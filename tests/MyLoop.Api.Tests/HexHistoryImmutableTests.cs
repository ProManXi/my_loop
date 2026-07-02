using System.Net.Http;
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
/// Integration tests (real PostgreSQL via Testcontainers) proving the Home "Hex History" summary is
/// an immutable record derived from the append-only Claims log — not live TerritoryCells — so a past
/// day's captured count does not shrink when those hexes later decay or are stolen.
///
/// See vault bug: bug-2026-07-02-hex-history-derives-from-live-cells-not-immutable-claims.
/// </summary>
public class HexHistoryImmutableTests : IAsyncLifetime
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

    // GetClaimHistory only touches the DbContext; the other dependencies are inert here.
    private TerritoryService NewService(AppDbContext db) => new(
        db,
        Mock.Of<IHexGridService>(),
        Mock.Of<IGeoService>(),
        Mock.Of<ITerritoryNotifier>(),
        Mock.Of<IPathValidationService>(),
        Mock.Of<IPushNotificationService>(),
        new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
        Mock.Of<IMissionService>(),
        Mock.Of<IAchievementService>(),
        NullLogger<TerritoryService>.Instance);

    private static Claim NewClaim(Guid userId, int cellCount, DateTime createdAt) => new()
    {
        Id = Guid.NewGuid(),
        UserId = userId,
        CellCount = cellCount,
        AreaM2 = cellCount * GameConstants.CellAreaSquareMeters,
        CreatedAt = createdAt,
    };

    [Fact]
    public async Task Hex_history_sums_the_claim_log_and_does_not_shrink_when_cells_are_removed()
    {
        var userId = Guid.NewGuid();
        var day1 = DateTime.UtcNow.AddDays(-3);
        var day2 = DateTime.UtcNow.AddDays(-1);

        await using (var seed = NewDb())
        {
            seed.Users.Add(new User { Id = userId, FirebaseUid = $"uid-{userId}", DisplayName = "P", Color = "#111111" });
            // Two walks on day1 (5 + 3 cells) and one on day2 (4 cells).
            var claimA = NewClaim(userId, 5, day1);
            seed.Claims.AddRange(claimA, NewClaim(userId, 3, day1), NewClaim(userId, 4, day2));
            // Some cells the player currently owns from day1's first walk — these will be deleted
            // below to simulate later decay/theft.
            for (var i = 0; i < 5; i++)
            {
                seed.TerritoryCells.Add(new TerritoryCell
                {
                    CellId = 5_000 + i,
                    OwnerId = userId,
                    ClaimId = claimA.Id,
                    ClaimedAt = day1,
                    CenterLat = 12.9,
                    CenterLng = 77.5,
                    ParentCellId = 1,
                    NeighborhoodId = 2,
                    LastRefreshedAt = day1,
                    DecayDays = 7,
                });
            }
            await seed.SaveChangesAsync();
        }

        // day1 total = 8 (5+3), day2 total = 4, ordered most-recent first.
        List<Models.ClaimHistoryEntry> before;
        await using (var db = NewDb())
        {
            before = await NewService(db).GetClaimHistory(userId);
        }
        Assert.Equal(2, before.Count);
        Assert.Equal(4, before[0].CellCount); // day2
        Assert.Equal(8, before[1].CellCount); // day1
        Assert.Equal(8 * GameConstants.CellAreaSquareMeters, before[1].AreaM2);

        // Simulate the player LOSING all of day1's currently-owned hexes (decay / steal).
        await using (var db = NewDb())
        {
            await db.TerritoryCells.Where(c => c.OwnerId == userId).ExecuteDeleteAsync();
        }

        // The history is unchanged — it reads the immutable claim log, not live cells.
        // (The old implementation grouped live TerritoryCells and would now report nothing for day1.)
        await using (var db = NewDb())
        {
            var after = await NewService(db).GetClaimHistory(userId);
            Assert.Equal(before.Count, after.Count);
            Assert.Equal(before[0].CellCount, after[0].CellCount);
            Assert.Equal(before[1].CellCount, after[1].CellCount);
        }
    }
}
