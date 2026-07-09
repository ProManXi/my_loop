using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Query;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Models;

namespace MyLoop.Api.Services;

public class LeaderboardService : ILeaderboardService
{
    /// <summary>Postgres advisory-lock key serializing RefreshLeaderboard runs.</summary>
    private const long LeaderboardRefreshLockKey = 0x4C4442524546; // "LDBREF"

    private readonly AppDbContext _db;
    private readonly IHexGridService _hexGrid;

    public LeaderboardService(AppDbContext db, IHexGridService hexGrid)
    {
        _db = db;
        _hexGrid = hexGrid;
    }

    public async Task<LeaderboardResponse> GetLeaderboard(double lat, double lng, Guid? userId, string scope)
    {
        var leaderboardScope = scope.ToLowerInvariant();

        // Between UTC midnight and the day's first refresh there are no rows for "today" yet;
        // serve the latest committed snapshot instead of a blank board (#125).
        var snapshotDate = await LatestSnapshotDate(_db);

        var query = await BuildScopedQuery(snapshotDate, leaderboardScope, userId);
        var scopedTop = await FetchTopEntries(query);
        var myRank = await ResolveUserRank(userId, scopedTop, query, snapshotDate);

        return new LeaderboardResponse
        {
            Top = scopedTop,
            MyRank = myRank,
            Scope = leaderboardScope,
        };
    }

