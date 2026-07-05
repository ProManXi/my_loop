using MyLoop.Api.Constants;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Pure-logic tests (no database) for <see cref="GeoService"/> — the geographic
/// math that underpins distance-based anti-cheat (speed gates), walk-distance
/// missions, and claim-area accounting. Expected values are derived from the
/// documented sphere radius (<see cref="GameConstants.EarthRadiusMeters"/>) and
/// the flat-projection constants, so they track the constants rather than a
/// hardcoded magic number.
/// </summary>
public class GeoServiceTests
{
    private static GeoService Service() => new();

    // One degree of arc on the configured sphere, in metres: R * (π/180).
    private static readonly double MetersPerDegreeArc =
        GameConstants.EarthRadiusMeters * Math.PI / 180.0;

    [Fact]
    public void Haversine_between_identical_points_is_zero()
    {
        Assert.Equal(0.0, Service().HaversineMeters(40.0, -74.0, 40.0, -74.0), precision: 6);
    }

    [Fact]
    public void Haversine_one_degree_of_latitude_matches_arc_length()
    {
        // Meridian distance is independent of longitude: 1° lat == R·(π/180).
        var d = Service().HaversineMeters(0.0, 0.0, 1.0, 0.0);
        Assert.Equal(MetersPerDegreeArc, d, precision: 1); // ≈ 111_194.9 m
    }

    [Fact]
    public void Haversine_one_degree_of_longitude_at_equator_matches_arc_length()
    {
        // At the equator cos(lat)=1, so 1° lng equals the same arc length as 1° lat.
        var d = Service().HaversineMeters(0.0, 0.0, 0.0, 1.0);
        Assert.Equal(MetersPerDegreeArc, d, precision: 1);
    }

    [Fact]
    public void Haversine_longitude_shrinks_with_latitude()
    {
        // A degree of longitude at 60° covers ~half the ground distance of one at
        // the equator (cos 60° = 0.5).
        var svc = Service();
        var atEquator = svc.HaversineMeters(0.0, 0.0, 0.0, 1.0);
        var atSixty = svc.HaversineMeters(60.0, 0.0, 60.0, 1.0);
        Assert.True(atSixty < atEquator);
        Assert.Equal(0.5, atSixty / atEquator, precision: 2);
    }

    [Fact]
    public void Haversine_is_symmetric()
    {
        var svc = Service();
        var ab = svc.HaversineMeters(51.5074, -0.1278, 48.8566, 2.3522); // London↔Paris
        var ba = svc.HaversineMeters(48.8566, 2.3522, 51.5074, -0.1278);
        Assert.Equal(ab, ba, precision: 6);
        // London–Paris great-circle distance is ~343 km; allow a wide band.
        Assert.InRange(ab, 330_000, 360_000);
    }

    [Fact]
    public void PathDistance_of_empty_or_single_point_is_zero()
    {
        var svc = Service();
        Assert.Equal(0.0, svc.CalculatePathDistance(Array.Empty<double[]>()));
        Assert.Equal(0.0, svc.CalculatePathDistance(new[] { new[] { 1.0, 2.0 } }));
    }

    [Fact]
    public void PathDistance_sums_consecutive_segments()
    {
        var svc = Service();
        var path = new[]
        {
            new[] { 0.0, 0.0 },
            new[] { 0.0, 1.0 },
            new[] { 0.0, 2.0 },
        };
        var expected =
            svc.HaversineMeters(0, 0, 0, 1) + svc.HaversineMeters(0, 1, 0, 2);
        Assert.Equal(expected, svc.CalculatePathDistance(path), precision: 6);
    }

    [Fact]
    public void PolygonArea_of_degenerate_polygon_is_zero()
    {
        var svc = Service();
        Assert.Equal(0.0, svc.CalculatePolygonArea(Array.Empty<double[]>()));
        Assert.Equal(0.0, svc.CalculatePolygonArea(new[] { new[] { 0.0, 0.0 }, new[] { 0.0, 1.0 } }));
    }

    [Fact]
    public void PolygonArea_of_small_square_approximates_side_squared()
    {
        // A ~0.001° square near the equator projects to roughly 111.32 m per side.
        var svc = Service();
        var square = new[]
        {
            new[] { 0.0, 0.0 },
            new[] { 0.0, 0.001 },
            new[] { 0.001, 0.001 },
            new[] { 0.001, 0.0 },
        };
        var side = 0.001 * GameConstants.MetersPerDegreeLat; // ≈ 111.32 m
        var expected = side * side;                          // ≈ 12_392 m²
        Assert.Equal(expected, svc.CalculatePolygonArea(square), expected * 0.01); // within 1%
    }

    [Fact]
    public void PolygonArea_is_orientation_independent()
    {
        // Shoelace takes the absolute value, so winding order must not matter.
        var svc = Service();
        var cw = new[]
        {
            new[] { 0.0, 0.0 },
            new[] { 0.0, 0.001 },
            new[] { 0.001, 0.001 },
            new[] { 0.001, 0.0 },
        };
        var ccw = new[]
        {
            new[] { 0.0, 0.0 },
            new[] { 0.001, 0.0 },
            new[] { 0.001, 0.001 },
            new[] { 0.0, 0.001 },
        };
        Assert.Equal(svc.CalculatePolygonArea(cw), svc.CalculatePolygonArea(ccw), precision: 6);
    }
}
