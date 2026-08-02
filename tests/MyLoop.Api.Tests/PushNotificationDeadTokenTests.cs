using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #103 (ML-ERR-006): the FCM send path used to be a stub that only
/// logged, so it never sent anything and never pruned dead tokens. Verifies
/// <see cref="PushNotificationService.NotifyHexStolen"/> batches every victim token into one
/// <see cref="IFcmSender"/> call and deletes exactly the tokens FCM reports as unregistered.
/// </summary>
public class PushNotificationDeadTokenTests : IAsyncLifetime
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

    /// <summary>Records every batch it was asked to send and returns canned per-token outcomes.</summary>
    private sealed class FakeFcmSender : IFcmSender
    {
        public List<IReadOnlyList<string>> Calls { get; } = new();
        public Func<IReadOnlyList<string>, IReadOnlyList<FcmSendOutcome>>? OutcomeFactory { get; set; }

        public Task<IReadOnlyList<FcmSendOutcome>> SendEachAsync(IReadOnlyList<string> tokens, string title, string body)
        {
            Calls.Add(tokens);
            IReadOnlyList<FcmSendOutcome> outcomes = OutcomeFactory?.Invoke(tokens)
                ?? tokens.Select(t => new FcmSendOutcome(t, Success: true, IsUnregistered: false)).ToList();
            return Task.FromResult(outcomes);
        }
    }

    private async Task<Guid> SeedUserWithTokens(AppDbContext db, params string[] tokens)
    {
        var userId = Guid.NewGuid();
        db.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid{userId}",
            DisplayName = "Victim",
            Color = "#111111",
        });
        foreach (var token in tokens)
        {
            db.DeviceTokens.Add(new DeviceToken
            {
                Id = Guid.NewGuid(),
                UserId = userId,
                Token = token,
                Platform = "ios",
            });
        }
        await db.SaveChangesAsync();
        return userId;
    }

    [Fact]
    public async Task A_dead_token_response_prunes_only_that_row()
    {
        await using var seed = NewDb();
        var userId = await SeedUserWithTokens(seed, "token-alive", "token-dead");

        var sender = new FakeFcmSender
        {
            OutcomeFactory = tokens => tokens
                .Select(t => new FcmSendOutcome(t, Success: t != "token-dead", IsUnregistered: t == "token-dead"))
                .ToList(),
        };

        await using var db = NewDb();
        var service = new PushNotificationService(db, sender, NullLogger<PushNotificationService>.Instance);

        await service.NotifyHexStolen(userId, "Thief", stolenCount: 2);

        await using var check = NewDb();
        var remaining = await check.DeviceTokens.Where(t => t.UserId == userId).Select(t => t.Token).ToListAsync();
        Assert.Equal(new[] { "token-alive" }, remaining);
    }

    [Fact]
    public async Task All_of_a_victims_tokens_are_sent_in_a_single_batched_call()
    {
        await using var seed = NewDb();
        var userId = await SeedUserWithTokens(seed, "token-a", "token-b", "token-c");

        var sender = new FakeFcmSender();

        await using var db = NewDb();
        var service = new PushNotificationService(db, sender, NullLogger<PushNotificationService>.Instance);

        await service.NotifyHexStolen(userId, "Thief", stolenCount: 3);

        var call = Assert.Single(sender.Calls);
        Assert.Equal(new[] { "token-a", "token-b", "token-c" }, call.OrderBy(t => t));
    }

    [Fact]
    public async Task No_tokens_means_no_send_and_no_query()
    {
        await using var seed = NewDb();
        var userId = Guid.NewGuid();
        seed.Users.Add(new User { Id = userId, FirebaseUid = $"uid{userId}", DisplayName = "NoDevice", Color = "#222222" });
        await seed.SaveChangesAsync();

        var sender = new FakeFcmSender();

        await using var db = NewDb();
        var service = new PushNotificationService(db, sender, NullLogger<PushNotificationService>.Instance);

        await service.NotifyHexStolen(userId, "Thief", stolenCount: 1);

        Assert.Empty(sender.Calls);
    }

    [Fact]
    public async Task An_fcm_send_failure_is_swallowed_not_propagated_to_the_caller()
    {
        await using var seed = NewDb();
        var userId = await SeedUserWithTokens(seed, "token-a");

        var sender = new ThrowingFcmSender();

        await using var db = NewDb();
        var service = new PushNotificationService(db, sender, NullLogger<PushNotificationService>.Instance);

        // Territory has already changed hands by the time this runs (post-commit) — a push
        // failure must never surface as an error on the thief's claim request.
        await service.NotifyHexStolen(userId, "Thief", stolenCount: 1);

        await using var check = NewDb();
        Assert.Equal(1, await check.DeviceTokens.CountAsync(t => t.UserId == userId));
    }

    private sealed class ThrowingFcmSender : IFcmSender
    {
        public Task<IReadOnlyList<FcmSendOutcome>> SendEachAsync(IReadOnlyList<string> tokens, string title, string body)
            => throw new InvalidOperationException("Simulated FCM outage");
    }
}