    public async Task<int> RefreshLeaderboard()
    {
        var today = DateOnly.FromDateTime(DateTime.UtcNow);

        // The retrying execution strategy (EnableRetryOnFailure) may re-run this whole block on a
        // transient connection failure, so it must be wrapped here and be idempotent. The leading
        // ChangeTracker.Clear() is essential: UpdateAchievementCounters increments persistent user
        // counters in memory, and without a reset a retry would compound those increments on the
        // same DbContext. Clearing makes each attempt re-read fresh state (prior attempts rolled
        // back), and the delete-then-reinsert of today's rows is itself idempotent.
        var strategy = _db.Database.CreateExecutionStrategy();
        return await strategy.ExecuteAsync(async () =>
        {
            _db.ChangeTracker.Clear();
            await using var transaction = await _db.Database.BeginTransactionAsync();

            // Serialize concurrent refreshes (the hourly run and a claim-triggered run can
            // overlap): the loser waits, then observes the winner's committed rows, keeping
            // the finish counters once-per-day and preventing the delete/re-insert pair from
            // colliding on the (UserId, Date) unique index. Same advisory-lock pattern as
            // TerritoryService claims.
            await _db.Database.ExecuteSqlRawAsync(
                "SELECT pg_advisory_xact_lock({0})", LeaderboardRefreshLockKey);

            // Users already ranked today were credited a "finish" by an earlier refresh —
            // captured before the delete below wipes today's rows (#83).
            var alreadyCountedToday = (await _db.LeaderboardEntries
                .Where(l => l.Date == today)
                .Select(l => l.UserId)
                .ToListAsync()).ToHashSet();

            await _db.LeaderboardEntries.Where(l => l.Date == today).ExecuteDeleteAsync();

            var rankings = await _db.TerritoryCells
                .GroupBy(t => t.OwnerId)
                .Select(g => new { UserId = g.Key, CellCount = g.Count() })
                .OrderByDescending(x => x.CellCount)
                .ToListAsync();

            var entries = rankings.Select((r, i) => new LeaderboardEntry
            {
                Id = Guid.NewGuid(),
                UserId = r.UserId,
                Date = today,
                CellCount = r.CellCount,
                AreaM2 = _hexGrid.CalculateArea(r.CellCount),
                Rank = i + 1,
            }).ToList();

            _db.LeaderboardEntries.AddRange(entries);
            await _db.SaveChangesAsync();

            await UpdateAchievementCounters(entries, alreadyCountedToday);
            await PurgeOldEntries(today);

            await _db.SaveChangesAsync();
            await transaction.CommitAsync();

            return rankings.Count;
        });
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// The newest committed snapshot date (≤ UTC today), or today for an empty table. Every
    /// read of the board AND every registration row must key on this, not raw UTC today:
    /// between 00:00 UTC and the day's first refresh "today" has no snapshot, and a stray
    /// today-dated row (e.g. a signup) would otherwise hide the latest full snapshot (#125).
    /// </summary>
    internal static async Task<DateOnly> LatestSnapshotDate(AppDbContext db)
    {
        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        return await db.LeaderboardEntries
            .Where(l => l.Date <= today)
            .MaxAsync(l => (DateOnly?)l.Date) ?? today;
    }

    private async Task<IQueryable<LeaderboardEntry>> BuildScopedQuery(
        DateOnly snapshotDate, string scope, Guid? userId)
    {
        var query = _db.LeaderboardEntries
            .Include(l => l.User)
            .Where(l => l.Date == snapshotDate);

        if (scope is not ("city" or "country")) return query;
        if (!userId.HasValue) return query;

        var user = await _db.Users.FindAsync(userId.Value);
        if (user == null) return query;

        return scope switch
        {
            "city" when !string.IsNullOrEmpty(user.City) => query.Where(l => l.User!.City == user.City),
            "country" when !string.IsNullOrEmpty(user.Country) => query.Where(l => l.User!.Country == user.Country),
            _ => query,
        };
    }

    private static async Task<List<LeaderboardEntryResponse>> FetchTopEntries(IQueryable<LeaderboardEntry> query)
    {
        var topEntries = await query
            .OrderBy(l => l.Rank)
            .Take(GameConstants.LeaderboardTopCount)
            .Select(l => new
            {
                l.UserId,
                UserName = l.User!.DisplayName,
                UserColor = l.User!.Color,
                UserAvatar = l.User!.AvatarId,
                UserHexCount = l.User!.HexCount,
                UserStreak = l.User!.Streak,
                UserDistanceKm = l.User!.DistanceKm,
                l.CellCount,
                l.AreaM2,
            })
            .ToListAsync();

        // Competition ranking ("1224"): tied cell counts share a rank. This is the same
        // count-of-higher rule ResolveUserRank applies to users OUTSIDE this window, so a
        // tied player sees the same rank whether they made the top list or sit just below
        // it — positional i+1 numbering showed tied users different ranks (#125).
        var responses = new List<LeaderboardEntryResponse>(topEntries.Count);
        for (var i = 0; i < topEntries.Count; i++)
        {
            var e = topEntries[i];
            responses.Add(new LeaderboardEntryResponse
            {
                Rank = i > 0 && topEntries[i - 1].CellCount == e.CellCount
                    ? responses[i - 1].Rank
                    : i + 1,
                UserId = e.UserId,
                UserName = e.UserName,
                UserColor = e.UserColor,
                UserAvatar = e.UserAvatar,
                UserHexCount = e.UserHexCount,
                UserStreak = e.UserStreak,
                UserDistanceKm = e.UserDistanceKm,
                CellCount = e.CellCount,
                AreaM2 = e.AreaM2,
            });
        }
        return responses;
    }

    private async Task<MyRankResponse?> ResolveUserRank(
        Guid? userId, List<LeaderboardEntryResponse> topList,
        IQueryable<LeaderboardEntry> query, DateOnly snapshotDate)
    {
        if (!userId.HasValue) return null;

        var inTop = topList.FirstOrDefault(e => e.UserId == userId.Value);
        if (inTop != null)
        {
            return new MyRankResponse { Rank = inTop.Rank, CellCount = inTop.CellCount, AreaM2 = inTop.AreaM2 };
        }

        var globalEntry = await _db.LeaderboardEntries
            .Where(l => l.Date == snapshotDate && l.UserId == userId.Value)
            .Select(l => new { l.CellCount, l.AreaM2 })
            .FirstOrDefaultAsync();

        if (globalEntry == null) return null;

        var higherCount = await query.CountAsync(l => l.CellCount > globalEntry.CellCount);
        return new MyRankResponse
        {
            Rank = higherCount + 1,
            CellCount = globalEntry.CellCount,
            AreaM2 = globalEntry.AreaM2,
        };
    }

    /// <summary>
    /// Credits top-N finish counters at most once per calendar day per user: only users
    /// gaining their first LeaderboardEntry of the day are counted (#83). Set-based
    /// ExecuteUpdate per rank threshold replaces the former per-user FindAsync loop (N+1);
    /// it runs inside the refresh transaction, so a retry rolls back and re-runs cleanly.
    /// </summary>
    private async Task UpdateAchievementCounters(
        List<LeaderboardEntry> entries, HashSet<Guid> alreadyCountedToday)
    {
        var newlyRanked = entries.Where(e => !alreadyCountedToday.Contains(e.UserId)).ToList();

        await IncrementFinishes(newlyRanked, 3,
            s => s.SetProperty(u => u.TopThreeFinishes, u => u.TopThreeFinishes + 1));
        await IncrementFinishes(newlyRanked, 10,
            s => s.SetProperty(u => u.TopTenFinishes, u => u.TopTenFinishes + 1));
        await IncrementFinishes(newlyRanked, 100,
            s => s.SetProperty(u => u.TopHundredFinishes, u => u.TopHundredFinishes + 1));
        await IncrementFinishes(newlyRanked, 1000,
            s => s.SetProperty(u => u.TopThousandFinishes, u => u.TopThousandFinishes + 1));
    }

    private async Task IncrementFinishes(
        List<LeaderboardEntry> newlyRanked, int maxRank,
        Action<UpdateSettersBuilder<User>> increment)
    {
        var userIds = newlyRanked.Where(e => e.Rank <= maxRank).Select(e => e.UserId).ToList();
        if (userIds.Count == 0) return;
        await _db.Users.Where(u => userIds.Contains(u.Id)).ExecuteUpdateAsync(increment);
    }

    private async Task PurgeOldEntries(DateOnly today)
    {
        var cutoff = today.AddDays(-GameConstants.LeaderboardRetentionDays);
        await _db.LeaderboardEntries.Where(l => l.Date < cutoff).ExecuteDeleteAsync();
    }
}
