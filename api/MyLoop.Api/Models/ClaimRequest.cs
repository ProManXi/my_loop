namespace MyLoop.Api.Models;

public class ClaimRequest
{
    public Guid UserId { get; set; }
    public double[][] Path { get; set; } = [];

    /// <summary>
    /// Client-generated walk session id (UUID string). All batch-step claims and the final loop
    /// claim for one continuous walk share this id, so the server records them as a single Claim
    /// (one walk = one history entry, #56). Sent as a string (JSON has no Guid type); the
    /// controller parses it tolerantly — absent, empty, or unparseable values resolve to a
    /// standalone claim, so a malformed id can never 400 the core claim path.
    /// </summary>
    public string? WalkSessionId { get; set; }

    /// <summary>
    /// Client's local calendar date ("yyyy-MM-dd"). Drives which day's daily missions this loop
    /// claim progresses, so missions roll over on the player's local midnight (matching streaks and
    /// the batch-step path), not server UTC. Absent/unparseable falls back to UTC today server-side.
    /// </summary>
    public string? LocalDate { get; set; }
}
