using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;

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
        var notifier = scope.ServiceProvider.GetRequiredService<ITerritoryNotifier>();

        var released = await ReleaseDecayedCellsAsync(db, DecayBatchSize, ct);

        if (released.Count > 0)
        {
            _logger.LogInformation("Decay cleanup: released {Count} cells", released.Count);
            // Post-commit side effect (database-retry-resilience): the delete is durable,
            // so a broadcast failure can't be retried into a double-release. Clients that
            // miss it self-heal on their next viewport poll.
            await notifier.NotifyHexesReleasedAsync(ToReleaseEvents(released));
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
    /// Releases up to <paramref name="batchSize"/> decayed cells: deletes them, decrements
    /// their owners' HexCount, and writes Reason=Decay CellTransfer audit rows — all inside
    /// one transaction acting on the same locked row set. Returns the released cells so the
    /// caller can broadcast HexesReleased AFTER the commit (#104).
    ///
    /// The batch is selected FOR UPDATE first (indexed DecayAt range scan — the old
    /// per-row interval predicate was unindexable), so an owner refreshing a cell mid-run
    /// can't resurrect a row between the select and the delete. The decrement, audit
    /// insert, and delete then act on exactly that set, preserving the HexCount-drift fix
    /// (#78): an owner is only ever decremented by the number of their cells actually
    /// deleted this run.
    /// </summary>
    internal static async Task<List<DecayedCellRow>> ReleaseDecayedCellsAsync(
        AppDbContext db, int batchSize, CancellationToken ct)
    {
        var strategy = db.Database.CreateExecutionStrategy();
        return await strategy.ExecuteAsync(async () =>
        {
            db.ChangeTracker.Clear();
            await using var transaction = await db.Database.BeginTransactionAsync(ct);

            var decayed = await db.Database.SqlQueryRaw<DecayedCellRow>("""
                SELECT "CellId", "OwnerId", "ParentCellId"
                FROM "TerritoryCells"
                WHERE "DecayAt" < (NOW() AT TIME ZONE 'UTC')
                ORDER BY "DecayAt"
                LIMIT {0}
                FOR UPDATE
                """, batchSize).ToListAsync(ct);

            if (decayed.Count == 0)
            {
                await transaction.RollbackAsync(ct);
                return decayed;
            }

            var cellIds = decayed.Select(d => d.CellId).ToArray();
            await db.Database.ExecuteSqlRawAsync("""
                WITH decayed AS MATERIALIZED (
                    SELECT "CellId", "OwnerId"
                    FROM "TerritoryCells"
                    WHERE "CellId" = ANY({0})
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
                ),
                audit AS (
                    INSERT INTO "CellTransfers"
                        ("Id", "CellId", "FromUserId", "ToUserId", "ClaimId", "TransferredAt", "Reason")
                    SELECT gen_random_uuid(), d."CellId", d."OwnerId", d."OwnerId", {1}, NOW(), {2}
                    FROM decayed d
                    RETURNING 1
                )
                DELETE FROM "TerritoryCells" t
                USING decayed d
                WHERE t."CellId" = d."CellId"
                """, new object[] { cellIds, Guid.Empty, (int)TransferReason.Decay }, ct);

            await transaction.CommitAsync(ct);
            return decayed;
        });
    }

    internal static List<HexReleasedEvent> ToReleaseEvents(IEnumerable<DecayedCellRow> released) =>
        released.Select(r => new HexReleasedEvent(r.CellId.ToString(), r.ParentCellId)).ToList();
}

/// <summary>A cell released by the decay reaper (see ReleaseDecayedCellsAsync).</summary>
public class DecayedCellRow
{
    public long CellId { get; set; }
    public Guid OwnerId { get; set; }
    public long ParentCellId { get; set; }
}
