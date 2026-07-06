using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;

namespace MyLoop.Api.Services;

/// <summary>
/// Background service that runs periodically to release decayed territory cells.
/// Hexes not refreshed (owner didn't walk through) within DecayDays are released.
/// Runs every hour — lightweight query with batch processing.
/// </summary>
public class DecayCleanupService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<DecayCleanupService> _logger;
    private static readonly TimeSpan Interval = TimeSpan.FromHours(1);

    /// <summary>
    /// Max decayed cells released per run. Bounds each pass so a large backlog can't lock the
    /// table for long; the remainder is picked up on the next hourly run. The owner HexCount
    /// decrement is derived from THIS exact deleted set (see <see cref="CleanupDecayedCells"/>),
    /// so a batched backlog can never double-count against HexCount.
    /// </summary>
    internal const int DecayBatchSize = 1000;

    public DecayCleanupService(IServiceScopeFactory scopeFactory, ILogger<DecayCleanupService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await CleanupDecayedCells(stoppingToken);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Decay cleanup failed");
            }

            await Task.Delay(Interval, stoppingToken);
        }
    }

    private async Task CleanupDecayedCells(CancellationToken ct)
    {
        using var scope = _scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var deleted = await ReleaseDecayedCellsAsync(db, DecayBatchSize, ct);

        if (deleted > 0)
        {
            _logger.LogInformation("Decay cleanup: released {Count} cells", deleted);
        }

        var brokenStreaks = await BreakStaleStreaksAsync(db, GameConstants.StreakBreakUtcGraceDays, ct);
        if (brokenStreaks > 0)
        {
            _logger.LogInformation("Streak cleanup: broke {Count} stale streaks", brokenStreaks);
        }
    }

    /// <summary>
    /// Breaks streaks that have gone stale — no claim for more than <paramref name="graceDays"/>
    /// days measured in UTC. Returns the number of streaks broken.
    ///
    /// The grace exists because LastClaimDate is recorded from the player's LOCAL date (clamped to
    /// UTC ±1 by <c>TerritoryService.ResolveStreakDate</c>), so a streak still alive in some
    /// timezone can trail UTC by up to two days. Breaking at (UTC today − graceDays), with
    /// graceDays = <see cref="GameConstants.StreakBreakUtcGraceDays"/>, never severs a streak an
    /// honest local claim would keep, while still reaping ones that are dead in every timezone.
    /// A broken streak is Streak = 0 / IsStreakActive = false; the next qualifying claim starts a
    /// fresh streak of 1 via <c>TerritoryService.UpdateStreak</c>.
    /// </summary>
    internal static Task<int> BreakStaleStreaksAsync(AppDbContext db, int graceDays, CancellationToken ct)
    {
        var cutoff = DateOnly.FromDateTime(DateTime.UtcNow).AddDays(-graceDays);
        return db.Database.ExecuteSqlAsync($"""
            UPDATE "Users"
            SET "IsStreakActive" = false, "Streak" = 0
            WHERE "IsStreakActive" = true
              AND ("LastClaimDate" IS NULL OR "LastClaimDate" < {cutoff})
            """, ct);
    }

    /// <summary>
    /// Releases up to <paramref name="batchSize"/> decayed cells and decrements their owners'
    /// HexCount in a SINGLE atomic statement, both derived from the same MATERIALIZED
    /// <c>decayed</c> set. Returns the number of cells released.
    ///
    /// This is the fix for the HexCount drift bug: the previous version decremented HexCount for
    /// EVERY currently-decayed cell but deleted only a capped batch, so any decayed cell beyond
    /// the cap survived and was decremented again on the next run — permanently under-counting
    /// heavy owners. Here the decrement (the <c>upd</c> data-modifying CTE) and the delete (the
    /// top-level statement) act on exactly the rows in <c>decayed</c>, so an owner's HexCount is
    /// only ever reduced by the number of their cells actually released this run.
    ///
    /// Single statement ⇒ one implicit transaction ⇒ delete and decrement can never diverge, and
    /// it participates in the configured Npgsql retry strategy automatically. <c>batchSize</c> is
    /// passed as a bound SQL parameter (not string-interpolated), so the query is injection-safe.
    /// </summary>
    internal static Task<int> ReleaseDecayedCellsAsync(AppDbContext db, int batchSize, CancellationToken ct) =>
        db.Database.ExecuteSqlRawAsync("""
            WITH decayed AS MATERIALIZED (
                SELECT "CellId", "OwnerId"
                FROM "TerritoryCells"
                WHERE "LastRefreshedAt" + ("DecayDays" || ' days')::interval < NOW()
                LIMIT {0}
            ),
            counts AS (
                SELECT "OwnerId", COUNT(*) AS cnt
                FROM decayed
                GROUP BY "OwnerId"
            ),
            upd AS (
                UPDATE "Users" u
                SET "HexCount" = GREATEST(0, u."HexCount" - c.cnt)
                FROM counts c
                WHERE u."Id" = c."OwnerId"
                RETURNING 1
            )
            DELETE FROM "TerritoryCells" t
            USING decayed d
            WHERE t."CellId" = d."CellId"
            """, new object[] { batchSize }, ct);
}
