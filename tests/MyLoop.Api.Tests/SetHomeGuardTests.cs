using System.Net;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Constants;
using MyLoop.Api.Controllers;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #84: POST /api/users/{id}/home accepted any coordinates,
/// any number of times — a caller could re-home into arbitrary cities to game decay
/// distance and leaderboard scoping. Home changes are now gated to once per
/// GameConstants.HomeChangeCooldownDays; the first (onboarding) set is always allowed.
/// </summary>
public class SetHomeGuardTests : IAsyncLifetime
{
    private readonly PostgreSqlContainer _pg = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    private string _conn = "";

    public async Task InitializeAsync()
    {
        await _pg.StartAsync();
        _conn = _pg.GetConnectionString();
        await using var db = NewDb();
        await db.Database.EnsureCreatedAsync();
    }

    public async Task DisposeAsync() => await _pg.DisposeAsync();

    private AppDbContext NewDb() =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseNpgsql(_conn).Options);

    /// <summary>Canned nominatim reverse-geocode response — keeps tests offline and deterministic.</summary>
    private sealed class StubNominatimHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    """{"address":{"city":"Testville","state":"Testshire","country":"Testland","country_code":"gb"}}""",
                    Encoding.UTF8, "application/json"),
            });
    }

    private UsersController BuildController(AppDbContext db, Guid callerId)
    {
        var currentUser = new Mock<ICurrentUser>();
        currentUser.Setup(c => c.TryGetUserIdAsync()).ReturnsAsync(callerId);

        var geocoding = new GeocodingService(
            new HttpClient(new StubNominatimHandler()), NullLogger<GeocodingService>.Instance);

        return new UsersController(
            Mock.Of<IUserService>(), Mock.Of<IValidationService>(),
            Mock.Of<IPushNotificationService>(), geocoding, db, currentUser.Object,
            Mock.Of<IMissionService>(), Mock.Of<IAchievementService>(), Mock.Of<ITerritoryService>(),
            NullLogger<UsersController>.Instance);
    }

    private async Task<Guid> SeedUser(double? homeLat = null, double? homeLng = null, DateTime? homeSetAt = null)
    {
        var userId = Guid.NewGuid();
        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId, FirebaseUid = $"uid-{userId}", DisplayName = "H", Color = "#111111",
            HomeLat = homeLat, HomeLng = homeLng, HomeSetAt = homeSetAt,
        });
        await seed.SaveChangesAsync();
        return userId;
    }

    private static SetHomeRequest Coords(double lat, double lng) => new() { Lat = lat, Lng = lng };

    [Fact]
    public async Task First_set_during_onboarding_succeeds_and_stamps_HomeSetAt()
    {
        var userId = await SeedUser();

        await using var db = NewDb();
        var result = await BuildController(db, userId).SetHome(userId, Coords(51.5, -0.12));

        Assert.IsType<OkObjectResult>(result);
        await using var check = NewDb();
        var user = await check.Users.SingleAsync(u => u.Id == userId);
        Assert.Equal(51.5, user.HomeLat);
        Assert.Equal("Testville", user.HomeCity);
        Assert.NotNull(user.HomeSetAt);
    }

    [Fact]
    public async Task Immediate_rehome_is_rejected_with_429_and_coordinates_unchanged()
    {
        var userId = await SeedUser();

        await using (var db1 = NewDb())
        {
            Assert.IsType<OkObjectResult>(
                await BuildController(db1, userId).SetHome(userId, Coords(51.5, -0.12)));
        }

        await using var db2 = NewDb();
        var second = await BuildController(db2, userId).SetHome(userId, Coords(48.85, 2.35));

        var status = Assert.IsType<ObjectResult>(second);
        Assert.Equal(429, status.StatusCode);

        await using var check = NewDb();
        var user = await check.Users.SingleAsync(u => u.Id == userId);
        Assert.Equal(51.5, user.HomeLat);
        Assert.Equal(-0.12, user.HomeLng);
    }

    [Fact]
    public async Task Rehome_after_cooldown_expires_succeeds_and_restamps()
    {
        var staleStamp = DateTime.UtcNow.AddDays(-(GameConstants.HomeChangeCooldownDays + 1));
        var userId = await SeedUser(homeLat: 51.5, homeLng: -0.12, homeSetAt: staleStamp);

        await using var db = NewDb();
        var result = await BuildController(db, userId).SetHome(userId, Coords(48.85, 2.35));

        Assert.IsType<OkObjectResult>(result);
        await using var check = NewDb();
        var user = await check.Users.SingleAsync(u => u.Id == userId);
        Assert.Equal(48.85, user.HomeLat);
        Assert.True(user.HomeSetAt > DateTime.UtcNow.AddMinutes(-5));
    }

    [Fact]
    public async Task Legacy_account_with_home_but_no_stamp_gets_one_tracked_change_then_cooldown()
    {
        var userId = await SeedUser(homeLat: 51.5, homeLng: -0.12, homeSetAt: null);

        await using (var db1 = NewDb())
        {
            Assert.IsType<OkObjectResult>(
                await BuildController(db1, userId).SetHome(userId, Coords(48.85, 2.35)));
        }

        await using var db2 = NewDb();
        var second = await BuildController(db2, userId).SetHome(userId, Coords(40.7, -74.0));
        var status = Assert.IsType<ObjectResult>(second);
        Assert.Equal(429, status.StatusCode);
    }

    [Fact]
    public async Task SetHome_for_another_user_is_still_forbidden()
    {
        var victimId = await SeedUser();

        await using var db = NewDb();
        var result = await BuildController(db, callerId: Guid.NewGuid()).SetHome(victimId, Coords(51.5, -0.12));

        Assert.IsType<ForbidResult>(result);
    }
}
