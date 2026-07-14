namespace MyLoop.Api.Services;

/// <summary>
/// Periodically recomputes the leaderboard snapshot from current territory data, replacing the
/// former client-triggered <c>POST /api/leaderboard/refresh</c>. That endpoint let any
/// authenticated user force a full <c>TerritoryCells</c> group-by over every cell plus a
/// delete/re-insert of today's <c>LeaderboardEntries</c> (<see cref="LeaderboardService.RefreshLeaderboard"/>)
/// on every walk, at up to the rate limiter's 120/min — an O(total cells) endpoint reachable by
/// design, not just accident (#109 / ML-ERR-012).
///
/// The advisory lock inside <see cref="LeaderboardService.RefreshLeaderboard"/> already
/// serializes overlapping runs, so this worker's periodic tick and the boot-time first pass
/// can never race a concurrent refresh.
/// </summary>
public class LeaderboardRefreshWorker : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<LeaderboardRefreshWorker> _logger;

    /// <summary>How often to recompute. Rank/leaderboard staleness of up to this long is
    /// acceptable — the previous client-triggered path was defended as necessary for a fresh
    /// post-walk rank, but the profile rank tile already tolerates the same staleness class
    /// (see #125's snapshot fallback).</summary>
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(5);

    public LeaderboardRefreshWorker(
        IServiceScopeFactory scopeFactory, ILogger<LeaderboardRefreshWorker> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await RunOnceAsync(_scopeFactory, _logger);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Leaderboard refresh failed");
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
    /// Runs one refresh cycle. Extracted from the timer loop so tests can drive it directly
    /// instead of waiting on <see cref="Interval"/>.
    /// </summary>
    internal static async Task<int> RunOnceAsync(IServiceScopeFactory scopeFactory, ILogger logger)
    {
        using var scope = scopeFactory.CreateScope();
        var leaderboardService = scope.ServiceProvider.GetRequiredService<ILeaderboardService>();
        var playerCount = await leaderboardService.RefreshLeaderboard();
        logger.LogInformation("Leaderboard refreshed: {PlayerCount} players ranked", playerCount);
        return playerCount;
    }
}
