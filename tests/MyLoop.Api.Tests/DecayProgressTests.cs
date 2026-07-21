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
/// Regression tests for ML-ERR-008 (issue #105): DecayProgress was computed from the global
/// GameConstants.DecayDays (7) instead of each cell's own DecayDays (7–90, set by home
/// distance at capture). A 90-day foreign cell rendered as fully decayed after 7 days in
/// every client decay ring while the server would not release it for months.
/// </summary>
public class DecayProgressTests : IAsyncLifetime
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

    private static TerritoryService NewService(AppDbContext db)
    {
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };
        return new TerritoryService(
            db, Mock.Of<IHexGridService>(), Mock.Of<IGeoService>(),
            Mock.Of<ITerritoryNotifier>(), Mock.Of<IPathValidationService>(),
            Mock.Of<IPushNotificationService>(),
            new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, Mock.Of<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);
    }

    private const long SlowDecayCellId = 9101L; // 90-day cell, e.g. captured abroad
    private const long LocalCellId = 9102L;     // default 7-day cell near home

    private async Task<Guid> SeedUserWithTwoCells()
    {
        var userId = Guid.NewGuid();
        var claimId = Guid.NewGuid();
        var now = DateTime.UtcNow;
        await using var seed = NewDb();
        seed.Users.Add(new User { Id = userId, FirebaseUid = "uid-decay", DisplayName = "D", Color = "#333333" });
        seed.Claims.Add(new Claim { Id = claimId, UserId = userId, CellCount = 2, CreatedAt = now.AddDays(-9) });
        seed.TerritoryCells.Add(NewCell(SlowDecayCellId, userId, claimId, decayDays: 90, lastRefreshed: now.AddDays(-9)));
        seed.TerritoryCells.Add(NewCell(LocalCellId, userId, claimId, decayDays: 7, lastRefreshed: now.AddDays(-3.5)));
        await seed.SaveChangesAsync();
        return userId;
    }

    private static TerritoryCell NewCell(long cellId, Guid ownerId, Guid claimId, int decayDays, DateTime lastRefreshed)
    {
        var cell = new TerritoryCell
        {
            CellId = cellId,
            OwnerId = ownerId,
            ClaimId = claimId,
            ClaimedAt = lastRefreshed,
            LastRefreshedAt = lastRefreshed,
            CenterLat = 12.9,
            CenterLng = 77.5,
            ParentCellId = 1L,
            NeighborhoodId = 2L,
            DecayDays = decayDays,
        };
        cell.SetBoundary([[12.9, 77.5]]);
        return cell;
    }

    [Fact]
    public async Task Viewport_decay_progress_uses_each_cells_own_DecayDays()
    {
        var userId = await SeedUserWithTwoCells();

        await using var db = NewDb();
        var cells = await NewService(db).GetTerritoriesInViewport(12.0, 77.0, 13.0, 78.0);

        var slow = cells.Single(c => c.CellId == SlowDecayCellId);
        var local = cells.Single(c => c.CellId == LocalCellId);

        // 9 of 90 days elapsed → 10%, NOT 9/7 clamped to 100%.
        Assert.InRange(slow.DecayProgress, 0.09, 0.11);
        // 3.5 of 7 days elapsed → 50% either way (control: default-decay cells unaffected).
        Assert.InRange(local.DecayProgress, 0.49, 0.51);
        Assert.Equal(userId, slow.OwnerId);
    }

    [Fact]
    public async Task User_territories_decay_progress_uses_each_cells_own_DecayDays()
    {
        var userId = await SeedUserWithTwoCells();

        await using var db = NewDb();
        var cells = await NewService(db).GetUserTerritories(userId);

        var slow = cells.Single(c => c.CellId == SlowDecayCellId);
        var local = cells.Single(c => c.CellId == LocalCellId);

        Assert.InRange(slow.DecayProgress, 0.09, 0.11);
        Assert.InRange(local.DecayProgress, 0.49, 0.51);
    }
}
