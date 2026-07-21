using System.Collections.Concurrent;
using System.Text.Json;
using MyLoop.Api.Models;

namespace MyLoop.Api.Services;

/// <summary>
/// Reverse geocodes coordinates to area names using Nominatim (OpenStreetMap).
/// Results are cached in-memory since area names don't change.
/// </summary>
public class GeocodingService
{
    private readonly HttpClient _http;
    private readonly ILogger<GeocodingService> _logger;
    private readonly ConcurrentDictionary<string, string> _cache = new();
    private readonly ConcurrentDictionary<string, LocationInfo> _locationCache = new();
    private readonly SemaphoreSlim _throttle = new(1, 1); // 1 req/sec Nominatim policy
    private DateTime _lastRequest = DateTime.MinValue;

    public GeocodingService(HttpClient http, ILogger<GeocodingService> logger)
    {
        _http = http;
        _logger = logger;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("MyLoop/1.0 (territory-game)");
    }

    /// <summary>
    /// Returns a human-readable area name for the given coordinates.
    /// Falls back to "Area" if geocoding fails.
    /// </summary>
    public async Task<string> GetAreaName(double lat, double lng)
    {
        var cacheKey = $"{lat:F4},{lng:F4}";
        if (_cache.TryGetValue(cacheKey, out var cached))
            return cached;

        await _throttle.WaitAsync();
        try
        {
            // Nominatim rate limit: 1 request per second
            var elapsed = DateTime.UtcNow - _lastRequest;
            if (elapsed.TotalMilliseconds < 1100)
                await Task.Delay(1100 - (int)elapsed.TotalMilliseconds);

            var url = $"https://nominatim.openstreetmap.org/reverse?lat={lat}&lon={lng}&format=json&zoom=16&addressdetails=1";
            var response = await _http.GetAsync(url);
            _lastRequest = DateTime.UtcNow;

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Nominatim area lookup returned {StatusCode}; using fallback name",
                    (int)response.StatusCode);
                return CacheAndReturn(cacheKey, FallbackName(lat, lng));
            }

