using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #131 (ML-ERR-034): DailyMissions only had a NON-unique
/// (UserId, Date) index, so two concurrent first-of-day generations (e.g. /game-state
/// hydration racing a claim's RecordProgress — only claims hold the advisory lock) both
/// inserted, yielding 6 missions for the day and double XP surface. GetTodaysMissions'
/// catch-and-requery recovery assumed a unique violation that could never happen.
/// The index is now unique on (UserId, Date, Type), and DbInitializer collapses any
/// pre-existing duplicates before swapping the index on existing databases.
/// </summary>
public class DailyMissionUniqueSetTests : IAsyncLifetime
{
    private readonly PostgreSqlContainer _pg = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    private string _conn = "";

    public async Task InitializeAsync()
    {
        await _pg.StartAsync();
        _conn = _pg.GetConnectionString();
        await using var db = NewDb();
        await db.Database.EnsureCreatedAsync();
    }

    public async Task DisposeAsync() => await _pg.DisposeAsync();

    private AppDbContext NewDb(IInterceptor? interceptor = null)
    {
        var builder = new DbContextOptionsBuilder<AppDbContext>().UseNpgsql(_conn);
        if (interceptor != null)
            builder.AddInterceptors(interceptor);
        return new AppDbContext(builder.Options);
    }

    private async Task<Guid> SeedUser()
    {
        var userId = Guid.NewGuid();
        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid-{userId}",
            DisplayName = "U",
            Color = "#111111",
        });
        await seed.SaveChangesAsync();
        return userId;
    }

    /// <summary>
    /// Deterministically loses the first-of-day race: just before this context saves its
    /// freshly generated missions, a rival context inserts a mission set for the same
    /// (user, day) — exactly what a concurrent /game-state call does.
    /// </summary>
    private sealed class CompetingGenerationInterceptor(string conn) : SaveChangesInterceptor
    {
        private bool _fired;

        public override async ValueTask<InterceptionResult<int>> SavingChangesAsync(
            DbContextEventData eventData, InterceptionResult<int> result,
            CancellationToken cancellationToken = default)
        {
            var added = eventData.Context?.ChangeTracker.Entries<DailyMission>()
                .Where(e => e.State == EntityState.Added)
                .Select(e => e.Entity)
                .ToList();
            if (!_fired && added is { Count: > 0 })
            {
                _fired = true;
                await using var rival = new AppDbContext(
                    new DbContextOptionsBuilder<AppDbContext>().UseNpgsql(conn).Options);
                rival.DailyMissions.AddRange(added.Select(m => new DailyMission
                {
                    Id = Guid.NewGuid(),
                    UserId = m.UserId,
                    Date = m.Date,
                    Type = m.Type,
                    TargetValue = m.TargetValue,
                    XpReward = m.XpReward,
                    Description = m.Description,
                }));
                await rival.SaveChangesAsync(cancellationToken);
            }
            return result;
        }
    }

    [Fact]
    public async Task Concurrent_first_of_day_generation_yields_exactly_one_mission_set()
    {
        var userId = await SeedUser();

        List<DailyMission> missions;
        await using (var db = NewDb(new CompetingGenerationInterceptor(_conn)))
            missions = await new MissionService(db).GetTodaysMissions(userId);

        // The loser's insert hit the unique index and requeried the winner's set.
        Assert.Equal(GameConstants.MissionsPerDay, missions.Count);

        await using var check = NewDb();
        var rows = await check.DailyMissions.Where(m => m.UserId == userId).ToListAsync();
        Assert.Equal(GameConstants.MissionsPerDay, rows.Count);
        Assert.Equal(GameConstants.MissionsPerDay, rows.Select(m => m.Type).Distinct().Count());
    }

    [Fact]
    public async Task Startup_patch_collapses_duplicates_keeps_most_progress_and_is_idempotent()
    {
        var userId = await SeedUser();
        var today = DateOnly.FromDateTime(DateTime.UtcNow);

        await using var db = NewDb();
        // Recreate the pre-fix schema: non-unique (UserId, Date) index only.
        await db.Database.ExecuteSqlRawAsync(
            @"DROP INDEX IF EXISTS ""IX_DailyMissions_UserId_Date_Type""");
        await db.Database.ExecuteSqlRawAsync(@"
            CREATE INDEX IF NOT EXISTS ""IX_DailyMissions_UserId_Date""
            ON ""DailyMissions"" (""UserId"", ""Date"")");

        // A raced day: CaptureHexes exists twice with different progress.
        DailyMission Mission(MissionType type, int progress) => new()
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            Date = today,
            Type = type,
            TargetValue = 5,
            CurrentProgress = progress,
            XpReward = 80,
            Description = "d",
        };
        db.DailyMissions.AddRange(
            Mission(MissionType.CaptureHexes, 4),
            Mission(MissionType.CaptureHexes, 1),
            Mission(MissionType.WalkDistance, 0));
        await db.SaveChangesAsync();

        DbInitializer.ApplyDailyMissionUniqueIndexPatch(db);
        DbInitializer.ApplyDailyMissionUniqueIndexPatch(db); // idempotent

        await using var check = NewDb();
        var rows = await check.DailyMissions.Where(m => m.UserId == userId).ToListAsync();
        Assert.Equal(2, rows.Count);
        Assert.Equal(4, rows.Single(m => m.Type == MissionType.CaptureHexes).CurrentProgress);

        // The unique index is back, so re-racing the same (user, day, type) now fails loud.
        check.DailyMissions.Add(Mission(MissionType.WalkDistance, 0));
        await Assert.ThrowsAsync<DbUpdateException>(() => check.SaveChangesAsync());
    }

    [Fact]
    public async Task Multiple_progress_calls_in_one_transaction_generate_the_set_once()
    {
        var userId = await SeedUser();

        // A claim calls RecordProgress several times (CaptureHexes, CaptureInOneWalk,
        // WalkDistance, …) on ONE context before a single save. On the first claim of the
        // day the later calls must reuse the first call's unsaved set — regenerating would
        // self-collide on the unique index and fail every retry of the claim.
        await using (var db = NewDb())
        {
            var missions = new MissionService(db);
            await missions.RecordProgress(userId, MissionType.CaptureHexes, 2);
            await missions.RecordProgress(userId, MissionType.CaptureInOneWalk, 2);
            await missions.RecordProgress(userId, MissionType.WalkDistance, 250);
            await db.SaveChangesAsync();
        }

        await using var check = NewDb();
        Assert.Equal(
            GameConstants.MissionsPerDay,
            await check.DailyMissions.CountAsync(m => m.UserId == userId));
    }

    [Fact]
    public async Task Generated_mission_sets_always_have_distinct_types()
    {
        await using var db = NewDb();
        for (var i = 0; i < 25; i++)
        {
            var userId = await SeedUser();
            var missions = await new MissionService(db).GetTodaysMissions(userId);
            Assert.Equal(GameConstants.MissionsPerDay, missions.Select(m => m.Type).Distinct().Count());
        }
    }
}
