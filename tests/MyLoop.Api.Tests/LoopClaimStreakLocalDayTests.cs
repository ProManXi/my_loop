using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issues #106/#88 (ML-ERR-009): one walk updated the streak on two paths
/// that disagreed on which day it is. The batch-step path resolved the player's local day
/// (GameDay.Resolve) and called UpdateStreak(user, gameDay), but the final loop claim went
/// through UpdateUserStats → the parameterless UpdateStreak overload defaulting to UTC today.
/// For players ahead of UTC, the loop claim overwrote LastClaimDate with the UTC day the batch
/// drain had just stamped locally — off-by-one streak accounting near timezone boundaries.
/// The loop claim must stamp the SAME resolved game day as the batch path; the parameterless
/// overload is deleted so no caller can silently fall back to UTC.
/// </summary>
public class LoopClaimStreakLocalDayTests : IAsyncLifetime
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

    private static long CellOf(double lat) => (long)Math.Round(lat * 1000);

    private static TerritoryService NewService(AppDbContext db, IReadOnlyList<long>? loopCells = null)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.GetCellAtPoint(It.IsAny<double>(), It.IsAny<double>()))
            .Returns<double, double>((lat, lng) => new HexCell { CellId = CellOf(lat), Boundary = [[lat, lng]] });
        hex.Setup(h => h.ComputeCapturedCells(It.IsAny<double[][]>()))
            .Returns(() => (loopCells ?? [])
                .Select(id => new HexCell { CellId = id, Boundary = [[12.9, 77.5]] })
                .ToList());
        hex.Setup(h => h.HasClosedLoop(It.IsAny<double[][]>())).Returns(true);
        hex.Setup(h => h.CalculateArea(It.IsAny<int>())).Returns<int>(c => c * 2_150.0);
        hex.Setup(h => h.GetCellCenter(It.IsAny<long>())).Returns(new GeoCoordinate { Lat = 12.9, Lng = 77.5 });
        hex.Setup(h => h.GetParentCellId(It.IsAny<long>())).Returns(1L);
        hex.Setup(h => h.GetNeighborhoodId(It.IsAny<long>())).Returns(2L);

        var geo = new Mock<IGeoService>();
        geo.Setup(g => g.CalculatePathDistance(It.IsAny<double[][]>())).Returns(250.0);

        var notifier = new Mock<ITerritoryNotifier> { DefaultValue = DefaultValue.Empty };
        var push = new Mock<IPushNotificationService> { DefaultValue = DefaultValue.Empty };
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        missions.Setup(m => m.AwardXp(It.IsAny<Guid>(), It.IsAny<int>(), It.IsAny<string>()))
            .ReturnsAsync(new XpGainResult { TotalXp = 0, Level = 1, LeveledUp = false });
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };
        achievements.Setup(a => a.CheckAndUnlock(It.IsAny<Guid>()))
            .ReturnsAsync(new List<AchievementUnlock>());

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, NullLogger<TerritoryService>.Instance);
    }

    private static readonly double[][] LoopPath =
    [
        [12.900, 77.500], [12.901, 77.500], [12.901, 77.501], [12.900, 77.501],
        [12.900, 77.5005], [12.9005, 77.500], [12.9005, 77.501], [12.901, 77.5005],
        [12.9008, 77.5008], [12.900, 77.500],
    ];

    private async Task SeedUser(Guid userId, DateOnly? lastClaimDate = null, int streak = 0)
    {
        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid-{userId}",
            DisplayName = "U",
            Color = "#111111",
            LastClaimDate = lastClaimDate,
            Streak = streak,
            IsStreakActive = streak > 0,
        });
        await seed.SaveChangesAsync();
    }

    [Fact]
    public async Task Loop_claim_increments_the_streak_on_the_players_local_day()
    {
        var utcToday = DateOnly.FromDateTime(DateTime.UtcNow);
        var localToday = utcToday.AddDays(1); // player ahead of UTC (e.g. UTC+13, evening walk)

        // Their previous walk was on their local yesterday — which IS the current UTC day.
        var userId = Guid.NewGuid();
        await SeedUser(userId, lastClaimDate: utcToday, streak: 1);

        await using var db = NewDb();
        var result = await NewService(db, loopCells: [301L])
            .ProcessClaim(userId, LoopPath, Guid.NewGuid(), localToday.ToString("yyyy-MM-dd"));
        Assert.True(result.Success);

        // UTC "today" would be a same-day no-op (streak stuck at 1); the local day is
        // exactly yesterday+1 in the player's frame, so the streak must increment.
        await using var check = NewDb();
        var user = await check.Users.SingleAsync(u => u.Id == userId);
        Assert.Equal(2, user.Streak);
        Assert.Equal(localToday, user.LastClaimDate);
    }

    [Fact]
    public async Task Loop_and_batch_paths_stamp_the_same_local_day_for_the_same_walk_day()
    {
        var utcToday = DateOnly.FromDateTime(DateTime.UtcNow);
        var localToday = utcToday.AddDays(1);
        var localDate = localToday.ToString("yyyy-MM-dd");

        var loopUser = Guid.NewGuid();
        var batchUser = Guid.NewGuid();
        await SeedUser(loopUser);
        await SeedUser(batchUser);

        await using (var db = NewDb())
        {
            var result = await NewService(db, loopCells: [401L])
                .ProcessClaim(loopUser, LoopPath, Guid.NewGuid(), localDate);
            Assert.True(result.Success);
        }
        await using (var db = NewDb())
        {
            var response = await NewService(db).ProcessBatchStepClaim(
                batchUser, localDate,
                [new BatchStepPoint { ClientId = "p1", Lat = 1.001, Lng = 77.5, CapturedAt = DateTime.UtcNow }],
                Guid.NewGuid());
            Assert.Null(response.RejectionReason);
        }

        await using var check = NewDb();
        var loopStamped = (await check.Users.SingleAsync(u => u.Id == loopUser)).LastClaimDate;
        var batchStamped = (await check.Users.SingleAsync(u => u.Id == batchUser)).LastClaimDate;
        Assert.Equal(localToday, batchStamped);
        Assert.Equal(batchStamped, loopStamped); // one walk day, one "today" on both paths
    }
}
