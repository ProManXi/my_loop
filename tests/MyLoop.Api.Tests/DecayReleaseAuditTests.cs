using Microsoft.EntityFrameworkCore;
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
/// Regression tests for issue #104 (ML-ERR-007): the decay reaper deleted cells silently —
/// no event for clients (ghost territory until the next viewport poll), no audit row (decay
/// invisible to the claim-pipeline event trail), and an unindexable per-row interval
/// predicate. The release now returns the deleted set for a post-commit HexesReleased
/// broadcast, writes Reason=Decay CellTransfer rows, scans the stored DecayAt column, and
/// the revenge list excludes decay rows.
/// </summary>
public class DecayReleaseAuditTests : IAsyncLifetime
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

    private async Task<Guid> SeedOwnerWithCells(
        long decayedCellId, long freshCellId, long parentCellId)
    {
        var userId = Guid.NewGuid();
        var claimId = Guid.NewGuid();
        var now = DateTime.UtcNow;
        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid-{userId}",
            DisplayName = "D",
            Color = "#555555",
            HexCount = 2,
        });
        seed.Claims.Add(new Claim { Id = claimId, UserId = userId, CellCount = 2, CreatedAt = now });
        seed.TerritoryCells.Add(Cell(decayedCellId, userId, claimId, parentCellId,
            lastRefreshed: now.AddDays(-10), decayDays: 7)); // decayed 3 days ago
        seed.TerritoryCells.Add(Cell(freshCellId, userId, claimId, parentCellId,
            lastRefreshed: now, decayDays: 7));
        await seed.SaveChangesAsync();
        return userId;
    }

    private static TerritoryCell Cell(
        long cellId, Guid ownerId, Guid claimId, long parentCellId,
        DateTime lastRefreshed, int decayDays)
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
            ParentCellId = parentCellId,
            NeighborhoodId = 2L,
            DecayDays = decayDays,
        };
        cell.SetBoundary([[12.9, 77.5]]);
        return cell;
    }

    [Fact]
    public async Task Release_returns_the_deleted_set_writes_a_decay_audit_row_and_decrements()
    {
        var userId = await SeedOwnerWithCells(4001L, 4002L, parentCellId: 71L);

        List<DecayedCellRow> released;
        await using (var db = NewDb())
            released = await DecayCleanupService.ReleaseDecayedCellsAsync(
                db, DecayCleanupService.DecayBatchSize, CancellationToken.None);

        // The deleted set is materialized for the post-commit broadcast.
        var row = Assert.Single(released, r => r.OwnerId == userId);
        Assert.Equal(4001L, row.CellId);
        Assert.Equal(71L, row.ParentCellId);
        var evt = Assert.Single(DecayCleanupService.ToReleaseEvents([row]));
        Assert.Equal("4001", evt.H3Index);
        Assert.Equal(71L, evt.ParentCellId);

        await using var check = NewDb();
        // Only the decayed cell is gone; HexCount decremented by exactly the released count.
        Assert.Null(await check.TerritoryCells.FindAsync(4001L));
        Assert.NotNull(await check.TerritoryCells.FindAsync(4002L));
        Assert.Equal(1, (await check.Users.SingleAsync(u => u.Id == userId)).HexCount);

        // The event trail records the release: FromUserId == ToUserId == loser, Reason=Decay.
        var audit = await check.CellTransfers.SingleAsync(t => t.CellId == 4001L);
        Assert.Equal(TransferReason.Decay, audit.Reason);
        Assert.Equal(userId, audit.FromUserId);
        Assert.Equal(userId, audit.ToUserId);
        Assert.Equal(Guid.Empty, audit.ClaimId);
    }

    [Fact]
    public async Task Decay_rows_do_not_pollute_the_revenge_list()
    {
        var victim = Guid.NewGuid();
        var attacker = Guid.NewGuid();
        await using (var seed = NewDb())
        {
            seed.Users.AddRange(
                new User { Id = victim, FirebaseUid = $"v-{victim}", DisplayName = "V", Color = "#1" },
                new User { Id = attacker, FirebaseUid = $"a-{attacker}", DisplayName = "A", Color = "#2" });
            seed.CellTransfers.AddRange(
                new CellTransfer
                {
                    Id = Guid.NewGuid(), CellId = 5001L, FromUserId = victim, ToUserId = attacker,
                    ClaimId = Guid.NewGuid(), TransferredAt = DateTime.UtcNow, Reason = TransferReason.Capture,
                },
                new CellTransfer
                {
                    Id = Guid.NewGuid(), CellId = 5002L, FromUserId = victim, ToUserId = victim,
                    ClaimId = Guid.Empty, TransferredAt = DateTime.UtcNow, Reason = TransferReason.Decay,
                });
            await seed.SaveChangesAsync();
        }

        await using var db = NewDb();
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };
        var service = new TerritoryService(
            db, Mock.Of<IHexGridService>(), Mock.Of<IGeoService>(),
            Mock.Of<ITerritoryNotifier>(), Mock.Of<IPathValidationService>(),
            Mock.Of<IPushNotificationService>(),
            new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, NullLogger<TerritoryService>.Instance);

        var revenge = await service.GetStolenCells(victim, days: 7);

        // Losing a hex to the reaper is not a theft: only the real steal is listed.
        Assert.Equal(1, revenge.TotalStolen);
        Assert.Equal(attacker, Assert.Single(revenge.Cells).ToUserId);
    }

    [Fact]
    public async Task Startup_patch_backfills_decay_schema_and_is_idempotent()
    {
        await using var db = NewDb();
        // Simulate a pre-fix database: no DecayAt column/index, no Reason column,
        // and the old (unusable) decay helper index present.
        await db.Database.ExecuteSqlRawAsync(@"DROP INDEX IF EXISTS ""IX_TerritoryCells_DecayAt""");
        await db.Database.ExecuteSqlRawAsync(@"ALTER TABLE ""TerritoryCells"" DROP COLUMN IF EXISTS ""DecayAt""");
        await db.Database.ExecuteSqlRawAsync(@"ALTER TABLE ""CellTransfers"" DROP COLUMN IF EXISTS ""Reason""");
        await db.Database.ExecuteSqlRawAsync(@"
            CREATE INDEX IF NOT EXISTS ""IX_TerritoryCells_Decay""
            ON ""TerritoryCells"" (""LastRefreshedAt"", ""DecayDays"")");

        DbInitializer.ApplyDecayReleaseSchema(db);
        DbInitializer.ApplyDecayReleaseSchema(db); // idempotent

        var decayAtIndexed = await db.Database.SqlQueryRaw<bool>(@"
            SELECT EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE tablename = 'TerritoryCells' AND indexname = 'IX_TerritoryCells_DecayAt'
            ) AS ""Value""").SingleAsync();
        var oldIndexGone = await db.Database.SqlQueryRaw<bool>(@"
            SELECT NOT EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE tablename = 'TerritoryCells' AND indexname = 'IX_TerritoryCells_Decay'
            ) AS ""Value""").SingleAsync();
        Assert.True(decayAtIndexed);
        Assert.True(oldIndexGone);

        // The regenerated column computes: a freshly seeded decayed cell is reaped.
        var userId = await SeedOwnerWithCells(6001L, 6002L, parentCellId: 72L);
        var released = await DecayCleanupService.ReleaseDecayedCellsAsync(
            db, DecayCleanupService.DecayBatchSize, CancellationToken.None);
        Assert.Contains(released, r => r.CellId == 6001L && r.OwnerId == userId);
    }
}
