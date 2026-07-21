using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Controllers;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// The destructive user endpoints (delete account, register device token) must reject
/// any caller who is not the targeted user. These are the highest-impact BOLA fixes:
/// account destruction and push-notification hijacking.
///
/// The deny path returns before any database/geocoding access, so those concrete
/// dependencies are intentionally null here.
/// </summary>
public class UsersControllerAuthTests
{
    private static UsersController Build(
        Mock<IUserService> users,
        Mock<IPushNotificationService> push,
        Mock<ICurrentUser> currentUser) =>
        new(users.Object, Mock.Of<IValidationService>(), push.Object,
            geocoding: null!, db: null!, currentUser.Object,
            Mock.Of<IMissionService>(), Mock.Of<IAchievementService>(), Mock.Of<ITerritoryService>(),
            NullLogger<UsersController>.Instance);

    [Fact]
    public async Task DeleteAccount_for_another_user_is_forbidden_and_deletes_nothing()
    {
        var callerId = Guid.NewGuid();
        var victimId = Guid.NewGuid();

        var users = new Mock<IUserService>();
        var push = new Mock<IPushNotificationService>();
        var currentUser = new Mock<ICurrentUser>();
        currentUser.Setup(c => c.TryGetUserIdAsync()).ReturnsAsync(callerId);

        var result = await Build(users, push, currentUser).DeleteAccount(victimId);

        Assert.IsType<ForbidResult>(result);
        users.Verify(u => u.DeleteAccount(It.IsAny<Guid>()), Times.Never);
    }

    [Fact]
    public async Task RegisterDeviceToken_for_another_user_is_forbidden_and_registers_nothing()
    {
        var callerId = Guid.NewGuid();
        var victimId = Guid.NewGuid();

        var users = new Mock<IUserService>();
        var push = new Mock<IPushNotificationService>();
        var currentUser = new Mock<ICurrentUser>();
        currentUser.Setup(c => c.TryGetUserIdAsync()).ReturnsAsync(callerId);

        var result = await Build(users, push, currentUser)
            .RegisterDeviceToken(victimId, new DeviceTokenRequest { Token = "attacker-device" });

        Assert.IsType<ForbidResult>(result);
        push.Verify(p => p.RegisterDeviceToken(It.IsAny<Guid>(), It.IsAny<string>(), It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task DeleteAccount_when_unauthenticated_returns_401()
    {
        var users = new Mock<IUserService>();
        var push = new Mock<IPushNotificationService>();
        var currentUser = new Mock<ICurrentUser>();
        currentUser.Setup(c => c.TryGetUserIdAsync()).ReturnsAsync((Guid?)null);

        var result = await Build(users, push, currentUser).DeleteAccount(Guid.NewGuid());

        Assert.IsType<UnauthorizedResult>(result);
        users.Verify(u => u.DeleteAccount(It.IsAny<Guid>()), Times.Never);
    }

    // ── Register identity trust (#99 / ML-ERR-001) ──────────────────────────────

    private static RegisterRequest ValidRegister(string? bodyUid) => new()
    {
        FirebaseUid = bodyUid,
        DisplayName = "Robin",
        Color = "#FF0000",
        AvatarId = 1,
    };

    [Fact]
    public async Task Register_uses_the_token_uid_and_ignores_the_body_uid()
    {
        var users = new Mock<IUserService>();
        var push = new Mock<IPushNotificationService>();
        var currentUser = new Mock<ICurrentUser>();
        currentUser.SetupGet(c => c.FirebaseUid).Returns("verified_owner");
        users.Setup(u => u.Register(It.IsAny<RegisterRequest>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(new User { Id = Guid.NewGuid(), FirebaseUid = "verified_owner", DisplayName = "Robin", Color = "#FF0000" });

        // The body tries to register a DIFFERENT (victim) uid.
        var result = await Build(users, push, currentUser).Register(ValidRegister("victim_uid"));

        Assert.IsType<CreatedResult>(result);
        users.Verify(u => u.Register(It.IsAny<RegisterRequest>(), "verified_owner", It.IsAny<string>()), Times.Once);
        users.Verify(u => u.Register(It.IsAny<RegisterRequest>(), "victim_uid", It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task Register_with_a_real_uid_and_no_token_is_rejected_401()
    {
        var users = new Mock<IUserService>();
        var push = new Mock<IPushNotificationService>();
        var currentUser = new Mock<ICurrentUser>();
        currentUser.SetupGet(c => c.FirebaseUid).Returns((string?)null); // no validated token

        // The account-squatting attempt: an anonymous caller posting a victim's Firebase uid.
        var result = await Build(users, push, currentUser).Register(ValidRegister("victim_firebase_uid"));

        Assert.IsType<UnauthorizedObjectResult>(result);
        users.Verify(u => u.Register(It.IsAny<RegisterRequest>(), It.IsAny<string>(), It.IsAny<string>()), Times.Never);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("local_abc")]
    [InlineData("dev_abc")]
    public async Task Register_local_account_without_token_mints_a_server_side_local_uid(string? bodyUid)
    {
        var users = new Mock<IUserService>();
        var push = new Mock<IPushNotificationService>();
        var currentUser = new Mock<ICurrentUser>();
        currentUser.SetupGet(c => c.FirebaseUid).Returns((string?)null);
        string? passedUid = null;
        users.Setup(u => u.Register(It.IsAny<RegisterRequest>(), It.IsAny<string>(), It.IsAny<string>()))
            .Callback<RegisterRequest, string, string>((_, uid, _) => passedUid = uid)
            .ReturnsAsync(new User { Id = Guid.NewGuid(), FirebaseUid = "local", DisplayName = "Robin", Color = "#FF0000" });

        var result = await Build(users, push, currentUser).Register(ValidRegister(bodyUid));

        Assert.IsType<CreatedResult>(result);
        // Server-minted, never the client's value, and provider forced to local.
        Assert.NotNull(passedUid);
        Assert.StartsWith("local_", passedUid);
        Assert.NotEqual(bodyUid, passedUid);
        users.Verify(u => u.Register(It.IsAny<RegisterRequest>(), It.IsAny<string>(), "local"), Times.Once);
    }
}
