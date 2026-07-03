using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Controllers;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Achievements expose per-user progress and must only be readable by their owner.
/// Before the fix AchievementsController performed no ownership check, so any
/// authenticated caller could read any other user's achievements by GUID (IDOR).
/// </summary>
public class AchievementsControllerAuthTests
{
    private static AchievementsController Build(Mock<IAchievementService> achievements, Mock<ICurrentUser> currentUser) =>
        new(achievements.Object, currentUser.Object, NullLogger<AchievementsController>.Instance);

    [Fact]
    public async Task GetAchievements_for_another_user_is_forbidden_and_reads_nothing()
    {
        var callerId = Guid.NewGuid();
        var otherId = Guid.NewGuid();

        var achievements = new Mock<IAchievementService>();
        var currentUser = new Mock<ICurrentUser>();
        currentUser.Setup(c => c.TryGetUserIdAsync()).ReturnsAsync(callerId);

        var result = await Build(achievements, currentUser).GetAchievements(otherId);

        Assert.IsType<ForbidResult>(result);
        achievements.Verify(a => a.GetAllForUser(It.IsAny<Guid>()), Times.Never);
    }

    [Fact]
    public async Task GetAchievements_when_unauthenticated_returns_401()
    {
        var achievements = new Mock<IAchievementService>();
        var currentUser = new Mock<ICurrentUser>();
        currentUser.Setup(c => c.TryGetUserIdAsync()).ReturnsAsync((Guid?)null);

        var result = await Build(achievements, currentUser).GetAchievements(Guid.NewGuid());

        Assert.IsType<UnauthorizedResult>(result);
        achievements.Verify(a => a.GetAllForUser(It.IsAny<Guid>()), Times.Never);
    }

    [Fact]
    public async Task GetAchievements_for_self_returns_ok()
    {
        var callerId = Guid.NewGuid();
        var expected = new List<AchievementStatus> { new() { Id = "first-claim" } };

        var achievements = new Mock<IAchievementService>();
        achievements.Setup(a => a.GetAllForUser(callerId)).ReturnsAsync(expected);
        var currentUser = new Mock<ICurrentUser>();
        currentUser.Setup(c => c.TryGetUserIdAsync()).ReturnsAsync(callerId);

        var result = await Build(achievements, currentUser).GetAchievements(callerId);

        var ok = Assert.IsType<OkObjectResult>(result);
        Assert.Same(expected, ok.Value);
    }
}
