using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Data;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #124 (ML-ERR-027): Claims had no index at all, yet the per-day
/// cap count (UserId + CreatedAt window) runs inside every claim transaction and claim history
/// groups over the same predicate — a per-claim seq scan once claim volume grows. The
/// (UserId, CreatedAt) index must exist on fresh databases (EnsureCreated from the model) and
/// be patched idempotently onto existing databases at startup (DbInitializer).
/// </summary>
public class ClaimIndexTests : IAsyncLifetime
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

    private static Task<bool> ClaimIndexExists(AppDbContext db) =>
        db.Database.SqlQueryRaw<bool>(@"
            SELECT EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE tablename = 'Claims' AND indexname = 'IX_Claims_UserId_CreatedAt'
            ) AS ""Value""").SingleAsync();

    [Fact]
    public async Task Fresh_database_has_the_claim_cap_index()
    {
        await using var db = NewDb();
        Assert.True(await ClaimIndexExists(db));
    }

    [Fact]
    public async Task Startup_patch_restores_the_index_on_existing_databases_and_is_idempotent()
    {
        await using var db = NewDb();
        // Simulate a database created before this fix.
        await db.Database.ExecuteSqlRawAsync(@"DROP INDEX IF EXISTS ""IX_Claims_UserId_CreatedAt""");
        Assert.False(await ClaimIndexExists(db));

        DbInitializer.ApplyTerritoryIndexes(db);
        Assert.True(await ClaimIndexExists(db));

        DbInitializer.ApplyTerritoryIndexes(db); // idempotent re-run
        Assert.True(await ClaimIndexExists(db));
    }
}
