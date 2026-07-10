using System.Data.Common;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #122 (ML-ERR-025): <c>UserService.DeleteUserData</c> issued 8
/// sequential <c>ExecuteDeleteAsync</c> statements (plus the user row's own delete) with no
/// transaction — a mid-sequence failure left an orphaned partial purge (e.g. cells deleted but
/// Claims/LeaderboardEntries intact and the user row still alive). The whole purge now runs
/// inside one transaction, wrapped in <c>CreateExecutionStrategy().ExecuteAsync</c> so Neon's
/// <c>EnableRetryOnFailure</c> can still retry a dropped connection.
/// </summary>
public class AccountDeletionTransactionTests : IAsyncLifetime
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

    private AppDbContext NewDb(IInterceptor? interceptor = null)
    {
        var builder = new DbContextOptionsBuilder<AppDbContext>().UseNpgsql(_conn);
        if (interceptor != null)
            builder.AddInterceptors(interceptor);
        return new AppDbContext(builder.Options);
    }

    /// <summary>
    /// Seeds one user with exactly one row in every table <c>DeleteUserData</c> purges, so a test
    /// can assert "all deleted" or "none deleted" unambiguously.
    /// </summary>
    private async Task<Guid> SeedUserWithOneRowPerTable()
    {
        var userId = Guid.NewGuid();
        var claimId = Guid.NewGuid();
        const long cellId = 555_000_111L;

        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid-{userId}",
            DisplayName = "Deletable",
            Color = "#123456",
        });
        seed.Claims.Add(new Claim { Id = claimId, UserId = userId, CellCount = 1, AreaM2 = 100.0 });
        seed.TerritoryCells.Add(new TerritoryCell
        {
            CellId = cellId,
            OwnerId = userId,
            ClaimId = claimId,
            CenterLat = 12.9,
            CenterLng = 77.5,
            ClaimedAt = DateTime.UtcNow,
            LastRefreshedAt = DateTime.UtcNow,
        });
        seed.Set<CellTransfer>().Add(new CellTransfer
        {
            Id = Guid.NewGuid(),
            CellId = cellId,
            FromUserId = null,
            ToUserId = userId,
            ClaimId = claimId,
            TransferredAt = DateTime.UtcNow,
        });
        seed.LeaderboardEntries.Add(new LeaderboardEntry
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            Date = DateOnly.FromDateTime(DateTime.UtcNow),
            CellCount = 1,
            AreaM2 = 100.0,
            Rank = 1,
        });
        seed.ExploredCells.Add(new ExploredCell
        {
            UserId = userId,
            CellId = cellId,
            NeighborhoodId = 1L,
            FirstVisitedAt = DateTime.UtcNow,
        });
        seed.DailyMissions.Add(new DailyMission
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            Date = DateOnly.FromDateTime(DateTime.UtcNow),
            Type = MissionType.CaptureHexes,
            TargetValue = 5,
            XpReward = 80,
            Description = "d",
        });
        seed.UserAchievements.Add(new UserAchievement
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            AchievementId = "first_capture",
            UnlockedAt = DateTime.UtcNow,
            XpAwarded = 50,
        });
        seed.DeviceTokens.Add(new DeviceToken
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            Token = "fcm-token",
        });
        await seed.SaveChangesAsync();
        return userId;
    }

    private static UserService NewUserService(AppDbContext db) =>
        new(db, new ValidationService(), NullLogger<UserService>.Instance);

    private async Task AssertRowCountsForUser(Guid userId, int expected)
    {
        await using var check = NewDb();
        Assert.Equal(expected, await check.Users.CountAsync(u => u.Id == userId));
        Assert.Equal(expected, await check.TerritoryCells.CountAsync(c => c.OwnerId == userId));
        Assert.Equal(expected, await check.Set<CellTransfer>().CountAsync(t => t.ToUserId == userId));
        Assert.Equal(expected, await check.Claims.CountAsync(c => c.UserId == userId));
        Assert.Equal(expected, await check.LeaderboardEntries.CountAsync(l => l.UserId == userId));
        Assert.Equal(expected, await check.ExploredCells.CountAsync(e => e.UserId == userId));
        Assert.Equal(expected, await check.DailyMissions.CountAsync(m => m.UserId == userId));
        Assert.Equal(expected, await check.UserAchievements.CountAsync(a => a.UserId == userId));
        Assert.Equal(expected, await check.DeviceTokens.CountAsync(d => d.UserId == userId));
    }

    /// <summary>
    /// Throws once the Nth non-query command executes — simulating a transient failure
    /// mid-purge (e.g. the 4th of the 8 `ExecuteDeleteAsync` statements).
    /// </summary>
    private sealed class FailOnNthCommandInterceptor(int failOnCommandNumber) : DbCommandInterceptor
    {
        private int _count;

        public override InterceptionResult<int> NonQueryExecuting(
            DbCommand command, CommandEventData eventData, InterceptionResult<int> result)
        {
            if (++_count == failOnCommandNumber)
                throw new InvalidOperationException("Simulated failure mid-purge");
            return result;
        }

        public override ValueTask<InterceptionResult<int>> NonQueryExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<int> result,
            CancellationToken cancellationToken = default)
        {
            if (++_count == failOnCommandNumber)
                throw new InvalidOperationException("Simulated failure mid-purge");
            return new ValueTask<InterceptionResult<int>>(result);
        }
    }

    [Fact]
    public async Task Failure_partway_through_the_purge_rolls_back_everything()
    {
        var userId = await SeedUserWithOneRowPerTable();

        // The 1st-3rd ExecuteDeleteAsync statements (TerritoryCells, CellTransfers, Claims)
        // succeed; the 4th (LeaderboardEntries) throws before the transaction commits.
        await using var db = NewDb(new FailOnNthCommandInterceptor(failOnCommandNumber: 4));
        await Assert.ThrowsAsync<InvalidOperationException>(
            () => NewUserService(db).DeleteAccount(userId));

        // Nothing is deleted — the first 3 statements' deletes were rolled back with the rest.
        await AssertRowCountsForUser(userId, expected: 1);
    }

    [Fact]
    public async Task Successful_purge_removes_every_row_in_every_table()
    {
        var userId = await SeedUserWithOneRowPerTable();

        await using var db = NewDb();
        var deleted = await NewUserService(db).DeleteAccount(userId);

        Assert.True(deleted);
        await AssertRowCountsForUser(userId, expected: 0);
    }

    [Fact]
    public async Task Deleting_a_nonexistent_user_returns_false_and_changes_nothing()
    {
        await using var db = NewDb();
        var deleted = await NewUserService(db).DeleteAccount(Guid.NewGuid());

        Assert.False(deleted);
    }
}
