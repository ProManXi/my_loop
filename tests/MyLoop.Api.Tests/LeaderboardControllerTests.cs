using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Controllers;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Thin-controller behavior tests (no database) for <see cref="LeaderboardController"/>:
/// it must default the scope to "city", pass query parameters through unchanged,
/// and surface the service result. Ranking data is public-by-design, so these are
/// delegation checks, not authorization checks.
/// </summary>
public class LeaderboardControllerTests
{
    private static LeaderboardController Build(Mock<ILeaderboardService> svc) =>
        new(svc.Object, NullLogger<LeaderboardController>.Instance);

    [Fact]
    public async Task GetLeaderboard_defaults_scope_to_city_when_absent()
    {
        var svc = new Mock<ILeaderboardService>();
        svc.Setup(s => s.GetLeaderboard(It.IsAny<double>(), It.IsAny<double>(), It.IsAny<Guid?>(), "city"))
           .ReturnsAsync(new LeaderboardResponse());

        await Build(svc).GetLeaderboard(1.0, 2.0, null, scope: null);

        svc.Verify(s => s.GetLeaderboard(1.0, 2.0, null, "city"), Times.Once);
    }

    [Fact]
    public async Task GetLeaderboard_passes_the_requested_scope_through()
    {
        var svc = new Mock<ILeaderboardService>();
        var userId = Guid.NewGuid();
        svc.Setup(s => s.GetLeaderboard(It.IsAny<double>(), It.IsAny<double>(), It.IsAny<Guid?>(), It.IsAny<string>()))
           .ReturnsAsync(new LeaderboardResponse());

        await Build(svc).GetLeaderboard(10.0, 20.0, userId, "world");

        svc.Verify(s => s.GetLeaderboard(10.0, 20.0, userId, "world"), Times.Once);
    }

    [Fact]
    public async Task GetLeaderboard_returns_ok_with_the_service_result()
    {
        var svc = new Mock<ILeaderboardService>();
        var payload = new LeaderboardResponse { Scope = "world" };
        svc.Setup(s => s.GetLeaderboard(It.IsAny<double>(), It.IsAny<double>(), It.IsAny<Guid?>(), It.IsAny<string>()))
           .ReturnsAsync(payload);

        var result = await Build(svc).GetLeaderboard(0, 0, null, "city");

        var ok = Assert.IsType<Microsoft.AspNetCore.Mvc.OkObjectResult>(result);
        Assert.Same(payload, ok.Value);
    }

    [Fact]
    public async Task Refresh_returns_ok_with_the_player_count()
    {
        var svc = new Mock<ILeaderboardService>();
        svc.Setup(s => s.RefreshLeaderboard()).ReturnsAsync(42);

        var result = await Build(svc).Refresh();

        Assert.IsType<Microsoft.AspNetCore.Mvc.OkObjectResult>(result);
        svc.Verify(s => s.RefreshLeaderboard(), Times.Once);
    }
}
