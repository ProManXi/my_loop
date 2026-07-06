using System.Diagnostics;
using MyLoop.Api.Constants;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// #116 / ML-ERR-019: the spatial-hash loop-closure scan must return the EXACT same result as
/// the original O(n²) brute-force scan, while being fast enough that a max-size path can't be a
/// CPU DoS. These tests keep an in-test brute-force reference and assert equivalence over many
/// randomized walks, plus a worst-case timing smoke test.
/// </summary>
public class HexGridLoopClosureEquivalenceTests
{
    private static HexGridService Service() => new(new GeoService());
    private static readonly GeoService Geo = new();

    // ── Brute-force reference implementations (the pre-#116 semantics) ──────────

    private static bool BruteHasClosedLoop(double[][] path)
    {
        if (path.Length < GameConstants.MinLoopPoints) return false;
        for (var i = GameConstants.LoopSkipNeighbors; i < path.Length; i++)
        {
            for (var j = 0; j <= i - GameConstants.MinLoopPoints; j++)
            {
                if (Geo.HaversineMeters(path[i][0], path[i][1], path[j][0], path[j][1])
                    <= GameConstants.LoopClosureDistanceMeters)
                    return true;
            }
        }
        return BruteIsLoopClosed(path);
    }

    private static bool BruteIsLoopClosed(double[][] path)
    {
        if (path.Length < GameConstants.MinLoopPoints) return false;
        return Geo.HaversineMeters(path[0][0], path[0][1], path[^1][0], path[^1][1])
               <= GameConstants.LoopClosureDistanceMeters;
    }

    private static List<double[][]> BruteFindClosureLoops(double[][] path)
    {
        var loops = new List<double[][]>();
        var used = new bool[path.Length];
        for (var i = GameConstants.LoopSkipNeighbors; i < path.Length; i++)
        {
            if (used[i]) continue;
            for (var j = 0; j <= i - GameConstants.MinLoopPoints; j++)
            {
                if (used[j]) continue;
                if (Geo.HaversineMeters(path[i][0], path[i][1], path[j][0], path[j][1])
                    > GameConstants.LoopClosureDistanceMeters) continue;

                var loopLength = i - j + 1;
                var loop = new double[loopLength][];
                Array.Copy(path, j, loop, 0, loopLength);
                loops.Add(loop);
                for (var k = j; k <= i; k++) used[k] = true;
                break;
            }
        }
        return loops;
    }

    // ── Randomized walk generator ──────────────────────────────────────────────

    /// <summary>
    /// A meandering GPS-like walk around a base coordinate: small random steps with occasional
    /// backtracking so real loop closures occur. Base latitudes span the globe so the longitude
    /// cell-sizing (which uses max |lat|) is exercised at high latitude too.
    /// </summary>
    private static double[][] RandomWalk(Random rng, int length, double baseLat, double baseLng)
    {
        var pts = new double[length][];
        var lat = baseLat;
        var lng = baseLng;
        for (var i = 0; i < length; i++)
        {
            pts[i] = new[] { lat, lng };
            // ~0-15 m steps; degrees scaled so the step is metric-consistent at this latitude.
            var stepLat = (rng.NextDouble() - 0.5) * 30.0 / GameConstants.MetersPerDegreeLat;
            var cosLat = Math.Max(Math.Cos(lat * Math.PI / 180.0), 0.01);
            var stepLng = (rng.NextDouble() - 0.5) * 30.0 / (GameConstants.MetersPerDegreeLat * cosLat);
            lat += stepLat;
            lng += stepLng;
        }
        return pts;
    }

    [Fact]
    public void HasClosedLoop_matches_brute_force_over_many_random_walks()
    {
        var rng = new Random(20260706);
        var svc = Service();
        var baseLats = new[] { 0.0, 12.9, 37.7, 51.5, 60.2, -33.9 };

        for (var t = 0; t < 300; t++)
        {
            var length = rng.Next(GameConstants.MinLoopPoints, 320);
            var baseLat = baseLats[rng.Next(baseLats.Length)];
            var path = RandomWalk(rng, length, baseLat, rng.NextDouble() * 100 - 50);

            Assert.Equal(BruteHasClosedLoop(path), svc.HasClosedLoop(path));
        }
    }

    [Fact]
    public void FindClosureLoops_produces_identical_loop_sets_over_many_random_walks()
    {
        var rng = new Random(99991);
        var svc = Service();
        var baseLats = new[] { 0.0, 25.3, 37.7, 55.0, 61.0, -41.0 };

        for (var t = 0; t < 300; t++)
        {
            var length = rng.Next(GameConstants.MinLoopPoints, 320);
            var baseLat = baseLats[rng.Next(baseLats.Length)];
            var path = RandomWalk(rng, length, baseLat, rng.NextDouble() * 100 - 50);

            var expected = BruteFindClosureLoops(path);
            var actual = new List<double[][]>();
            svc.FindClosureLoops(path, new bool[path.Length], actual);

            Assert.Equal(expected.Count, actual.Count);
            for (var k = 0; k < expected.Count; k++)
            {
                // Same loop = same start/end indices ⇒ same length and endpoint coordinates.
                Assert.Equal(expected[k].Length, actual[k].Length);
                Assert.Equal(expected[k][0], actual[k][0]);
                Assert.Equal(expected[k][^1], actual[k][^1]);
            }
        }
    }

    [Fact]
    public void MaxSize_path_scan_is_fast_enough_to_not_be_a_dos()
    {
        var rng = new Random(4242);
        var svc = Service();
        // A realistic max-length spread walk (the cap is now MaxClaimPathPoints).
        var path = RandomWalk(rng, GameConstants.MaxClaimPathPoints, 37.7749, -122.4194);

        var sw = Stopwatch.StartNew();
        svc.HasClosedLoop(path);
        svc.FindClosureLoops(path, new bool[path.Length], new List<double[][]>());
        sw.Stop();

        // Brute force here would be tens of millions of haversines. Generous ceiling to stay
        // robust on slow CI while still catching an accidental reintroduction of O(n²).
        Assert.True(sw.ElapsedMilliseconds < 750,
            $"loop-closure scan took {sw.ElapsedMilliseconds} ms for {path.Length} points");
    }
}
