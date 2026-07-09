using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #114 (ML-ERR-017): GetTerritoriesInViewport filtered only by
/// center coords and applied Take(500) with NO ORDER BY — Postgres returned an arbitrary 500,
/// so dense-city viewports rendered a different random subset each 30 s poll (visible hex
/// flicker), and the documented bucket-first ParentCellId pruning (spatial-model.md) was
/// ignored. The query now prunes by the region set, orders by CellId, and reports truncation.
/// </summary>
public class ViewportBucketFirstTests : IAsyncLifetime
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

    private static TerritoryService NewService(AppDbContext db, params long[] regionIds)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.GetRegionIdsForBbox(
                It.IsAny<double>(), It.IsAny<double>(), It.IsAny<double>(), It.IsAny<double>()))
            .Returns(regionIds);
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };
        return new TerritoryService(
            db, hex.Object, Mock.Of<IGeoService>(),
            Mock.Of<ITerritoryNotifier>(), Mock.Of<IPathValidationService>(),
            Mock.Of<IPushNotificationService>(),
            new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, NullLogger<TerritoryService>.Instance);
    }

    private async Task<Guid> SeedOwner()
    {
        var userId = Guid.NewGuid();
        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid-{userId}",
            DisplayName = "V",
            Color = "#444444",
        });
        await seed.SaveChangesAsync();
        return userId;
    }

    private async Task SeedCells(Guid ownerId, long parentCellId, IEnumerable<long> cellIds, double centerLat = 12.9)
    {
        await using var seed = NewDb();
        var claimId = Guid.NewGuid();
        seed.Claims.Add(new Claim { Id = claimId, UserId = ownerId, CellCount = 0, CreatedAt = DateTime.UtcNow });
        foreach (var cellId in cellIds)
        {
            var cell = new TerritoryCell
            {
                CellId = cellId,
                OwnerId = ownerId,
                ClaimId = claimId,
                ClaimedAt = DateTime.UtcNow,
                LastRefreshedAt = DateTime.UtcNow,
                CenterLat = centerLat,
                CenterLng = 77.5,
                ParentCellId = parentCellId,
                NeighborhoodId = 2L,
                DecayDays = 7,
            };
            cell.SetBoundary([[12.9, 77.5]]);
            seed.TerritoryCells.Add(cell);
        }
        await seed.SaveChangesAsync();
    }

    [Fact]
    public async Task Overfull_viewport_returns_a_deterministic_ordered_subset_and_flags_truncation()
    {
        var owner = await SeedOwner();
        // One more cell than the cap, seeded in two separate batches with the LOWER ids in
        // the second batch: heap order (first-inserted first) then disagrees with id order,
        // so an unordered Take returns the high-id batch first. (A single batch is not a
        // valid red-check — EF orders batched INSERTs by primary key, making physical order
        // coincide with sorted order.) The fixed query must return the lowest
        // MaxViewportCells ids, sorted, on every poll.
        var highBatch = Enumerable.Range(0, 300).Select(i => 2000L + i).ToList();
        var lowBatch = Enumerable.Range(0, GameConstants.MaxViewportCells + 1 - 300)
            .Select(i => 1000L + i).ToList();
        await SeedCells(owner, parentCellId: 1L, highBatch);
        await SeedCells(owner, parentCellId: 1L, lowBatch);
        var ids = highBatch.Concat(lowBatch).ToList();

        await using var db = NewDb();
        var service = NewService(db, 1L);

        var first = await service.GetTerritoriesInViewport(12.0, 77.0, 13.0, 78.0);
        var second = await service.GetTerritoriesInViewport(12.0, 77.0, 13.0, 78.0);

        var expected = ids.OrderBy(id => id).Take(GameConstants.MaxViewportCells).ToList();
        Assert.Equal(expected, first.Cells.Select(c => c.CellId).ToList());
        Assert.Equal(first.Cells.Select(c => c.CellId), second.Cells.Select(c => c.CellId));
        Assert.True(first.Truncated);
    }

    [Fact]
    public async Task Empty_region_set_skips_pruning_but_keeps_order_and_cap()
    {
        var owner = await SeedOwner();
        // Distinct latitude band: with pruning skipped, only the coordinate filter keeps
        // this test blind to the other tests' cells in the shared container.
        await SeedCells(owner, parentCellId: 55L, [3002L, 3001L], centerLat: 20.5);

        // Zoomed-out viewports get an empty region set ("too wide to prune") — every
        // in-bbox cell must still be served, deterministically ordered.
        await using var db = NewDb();
        var result = await NewService(db /* no region ids */).GetTerritoriesInViewport(20.0, 77.0, 21.0, 78.0);

        Assert.Equal([3001L, 3002L], result.Cells.Select(c => c.CellId).ToList());
        Assert.False(result.Truncated);
    }

    [Fact]
    public async Task Viewport_spanning_two_regions_returns_cells_from_both()
    {
        var owner = await SeedOwner();
        await SeedCells(owner, parentCellId: 11L, [2001L, 2002L]);
        await SeedCells(owner, parentCellId: 12L, [2003L]);
        // In-bbox cell whose parent is outside the region set must be pruned bucket-first.
        await SeedCells(owner, parentCellId: 99L, [2004L]);

        await using var db = NewDb();
        var result = await NewService(db, 11L, 12L).GetTerritoriesInViewport(12.0, 77.0, 13.0, 78.0);

        Assert.Equal([2001L, 2002L, 2003L], result.Cells.Select(c => c.CellId).ToList());
        Assert.False(result.Truncated);
    }
}

