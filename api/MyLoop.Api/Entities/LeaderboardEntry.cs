namespace MyLoop.Api.Entities;

/// <summary>
/// A daily leaderboard snapshot for one user.
/// Computed by <see cref="MyLoop.Api.Services.LeaderboardRefreshWorker"/>, a background timer
/// that ranks all players by total territory cells owned. One entry per user per day.
/// </summary>
public class LeaderboardEntry
{
    /// <summary>Unique identifier for this leaderboard entry (primary key).</summary>
    public Guid Id { get; set; }

    /// <summary>The user this entry belongs to.</summary>
    public Guid UserId { get; set; }

    /// <summary>The date this snapshot was computed for.</summary>
    public DateOnly Date { get; set; }

    /// <summary>Total number of H3 cells owned by this user on this date.</summary>
    public int CellCount { get; set; }

    /// <summary>Total territory area in square meters (derived from CellCount).</summary>
    public double AreaM2 { get; set; }

    /// <summary>The user's rank on this date (1 = most territory).</summary>
    public int Rank { get; set; }

    /// <summary>Navigation property to the ranked user.</summary>
    public User? User { get; set; }
}