            var json = await response.Content.ReadAsStringAsync();
            var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            // Try to extract: suburb > neighbourhood > city_district > city
            var name = TryExtractName(root);
            return CacheAndReturn(cacheKey, name ?? FallbackName(lat, lng));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Nominatim area lookup failed; using fallback name");
            return CacheAndReturn(cacheKey, FallbackName(lat, lng));
        }
        finally
        {
            _throttle.Release();
        }
    }

    private static string? TryExtractName(JsonElement root)
    {
        if (!root.TryGetProperty("address", out var addr))
            return null;

        // Priority: suburb → neighbourhood → city_district → town → city
        string[] priorities = ["suburb", "neighbourhood", "city_district", "town", "city", "municipality"];
        foreach (var key in priorities)
        {
            if (addr.TryGetProperty(key, out var val))
            {
                var name = val.GetString();
                if (!string.IsNullOrWhiteSpace(name))
                    return name;
            }
        }

        // Fallback to display_name first part
        if (root.TryGetProperty("display_name", out var display))
        {
            var full = display.GetString();
            if (!string.IsNullOrEmpty(full))
                return full.Split(',')[0].Trim();
        }

        return null;
    }

    private string CacheAndReturn(string key, string value)
    {
        _cache.TryAdd(key, value);
        return value;
    }

    /// <summary>
    /// The "Area (lat, lng)" placeholder used when Nominatim is unreachable. Also exposed to
    /// callers (e.g. <see cref="TerritoryService.GetExplorationStats"/>) that need an immediate
    /// name without waiting on a geocode call at all.
    /// </summary>
    public static string FallbackName(double lat, double lng)
        => $"Area ({lat:F2}, {lng:F2})";

    /// <summary>
    /// Returns full location info (city, state, country) for onboarding's home lookup.
    /// Results are cached per 2-decimal coordinate bucket (~1.1km) — coarser than the
    /// area-name cache since city/state/country boundaries don't need street precision.
    /// </summary>
    public async Task<LocationInfo> GetLocationInfo(double lat, double lng)
    {
        var cacheKey = $"loc:{lat:F2},{lng:F2}";
        if (_locationCache.TryGetValue(cacheKey, out var cached))
            return cached;

        await _throttle.WaitAsync();
        try
        {
            var elapsed = DateTime.UtcNow - _lastRequest;
            if (elapsed.TotalMilliseconds < 1100)
                await Task.Delay(1100 - (int)elapsed.TotalMilliseconds);

            var url = $"https://nominatim.openstreetmap.org/reverse?lat={lat}&lon={lng}&format=json&zoom=10&addressdetails=1";
            var response = await _http.GetAsync(url);
            _lastRequest = DateTime.UtcNow;

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Nominatim location lookup returned {StatusCode}; using empty location",
                    (int)response.StatusCode);
                return CacheLocationAndReturn(cacheKey, new LocationInfo());
            }

            var json = await response.Content.ReadAsStringAsync();
            var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            if (!root.TryGetProperty("address", out var addr))
                return CacheLocationAndReturn(cacheKey, new LocationInfo());

            var info = new LocationInfo
            {
                City = ExtractField(addr, "city", "town", "municipality", "village"),
                State = ExtractField(addr, "state", "province", "region", "state_district"),
                Country = ExtractField(addr, "country"),
                CountryCode = ExtractField(addr, "country_code"),
            };
            info.Continent = ContinentFromCountryCode(info.CountryCode);

            return CacheLocationAndReturn(cacheKey, info);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Nominatim location lookup failed; using empty location");
            return CacheLocationAndReturn(cacheKey, new LocationInfo());
        }
        finally
        {
            _throttle.Release();
        }
    }

    private static string ExtractField(JsonElement addr, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (addr.TryGetProperty(key, out var val))
            {
                var str = val.GetString();
                if (!string.IsNullOrWhiteSpace(str)) return str;
            }
        }
        return "";
    }

    private LocationInfo CacheLocationAndReturn(string key, LocationInfo info)
    {
        _locationCache.TryAdd(key, info);
        return info;
    }

    private static string ContinentFromCountryCode(string code)
    {
        if (string.IsNullOrEmpty(code)) return "";
        code = code.ToUpperInvariant();
        // Simplified continent mapping by country code
        return code switch
        {
            "US" or "CA" or "MX" or "GT" or "BZ" or "HN" or "SV" or "NI" or "CR" or "PA"
                or "CU" or "JM" or "HT" or "DO" or "PR" or "TT" => "NA",
            "BR" or "AR" or "CO" or "VE" or "PE" or "CL" or "EC" or "BO" or "PY" or "UY"
                or "GY" or "SR" => "SA",
            "GB" or "DE" or "FR" or "IT" or "ES" or "PT" or "NL" or "BE" or "SE" or "NO"
                or "DK" or "FI" or "PL" or "CZ" or "AT" or "CH" or "IE" or "GR" or "RO"
                or "BG" or "HR" or "SK" or "HU" or "UA" or "RU" or "BY" or "LT" or "LV"
                or "EE" or "RS" or "BA" or "ME" or "MK" or "AL" or "SI" or "IS" or "LU"
                or "MT" or "CY" or "MD" or "GE" or "AM" or "AZ" => "EU",
            "IN" or "CN" or "JP" or "KR" or "ID" or "TH" or "VN" or "PH" or "MY" or "SG"
                or "BD" or "PK" or "LK" or "NP" or "MM" or "KH" or "LA" or "TW" or "HK"
                or "MO" or "MN" or "KZ" or "UZ" or "TM" or "KG" or "TJ" or "AF"
                or "IR" or "IQ" or "SA" or "AE" or "QA" or "KW" or "OM" or "YE" or "JO"
                or "LB" or "SY" or "IL" or "PS" or "BH" or "TR" => "AS",
            "AU" or "NZ" or "FJ" or "PG" or "WS" or "TO" => "OC",
            _ => "AF" // Default remaining to Africa
        };
    }
}
