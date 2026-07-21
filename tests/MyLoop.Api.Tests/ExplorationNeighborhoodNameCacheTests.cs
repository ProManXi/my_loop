using System.Diagnostics;
using System.Net;
using System.Text;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #121 (ML-ERR-024): <c>GetExplorationStats</c> used to <c>await</c>
/// Nominatim reverse-geocode calls inline, capped at a 5-second timeout — on the
/// <c>/game-state</c> hot path hit at every login and every walk-end. It now never awaits
/// Nominatim on this path at all: an unresolved neighborhood gets an immediate lat/lng
/// fallback name, and the real name resolves in the background into a persisted,
/// shared-across-all-users <c>NeighborhoodNames</c> table that the next call reads from.
/// </summary>
public class ExplorationNeighborhoodNameCacheTests : IAsyncLifetime
{
    private const long NeighborhoodId = 5551L;
    private const double NeighborhoodLat = 12.9;
    private const double NeighborhoodLng = 77.5;

    private readonly PostgreSqlContainer _pg = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    private string _conn = "";
    private ServiceProvider _provider = null!;

    public async Task InitializeAsync()
    {
        await _pg.StartAsync();
        _conn = _pg.GetConnectionString();
        await using var db = NewDb();
        await db.Database.EnsureCreatedAsync();

        // A real IServiceScopeFactory, wired to the same test database, so the service's
        // fire-and-forget background resolution (its own DI scope) lands in the same DB the
        // test asserts against -- exactly like the app's real DI container, just minimal.
        var services = new ServiceCollection();
        services.AddDbContext<AppDbContext>(o => o.UseNpgsql(_conn));
        _provider = services.BuildServiceProvider();
    }

    public async Task DisposeAsync()
    {
        await _provider.DisposeAsync();
        await _pg.DisposeAsync();
    }

    private AppDbContext NewDb() =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseNpgsql(_conn).Options);

    /// <summary>Canned reverse-geocode response, delayed to simulate a slow/laggy Nominatim.</summary>
    private sealed class SlowNominatimHandler(TimeSpan delay) : HttpMessageHandler
    {
        public int CallCount;

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref CallCount);
            await Task.Delay(delay, cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    """{"address":{"suburb":"Realname Heights"}}""", Encoding.UTF8, "application/json"),
            };
        }
    }

    private TerritoryService NewService(GeocodingService geocoding) => new(
        NewDb(), Mock.Of<IHexGridService>(), Mock.Of<IGeoService>(),
        Mock.Of<ITerritoryNotifier>(), Mock.Of<IPathValidationService>(),
        Mock.Of<IPushNotificationService>(), geocoding,
        Mock.Of<IMissionService>(), Mock.Of<IAchievementService>(),
        _provider.GetRequiredService<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);

    private async Task<Guid> SeedExploredNeighborhood()
    {
        var userId = Guid.NewGuid();
        var claimId = Guid.NewGuid();
        await using var seed = NewDb();
        seed.Users.Add(new User { Id = userId, FirebaseUid = $"uid-{userId}", DisplayName = "E", Color = "#654321" });
        seed.Claims.Add(new Claim { Id = claimId, UserId = userId, CellCount = 1, CreatedAt = DateTime.UtcNow });
        var cell = new TerritoryCell
        {
            CellId = 42001L, OwnerId = userId, ClaimId = claimId,
            ClaimedAt = DateTime.UtcNow, LastRefreshedAt = DateTime.UtcNow,
            CenterLat = NeighborhoodLat, CenterLng = NeighborhoodLng,
            ParentCellId = 1L, NeighborhoodId = NeighborhoodId,
        };
        cell.SetBoundary([[NeighborhoodLat, NeighborhoodLng]]);
        seed.TerritoryCells.Add(cell);
        seed.ExploredCells.Add(new ExploredCell
        {
            UserId = userId, CellId = 42001L, NeighborhoodId = NeighborhoodId,
            FirstVisitedAt = DateTime.UtcNow,
        });
        await seed.SaveChangesAsync();
        return userId;
    }

    [Fact]
    public async Task Never_awaits_the_geocoder_and_returns_the_immediate_fallback_name()
    {
        var userId = await SeedExploredNeighborhood();
        var handler = new SlowNominatimHandler(TimeSpan.FromSeconds(3));
        var geocoding = new GeocodingService(new HttpClient(handler), NullLogger<GeocodingService>.Instance);

        var sw = Stopwatch.StartNew();
        var stats = await NewService(geocoding).GetExplorationStats(userId, 0, 0);
        sw.Stop();

        // The stub handler takes 3s to respond; a call that awaited it inline could not
        // possibly return this fast.
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(1),
            $"GetExplorationStats blocked on the geocoder for {sw.Elapsed}");

        var neighborhood = Assert.Single(stats);
        Assert.StartsWith("Area (", neighborhood.AreaName);
    }

    [Fact]
    public async Task Second_call_reuses_the_persisted_name_once_background_resolution_lands()
    {
        var userId = await SeedExploredNeighborhood();
        var handler = new SlowNominatimHandler(TimeSpan.FromMilliseconds(200));
        var geocoding = new GeocodingService(new HttpClient(handler), NullLogger<GeocodingService>.Instance);

        var first = await NewService(geocoding).GetExplorationStats(userId, 0, 0);
        Assert.StartsWith("Area (", Assert.Single(first).AreaName);

        // Background resolution is fire-and-forget; poll for it to land rather than sleep a
        // fixed guess.
        NeighborhoodName? persisted = null;
        for (var i = 0; i < 50 && persisted is null; i++)
        {
            await Task.Delay(100);
            await using var check = NewDb();
            persisted = await check.NeighborhoodNames.SingleOrDefaultAsync(n => n.NeighborhoodId == NeighborhoodId);
        }

        Assert.NotNull(persisted);
        Assert.Equal("Realname Heights", persisted!.AreaName);
        // Exactly one Nominatim call for the whole test -- the second GetExplorationStats call
        // below must NOT trigger another background resolution for an already-persisted name.
        Assert.Equal(1, handler.CallCount);

        var second = await NewService(geocoding).GetExplorationStats(userId, 0, 0);
        Assert.Equal("Realname Heights", Assert.Single(second).AreaName);
        Assert.Equal(1, handler.CallCount);
    }
}
