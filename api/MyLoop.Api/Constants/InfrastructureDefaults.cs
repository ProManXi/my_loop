namespace MyLoop.Api.Constants;

/// <summary>
/// Infrastructure/runtime defaults (rate limiting, logging sinks, external timeouts, auth).
/// Kept separate from <see cref="GameConstants"/>, which is gameplay-only. Environment-specific
/// values (e.g. the Firebase project id) are overridable via configuration where noted.
/// </summary>
public static class InfrastructureDefaults
{
    // --- Database resilience (Neon serverless Postgres scale-to-zero cold starts) ---
    /// <summary>
    /// Max times Npgsql's retrying execution strategy re-runs an operation after a transient
    /// connection failure (e.g. a pooled connection dropped while Neon was scaled to zero).
    /// </summary>
    public const int DbMaxRetryCount = 5;
    /// <summary>Upper bound on the (exponential) delay between database retry attempts.</summary>
    public const int DbMaxRetryDelaySeconds = 10;

    // --- Rate limiting (per authenticated user, falling back to client IP) ---
    public const int RateLimitPermitLimit = 120;
    public const int RateLimitWindowSeconds = 60;
    public const int RateLimitQueueLimit = 0;

    // --- External geocoding (Nominatim is best-effort) ---
    public const int GeocodingTimeoutSeconds = 5;

    // --- Serilog rolling-file sink ---
    public const string LogDirectoryName = "logs";
    public const string LogFileNamePattern = "myloop-.log";
    public const int LogRetainedFileCountLimit = 7;
    public const long LogFileSizeLimitBytes = 50_000_000;

    // --- Mock walk simulation (#29) ---
    /// <summary>
    /// Header whose presence marks a request as originating from the in-app mock walk simulator.
    /// The Flutter client attaches it only in debug builds while a simulated walk is running. It is
    /// read in exactly one place — <c>MockLogContextMiddleware</c> — and branches logging only; no
    /// game logic, validation, or persistence inspects it, so a mock walk hits the identical server
    /// path (anti-cheat included) as a real one.
    /// </summary>
    public const string MockRequestHeader = "X-MyLoop-Mock";
    /// <summary>LogContext property set on mock requests so their events route to <see cref="MockLogDirectoryName"/>.</summary>
    public const string MockLogContextProperty = "IsMock";
    /// <summary>Directory (under the same root as <see cref="LogDirectoryName"/>) for segregated mock logs.</summary>
    public const string MockLogDirectoryName = "MockLogs";
    public const string MockLogFileNamePattern = "mock-.log";

    // --- CORS ---
    /// <summary>Fallback origin when no browser origins are configured (the native client is CORS-exempt).</summary>
    public const string DefaultCorsOrigin = "http://localhost";

    // --- Firebase authentication ---
    /// <summary>Config key for the Firebase project id; overrides <see cref="DefaultFirebaseProjectId"/>.</summary>
    public const string FirebaseProjectIdConfigKey = "Authentication:Firebase:ProjectId";
    public const string DefaultFirebaseProjectId = "myloop-6aefc";
    /// <summary>Authority/issuer template; the audience is the project id itself.</summary>
    public const string FirebaseAuthorityFormat = "https://securetoken.google.com/{0}";

    // --- FCM push notifications (#103 / ML-ERR-006) ---
    /// <summary>Feature flag config key; false (the default) keeps push notifications log-only.</summary>
    public const string PushEnabledConfigKey = "Push:Enabled";
    /// <summary>Config key for the Firebase service-account JSON path; set via the gitignored appsettings.Development.json locally, or a deployment secret in production.</summary>
    public const string PushFirebaseServiceAccountPathConfigKey = "Push:Firebase:ServiceAccountPath";
}
