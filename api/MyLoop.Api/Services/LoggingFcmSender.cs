using MyLoop.Api.Interfaces;

namespace MyLoop.Api.Services;

/// <summary>
/// No-op <see cref="IFcmSender"/> that logs instead of calling Firebase. Registered whenever
/// <c>Push:Enabled</c> is false or no service-account credential is configured — the safe
/// default for local dev and CI, which have no live Firebase project.
/// </summary>
public class LoggingFcmSender : IFcmSender
{
    private readonly ILogger<LoggingFcmSender> _logger;

    public LoggingFcmSender(ILogger<LoggingFcmSender> logger)
    {
        _logger = logger;
    }

    public Task<IReadOnlyList<FcmSendOutcome>> SendEachAsync(IReadOnlyList<string> tokens, string title, string body)
    {
        foreach (var token in tokens)
        {
            _logger.LogInformation(
                "PUSH (disabled) [{Token}]: {Title} — {Body}",
                token[..Math.Min(token.Length, 10)], title, body);
        }

        IReadOnlyList<FcmSendOutcome> outcomes = tokens
            .Select(token => new FcmSendOutcome(token, Success: true, IsUnregistered: false))
            .ToList();
        return Task.FromResult(outcomes);
    }
}
