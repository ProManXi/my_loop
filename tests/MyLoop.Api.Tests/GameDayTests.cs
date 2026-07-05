using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Unit tests for <see cref="GameDay.Resolve"/> — the single "player's day" resolver shared by
/// streaks and daily missions. Clamps a client local date to UTC ±1 (honest offsets honoured,
/// manipulation bounded), and falls back to UTC today for missing/invalid input.
/// </summary>
public class GameDayTests
{
    private static readonly DateOnly UtcToday = DateOnly.FromDateTime(DateTime.UtcNow);

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not-a-date")]
    [InlineData("2026/07/02")]   // wrong format
    public void Missing_or_unparseable_falls_back_to_utc_today(string? input)
    {
        Assert.Equal(UtcToday, GameDay.Resolve(input));
    }

    [Fact]
    public void A_date_within_one_day_of_utc_is_returned_as_is()
    {
        foreach (var offset in new[] { -1, 0, 1 })
        {
            var date = UtcToday.AddDays(offset);
            Assert.Equal(date, GameDay.Resolve(date.ToString("yyyy-MM-dd")));
        }
    }

    [Fact]
    public void A_date_more_than_one_day_ahead_is_clamped_to_utc_plus_one()
    {
        var far = UtcToday.AddDays(5).ToString("yyyy-MM-dd");
        Assert.Equal(UtcToday.AddDays(1), GameDay.Resolve(far));
    }

    [Fact]
    public void A_date_more_than_one_day_behind_is_clamped_to_utc_minus_one()
    {
        var far = UtcToday.AddDays(-5).ToString("yyyy-MM-dd");
        Assert.Equal(UtcToday.AddDays(-1), GameDay.Resolve(far));
    }
}
