namespace MyLoop.Api.Services;

/// <summary>
/// The single definition of a player's "game day" — the calendar day used to roll over daily
/// missions AND streaks. Both are driven by the player's LOCAL date (sent by the client as
/// "yyyy-MM-dd"), clamped to UTC ±1 so honest timezone offsets are respected while date
/// manipulation is bounded to at most one day either side of UTC.
///
/// Before this existed, streaks used the local date but missions used server UTC, so a player far
/// from UTC saw their mission board reset mid-day. Routing both through here keeps one "today".
/// </summary>
public static class GameDay
{
    /// <summary>
    /// Resolves the player's game day from a client-supplied local date. A null / blank /
    /// unparseable value falls back to UTC today (back-compat for callers that don't send one).
    /// </summary>
    public static DateOnly Resolve(string? clientLocalDate)
    {
        var utcToday = DateOnly.FromDateTime(DateTime.UtcNow);
        if (string.IsNullOrWhiteSpace(clientLocalDate))
            return utcToday;

        if (!DateOnly.TryParseExact(clientLocalDate, "yyyy-MM-dd", out var parsed))
            return utcToday;

        if (parsed < utcToday.AddDays(-1)) return utcToday.AddDays(-1);
        if (parsed > utcToday.AddDays(1)) return utcToday.AddDays(1);
        return parsed;
    }
}
