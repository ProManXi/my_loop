using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Integration tests (real PostgreSQL via Testcontainers) for the HexCount data-integrity fix:
///
/// 1. Decay releases cells and decrements HexCount from the SAME batched set, so a backlog larger
///    than the per-run cap can never double-count against HexCount (the drift bug).
/// 2. The reconciliation backstop repairs any drifted HexCount back to the true owned-cell count.
///
/// See vault bug: bug-2026-07-02-hexcount-decay-drift-no-reconciliation.
/// </summary>
public class HexCountDecayReconciliationTests : IAsyncLifetime
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

    private static User NewUser(Guid id, int hexCount) =>
        new() { Id = id, FirebaseUid = $"uid-{id}", DisplayName = "P", Color = "#111111", HexCount = hexCount };

    /// <summary>Seeds the owning user plus a backing claim (required FK for the cells).</summary>
    private static Guid SeedOwner(AppDbContext db, Guid userId, int hexCount)
    {
        db.Users.Add(NewUser(userId, hexCount));
        var claimId = Guid.NewGuid();
        db.Claims.Add(new Claim { Id = claimId, UserId = userId, CellCount = 0, AreaM2 = 0 });
        return claimId;
    }

    /// <summary>Adds <paramref name="count"/> cells owned by <paramref name="owner"/> under
    /// <paramref name="claimId"/>. <paramref name="decayed"/> controls whether they are already
    /// past their decay window.</summary>
    private static void AddCells(
        AppDbContext db, Guid owner, Guid claimId, int count, bool decayed, long cellIdBase)
    {
        var now = DateTime.UtcNow;
        for (var i = 0; i < count; i++)
        {
            db.TerritoryCells.Add(new TerritoryCell
            {
                CellId = cellIdBase + i,
                OwnerId = owner,
                ClaimId = claimId,
                ClaimedAt = now,
                CenterLat = 12.9,
                CenterLng = 77.5,
                ParentCellId = 1,
                NeighborhoodId = 2,
                // Decayed: refreshed long ago with a 1-day window. Fresh: refreshed now, 30-day window.
                LastRefreshedAt = decayed ? now.AddDays(-100) : now,
                DecayDays = decayed ? 1 : 30,
            });
        }
    }

    [Fact]
    public async Task Decay_backlog_over_batch_size_decrements_once_per_released_cell()
    {
        var user = Guid.NewGuid();
        const int decayedCount = 8;
        const int freshCount = 10;
        const int batchSize = 5; // < decayedCount, forcing a multi-run backlog

        await using (var seed = NewDb())
        {
            // HexCount starts at the true owned total (18). Fresh cells must survive; only the
            // 8 decayed cells should be released, leaving HexCount == 10 == remaining COUNT.
            var claimId = SeedOwner(seed, user, hexCount: decayedCount + freshCount);
            AddCells(seed, user, claimId, decayedCount, decayed: true, cellIdBase: 1_000);
            AddCells(seed, user, claimId, freshCount, decayed: false, cellIdBase: 2_000);
            await seed.SaveChangesAsync();
        }

        // Run 1: releases `batchSize` decayed cells, decrementing HexCount by exactly that many.
        await using (var db = NewDb())
        {
            var released = await DecayCleanupService.ReleaseDecayedCellsAsync(db, batchSize, CancellationToken.None);
            Assert.Equal(batchSize, released);
        }
        await AssertHexCountMatchesOwnedCount(user, expected: decayedCount + freshCount - batchSize);

        // Run 2: drains the remaining decayed backlog (3), never touching the fresh cells.
        await using (var db = NewDb())
        {
            var released = await DecayCleanupService.ReleaseDecayedCellsAsync(db, batchSize, CancellationToken.None);
            Assert.Equal(decayedCount - batchSize, released);
        }

        // The bug would have decremented HexCount for ALL decayed cells on each run (8 then 3),
        // landing at 7. The fix decrements once per released cell, landing at the true count 10.
        await AssertHexCountMatchesOwnedCount(user, expected: freshCount);

        // Run 3: nothing left to decay — no-op, HexCount unchanged.
        await using (var db = NewDb())
        {
            var released = await DecayCleanupService.ReleaseDecayedCellsAsync(db, batchSize, CancellationToken.None);
            Assert.Equal(0, released);
        }
        await AssertHexCountMatchesOwnedCount(user, expected: freshCount);
    }

    [Fact]
    public async Task Reconciliation_repairs_drifted_hexcounts_to_true_owned_count()
    {
        var under = Guid.NewGuid();   // owns 10, stored 3  (drifted low — the decay-bug symptom)
        var over = Guid.NewGuid();    // owns 0, stored 5   (drifted high)
        var correct = Guid.NewGuid(); // owns 4, stored 4   (already correct — must be untouched)

        await using (var seed = NewDb())
        {
            var underClaim = SeedOwner(seed, under, hexCount: 3);
            SeedOwner(seed, over, hexCount: 5);  // owns 0 cells → must be repaired down to 0
            var correctClaim = SeedOwner(seed, correct, hexCount: 4);
            AddCells(seed, under, underClaim, 10, decayed: false, cellIdBase: 10_000);
            AddCells(seed, correct, correctClaim, 4, decayed: false, cellIdBase: 20_000);
            await seed.SaveChangesAsync();
        }

        int repaired;
        await using (var db = NewDb())
        {
            repaired = await HexCountReconciliationService.ReconcileAsync(db, CancellationToken.None);
        }

        // Only the two drifted rows are rewritten; the already-correct row is skipped.
        Assert.Equal(2, repaired);
        await AssertHexCountMatchesOwnedCount(under, expected: 10);
        await AssertHexCountMatchesOwnedCount(over, expected: 0);
        await AssertHexCountMatchesOwnedCount(correct, expected: 4);
    }

    private async Task AssertHexCountMatchesOwnedCount(Guid userId, int expected)
    {
        await using var db = NewDb();
        var hexCount = (await db.Users.AsNoTracking().SingleAsync(u => u.Id == userId)).HexCount;
        var ownedCount = await db.TerritoryCells.AsNoTracking().CountAsync(c => c.OwnerId == userId);

        Assert.Equal(expected, hexCount);
        Assert.Equal(expected, ownedCount);
    }
}
