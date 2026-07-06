using System.Security.Claims;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Entities;
using MyLoop.Api.Hubs;
using MyLoop.Api.Interfaces;
using Xunit;
using SecurityClaim = System.Security.Claims.Claim;

namespace MyLoop.Api.Tests;

/// <summary>
/// JoinUserGroup must map the caller's Firebase UID to their internal Guid before
/// authorising, so a caller can join their OWN personal group (internal-Guid arg,
/// Firebase-UID token) but never another user's.
/// </summary>
public class TerritoryHubAuthTests
{
    private static User UserWithId(Guid id) =>
        new() { Id = id, FirebaseUid = "uid_robin", DisplayName = "Robin", Color = "#FF0000" };

    private static TerritoryHub BuildHub(
        string? firebaseUid, User? resolvedUser, Mock<IGroupManager> groups,
        Mock<IHexGridService>? hexGrid = null)
    {
        var users = new Mock<IUserService>();
        if (firebaseUid != null)
            users.Setup(u => u.GetByFirebaseUid(firebaseUid)).ReturnsAsync(resolvedUser);

        var claims = new List<SecurityClaim>();
        if (firebaseUid != null) claims.Add(new SecurityClaim("user_id", firebaseUid));
        // A non-null authenticationType makes Identity.IsAuthenticated true.
        var identity = new ClaimsIdentity(claims, firebaseUid != null ? "Firebase" : null);
        var principal = new ClaimsPrincipal(identity);

        var ctx = new Mock<HubCallerContext>();
        ctx.SetupGet(c => c.User).Returns(principal);
        ctx.SetupGet(c => c.ConnectionId).Returns("conn-1");

        return new TerritoryHub(users.Object, (hexGrid ?? new Mock<IHexGridService>()).Object, NullLogger<TerritoryHub>.Instance)
        {
            Context = ctx.Object,
            Groups = groups.Object,
        };
    }

    [Fact]
    public async Task JoinUserGroup_for_own_internal_id_succeeds()
    {
        var internalId = Guid.NewGuid();
        var groups = new Mock<IGroupManager>();
        var hub = BuildHub("uid_robin", UserWithId(internalId), groups);

        await hub.JoinUserGroup(internalId.ToString());

        groups.Verify(g => g.AddToGroupAsync("conn-1", $"user_{internalId}", It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task JoinUserGroup_for_another_users_id_is_rejected()
    {
        var callerInternalId = Guid.NewGuid();
        var victimInternalId = Guid.NewGuid();
        var groups = new Mock<IGroupManager>();
        var hub = BuildHub("uid_robin", UserWithId(callerInternalId), groups);

        await Assert.ThrowsAsync<HubException>(() => hub.JoinUserGroup(victimInternalId.ToString()));

        groups.Verify(g => g.AddToGroupAsync(
            It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task JoinUserGroup_when_unauthenticated_is_rejected()
    {
        var groups = new Mock<IGroupManager>();
        var hub = BuildHub(firebaseUid: null, resolvedUser: null, groups);

        await Assert.ThrowsAsync<HubException>(() => hub.JoinUserGroup(Guid.NewGuid().ToString()));

        groups.Verify(g => g.AddToGroupAsync(
            It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task JoinRegion_with_valid_region_id_subscribes()
    {
        const string regionId = "590686918550487039"; // a res-3 H3 cell id
        var groups = new Mock<IGroupManager>();
        var hexGrid = new Mock<IHexGridService>();
        hexGrid.Setup(h => h.IsValidRegionId(regionId)).Returns(true);
        var hub = BuildHub("uid_robin", UserWithId(Guid.NewGuid()), groups, hexGrid);

        await hub.JoinRegion(regionId);

        groups.Verify(g => g.AddToGroupAsync("conn-1", regionId, It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task JoinRegion_rejects_a_personal_group_name()
    {
        // The attack: subscribe to another user's private delta group via JoinRegion.
        var personalGroup = $"user_{Guid.NewGuid()}";
        var groups = new Mock<IGroupManager>();
        var hexGrid = new Mock<IHexGridService>();
        hexGrid.Setup(h => h.IsValidRegionId(personalGroup)).Returns(false);
        var hub = BuildHub("uid_robin", UserWithId(Guid.NewGuid()), groups, hexGrid);

        await Assert.ThrowsAsync<HubException>(() => hub.JoinRegion(personalGroup));

        groups.Verify(g => g.AddToGroupAsync(
            It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task JoinRegion_rejects_a_non_region_h3_cell_id()
    {
        // A syntactically-numeric id that is not a res-3 region (e.g. a res-11 cell) must
        // still be rejected — regions are exactly the ids the server broadcasts to.
        const string res11Cell = "639000000000000000";
        var groups = new Mock<IGroupManager>();
        var hexGrid = new Mock<IHexGridService>();
        hexGrid.Setup(h => h.IsValidRegionId(res11Cell)).Returns(false);
        var hub = BuildHub("uid_robin", UserWithId(Guid.NewGuid()), groups, hexGrid);

        await Assert.ThrowsAsync<HubException>(() => hub.JoinRegion(res11Cell));

        groups.Verify(g => g.AddToGroupAsync(
            It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }
}