/// <summary>
/// Unit tests for the real HexGridService.GetRegionIdsForBbox (#114): the region set must
/// contain the res-3 parent of every res-11 cell whose center lies in the bbox — small
/// viewports inside one parent, city viewports, and bboxes straddling parent boundaries.
/// Over-coverage is fine; under-coverage drops visible hexes.
/// </summary>
public class HexGridBboxRegionTests
{
    private static HexGridService Service() => new(new GeoService());

    [Theory]
    // ~200 m viewport (fits deep inside one res-3 parent — polyfill alone finds nothing).
    [InlineData(12.9700, 77.5900, 12.9718, 77.5918)]
    // City-scale viewport (~0.2°).
    [InlineData(12.85, 77.45, 13.05, 77.65)]
    // Wide viewport spanning multiple res-3 parents (~3°).
    [InlineData(11.5, 76.0, 14.5, 79.0)]
    // Long thin strip (~1 km tall, ~9° wide): no res-3 center falls inside, so corner
    // seeds + polyfill alone under-covered it — perimeter sampling must not.
    [InlineData(12.900, 70.0, 12.912, 79.0)]
    // Tall thin strip (the same shape rotated).
    [InlineData(8.0, 77.590, 17.0, 77.605)]
    public void Region_set_covers_the_parent_of_every_point_in_the_bbox(
        double minLat, double minLng, double maxLat, double maxLng)
    {
        var svc = Service();
        var regions = svc.GetRegionIdsForBbox(minLat, minLng, maxLat, maxLng);
        Assert.NotEmpty(regions);

        // Dense sample grid across the bbox, including the exact corners.
        const int steps = 8;
        for (var i = 0; i <= steps; i++)
        {
            for (var j = 0; j <= steps; j++)
            {
                var lat = minLat + (maxLat - minLat) * i / steps;
                var lng = minLng + (maxLng - minLng) * j / steps;
                var parent = svc.GetParentCellId(svc.GetCellAtPoint(lat, lng).CellId);
                Assert.Contains(parent, regions);
            }
        }
    }

    [Fact]
    public void World_scale_bbox_returns_empty_meaning_do_not_prune()
    {
        // Thousands of parents would defeat the index; the empty set tells the caller to
        // fall back to the coordinate-only filter.
        Assert.Empty(Service().GetRegionIdsForBbox(-85, -180, 85, 180));
    }

    [Fact]
    public void Bbox_straddling_a_parent_boundary_covers_both_parents()
    {
        var svc = Service();
        // Find two adjacent points (~15 km apart) with different res-3 parents by scanning east.
        var lat = 12.9716;
        var lngA = 77.5946;
        var parentA = svc.GetParentCellId(svc.GetCellAtPoint(lat, lngA).CellId);
        var lngB = lngA;
        long parentB;
        do
        {
            lngB += 0.15;
            parentB = svc.GetParentCellId(svc.GetCellAtPoint(lat, lngB).CellId);
        } while (parentB == parentA && lngB < lngA + 10);
        Assert.NotEqual(parentA, parentB);

        var regions = svc.GetRegionIdsForBbox(lat - 0.01, lngA, lat + 0.01, lngB);
        Assert.Contains(parentA, regions);
        Assert.Contains(parentB, regions);
    }
}
