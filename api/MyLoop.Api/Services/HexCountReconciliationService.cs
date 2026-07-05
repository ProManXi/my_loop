using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Data;

namespace MyLoop.Api.Services;

/// <summary>
/// Background service that periodically repairs the denormalized <c>User.HexCount</c> so it
/// matches the authoritative <c>COUNT(TerritoryCells WHERE OwnerId = user.Id)</c>.
///
/// HexCount is a denormalized counter written only by deltas (+captured on claim, −stolen from
/// a victim, −released by decay). Any arithmetic drift — a historical race, a partial batch, a
/// future bug — would otherwise accumulate forever with no self-heal, and HexCount is the single
/// most-shown number in the game (Home, Profile, Leaderboard, SignalR). This worker is the
/// backstop that makes drift transient rather than permanent.
///
/// Runs as one set-based UPDATE (no entity loading, no N+1). It only rewrites rows that are
/// actually wrong, so a healthy database is a cheap no-op with minimal WAL churn. It is a repair
/// backstop, not the primary writer: if it happens to run in the same instant a claim commits,
/// it may momentarily write a count taken from a snapshot just before that claim's cell became
/// visible — self-corrected by the claim's own delta and the next reconciliation pass. Cadence is
/// therefore deliberately low.
/// </summary>
public class HexCountReconciliationService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<HexCountReconciliationService> _logger;

    /// <summary>How often to reconcile. Daily: drift is rare and self-limited, and a low cadence
    /// keeps the repair away from claim traffic.</summary>
    private static readonly TimeSpan Interval = TimeSpan.FromHours(24);

    /// <summary>Small delay after startup before the first pass, so boot isn't competing with a
    /// cold-start claim surge.</summary>
    private static readonly TimeSpan StartupDelay = TimeSpan.FromMinutes(5);

    public HexCountReconciliationService(
        IServiceScopeFactory scopeFactory, ILogger<HexCountReconciliationService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await Task.Delay(StartupDelay, stoppingToken);

            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await ReconcileAsync(stoppingToken);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "HexCount reconciliation failed");
                }

                await Task.Delay(Interval, stoppingToken);
            }
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown — swallow.
        }
    }

    /// <summary>
    /// Recomputes HexCount from the true owned-cell count for every user whose stored value is
    /// wrong (including users who now own zero cells). Single statement, set-based; returns the
    /// number of rows repaired for observability.
    /// </summary>
    internal static async Task<int> ReconcileAsync(AppDbContext db, CancellationToken ct)
    {
        return await db.Database.ExecuteSqlRawAsync("""
            UPDATE "Users" u
            SET "HexCount" = COALESCE(c.cnt, 0)
            FROM "Users" u2
            LEFT JOIN (
                SELECT "OwnerId", COUNT(*) AS cnt
                FROM "TerritoryCells"
                GROUP BY "OwnerId"
            ) c ON c."OwnerId" = u2."Id"
            WHERE u."Id" = u2."Id"
              AND u."HexCount" <> COALESCE(c.cnt, 0)
            """, ct);
    }

    private async Task ReconcileAsync(CancellationToken ct)
    {
        using var scope = _scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

        var repaired = await ReconcileAsync(db, ct);

        if (repaired > 0)
        {
            _logger.LogWarning("HexCount reconciliation repaired {Count} drifted user rows", repaired);
        }
    }
}
