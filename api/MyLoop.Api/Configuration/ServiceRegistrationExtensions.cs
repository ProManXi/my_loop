using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Services;

namespace MyLoop.Api.Configuration;

/// <summary>
/// Application service registrations, grouped by concern (SRP). Each method returns the service
/// collection for fluent chaining from Program.cs.
/// </summary>
public static class ServiceRegistrationExtensions
{
    public static IServiceCollection AddMyLoopDatabase(this IServiceCollection services, IConfiguration configuration) =>
        services.AddDbContext<AppDbContext>(options =>
            options.UseNpgsql(
                configuration.GetConnectionString("DefaultConnection"),
                // Neon scales to zero when idle; the first query after a cold start (or a pooled
                // connection dropped during suspension) surfaces as a transient failure. Retry it
                // transparently. NOTE: this installs a retrying execution strategy, so every
                // user-initiated transaction MUST run inside Database.CreateExecutionStrategy().
                npgsql => npgsql.EnableRetryOnFailure(
                    maxRetryCount: InfrastructureDefaults.DbMaxRetryCount,
                    maxRetryDelay: TimeSpan.FromSeconds(InfrastructureDefaults.DbMaxRetryDelaySeconds),
                    errorCodesToAdd: null)));

    /// <summary>Registers domain services, identity resolution, the geocoding client, and the decay,
    /// HexCount reconciliation, and leaderboard refresh background workers.</summary>
    public static IServiceCollection AddMyLoopServices(this IServiceCollection services)
    {
        services.AddScoped<IValidationService, ValidationService>();
        services.AddScoped<IGeoService, GeoService>();
        services.AddScoped<IHexGridService, HexGridService>();
        services.AddScoped<ITerritoryService, TerritoryService>();
        services.AddScoped<IUserService, UserService>();
        services.AddScoped<ILeaderboardService, LeaderboardService>();
        services.AddScoped<ITerritoryNotifier, TerritoryNotifier>();
        services.AddScoped<IPathValidationService, PathValidationService>();
        services.AddScoped<IPushNotificationService, PushNotificationService>();
        services.AddScoped<IMissionService, MissionService>();
        services.AddScoped<IAchievementService, AchievementService>();

        services.AddSingleton<GeocodingService>();
        // Bound external geocoding latency: Nominatim is best-effort and the service already falls
        // back gracefully, so cap each request well below the 100s HttpClient default to avoid
        // tying up request threads when the upstream is slow or unreachable.
        services.AddHttpClient<GeocodingService>(c =>
            c.Timeout = TimeSpan.FromSeconds(InfrastructureDefaults.GeocodingTimeoutSeconds));
        services.AddHostedService<DecayCleanupService>();
        // Backstop that repairs any HexCount drift back to the true owned-cell count.
        services.AddHostedService<HexCountReconciliationService>();
        // Recomputes the leaderboard snapshot on a timer instead of a client-triggered endpoint.
        services.AddHostedService<LeaderboardRefreshWorker>();

        services.AddHttpContextAccessor();
        services.AddMemoryCache();
        services.AddScoped<ICurrentUser, CurrentUser>();
        return services;
    }
}
