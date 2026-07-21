using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for ML-ERR-020 (issue #117): ProcessBatchStepClaim silently truncated
/// oversized batches to 200 points. The controller already rejects them, but if that guard
/// ever drifts, truncated points would never be ACKed back to the client — and the mobile
/// WAL drainer only removes ACKed clientIds, so the dropped points would jam the queue
/// forever. The service must fail loud, not truncate.
/// </summary>
public class BatchStepPointCapTests
{
    [Fact]
    public void MaxBatchStepPoints_covers_the_client_drain_batch_size()
    {
        // The mobile drainer sends at most 50 points per batch; the shared cap must
        // never shrink below that or every full-size client batch would be rejected.
        Assert.True(GameConstants.MaxBatchStepPoints >= 50,
            $"MaxBatchStepPoints = {GameConstants.MaxBatchStepPoints} is below the client's max batch size");
    }

    [Fact]
    public async Task Oversized_batch_throws_instead_of_silently_truncating()
    {
        // Connection string is never used: the cap guard must reject the batch
        // before any database work happens.
        var db = new AppDbContext(new DbContextOptionsBuilder<AppDbContext>()
            .UseNpgsql("Host=localhost;Port=1;Database=never;Username=never;Password=never;Timeout=1")
            .Options);
        var service = new TerritoryService(
            db, Mock.Of<IHexGridService>(), Mock.Of<IGeoService>(),
            Mock.Of<ITerritoryNotifier>(), Mock.Of<IPathValidationService>(),
            Mock.Of<IPushNotificationService>(),
            new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            Mock.Of<IMissionService>(), Mock.Of<IAchievementService>(),
            Mock.Of<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);

        var oversized = Enumerable.Range(0, GameConstants.MaxBatchStepPoints + 1)
            .Select(i => new BatchStepPoint
            {
                ClientId = $"pt-{i}",
                Lat = 12.9,
                Lng = 77.5,
                CapturedAt = DateTime.UtcNow,
            })
            .ToList();

        await Assert.ThrowsAsync<ArgumentException>(() =>
            service.ProcessBatchStepClaim(Guid.NewGuid(), null, oversized, Guid.NewGuid()));
    }
}
