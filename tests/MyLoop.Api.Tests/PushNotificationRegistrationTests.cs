using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using MyLoop.Api.Configuration;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #103 (ML-ERR-006): with no <c>Push:Enabled</c>/service-account
/// configuration — the state of local dev and CI, which have no live Firebase project —
/// registration must resolve the logging no-op sender, never attempt to touch the real Firebase
/// Admin SDK, and never throw.
/// </summary>
public class PushNotificationRegistrationTests
{
    private static IServiceProvider BuildProvider(Dictionary<string, string?> config)
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(config).Build();
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddMyLoopPushNotifications(configuration);
        return services.BuildServiceProvider();
    }

    [Fact]
    public void No_push_config_resolves_the_logging_sender()
    {
        var provider = BuildProvider(new Dictionary<string, string?>());

        var sender = provider.GetRequiredService<IFcmSender>();

        Assert.IsType<LoggingFcmSender>(sender);
    }

    [Fact]
    public void Enabled_with_no_service_account_path_still_resolves_the_logging_sender()
    {
        // A misconfiguration (flag on, no credential) must fail safe, not attempt a Firebase call
        // that would throw with no default app configured.
        var provider = BuildProvider(new Dictionary<string, string?> { ["Push:Enabled"] = "true" });

        var sender = provider.GetRequiredService<IFcmSender>();

        Assert.IsType<LoggingFcmSender>(sender);
    }
}
