using MyLoop.Api.Constants;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Pure-logic tests (no database) for <see cref="HexGridService"/> — the H3 hex
/// grid math behind claim area, trail cells, and loop detection. These are the
/// numbers a spoofer tries to inflate and the ones walk history / leaderboard
/// disagree over when they drift, so the grid math is exercised directly with the
/// real <see cref="GeoService"/> (H3 is deterministic).
/// </summary>
public class HexGridServiceTests
{
    private static HexGridService Service() => new(new GeoService());

    // A point in San Francisco used as a stable anchor for cell lookups.
    private const double AnchorLat = 37.7749;
    private const double AnchorLng = -122.4194;

    /// <summary>Builds a closed square loop of <paramref name="pointsPerEdge"/>·4+1
    /// points whose last point equals the first.</summary>
    private static double[][] SquareLoop(double lat, double lng, double sizeDeg, int pointsPerEdge)
    {
        var corners = new[]
        {
            new[] { lat, lng },
            new[] { lat, lng + sizeDeg },
            new[] { lat + sizeDeg, lng + sizeDeg },
            new[] { lat + sizeDeg, lng },
        };
        var path = new List<double[]>();
        for (int c = 0; c < 4; c++)
        {
            var a = corners[c];
            var b = corners[(c + 1) % 4];
            for (int s = 0; s < pointsPerEdge; s++)
            {
                var t = (double)s / pointsPerEdge;
                path.Add(new[] { a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t });
            }
        }
        path.Add(new[] { corners[0][0], corners[0][1] }); // close it
        return path.ToArray();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(3000)]
    public void CalculateArea_is_cell_count_times_the_constant(int cells)
    {
        Assert.Equal(cells * GameConstants.CellAreaSquareMeters, Service().CalculateArea(cells));
    }

    [Fact]
    public void GetCellAtPoint_is_deterministic_for_the_same_point()
    {
        var svc = Service();
        Assert.Equal(
            svc.GetCellAtPoint(AnchorLat, AnchorLng).CellId,
            svc.GetCellAtPoint(AnchorLat, AnchorLng).CellId);
    }

    [Fact]
    public void GetCellAtPoint_returns_a_nonempty_boundary()
    {
        var cell = Service().GetCellAtPoint(AnchorLat, AnchorLng);
        Assert.NotEqual(0, cell.CellId);
        Assert.True(cell.Boundary.Length >= 6); // an H3 hexagon has 6 (rarely 5) vertices
    }

    [Fact]
    public void GetCellAtPoint_collapses_sub_metre_offsets_into_one_cell()
    {
        // ~1 m north stays inside the same res-11 hex (edge ≈ 20–25 m).
        var svc = Service();
        var a = svc.GetCellAtPoint(AnchorLat, AnchorLng).CellId;
        var b = svc.GetCellAtPoint(AnchorLat + 0.00001, AnchorLng).CellId;
        Assert.Equal(a, b);
    }

    [Fact]
    public void GetCellAtPoint_separates_distant_points()
    {
        // ~11 km away is many hexes over.
        var svc = Service();
        var a = svc.GetCellAtPoint(AnchorLat, AnchorLng).CellId;
        var b = svc.GetCellAtPoint(AnchorLat + 0.1, AnchorLng).CellId;
        Assert.NotEqual(a, b);
    }

    [Fact]
    public void GetCellCenter_round_trips_back_to_the_same_cell()
    {
        var svc = Service();
        var cellId = svc.GetCellAtPoint(AnchorLat, AnchorLng).CellId;
        var center = svc.GetCellCenter(cellId);
        Assert.Equal(cellId, svc.GetCellAtPoint(center.Lat, center.Lng).CellId);
    }

    [Fact]
    public void Parent_and_neighborhood_ids_are_stable_coarser_ancestors()
    {
        var svc = Service();
        var cellId = svc.GetCellAtPoint(AnchorLat, AnchorLng).CellId;

        var parent = svc.GetParentCellId(cellId);
        var neighborhood = svc.GetNeighborhoodId(cellId);

        Assert.NotEqual(cellId, parent);        // res-3 ancestor differs from res-11 cell
        Assert.NotEqual(cellId, neighborhood);  // res-8 ancestor differs too
        Assert.Equal(parent, svc.GetParentCellId(cellId));            // deterministic
        Assert.Equal(neighborhood, svc.GetNeighborhoodId(cellId));    // deterministic
    }

    [Fact]
    public void Adjacent_points_in_one_cell_share_a_parent()
    {
        var svc = Service();
        var c1 = svc.GetCellAtPoint(AnchorLat, AnchorLng).CellId;
        var c2 = svc.GetCellAtPoint(AnchorLat + 0.00001, AnchorLng).CellId;
        Assert.Equal(svc.GetParentCellId(c1), svc.GetParentCellId(c2));
    }

    [Fact]
    public void GetTrailCells_deduplicates_repeated_points()
    {
        var svc = Service();
        var path = new[]
        {
            new[] { AnchorLat, AnchorLng },
            new[] { AnchorLat, AnchorLng },
            new[] { AnchorLat, AnchorLng },
        };
        Assert.Single(svc.GetTrailCells(path));
    }

    [Fact]
    public void GetTrailCells_counts_distinct_hexes_along_a_spread_path()
    {
        // Three points ~11 km apart land in three different hexes.
        var svc = Service();
        var path = new[]
        {
            new[] { AnchorLat, AnchorLng },
            new[] { AnchorLat + 0.1, AnchorLng },
            new[] { AnchorLat + 0.2, AnchorLng },
        };
        Assert.Equal(3, svc.GetTrailCells(path).Count);
    }

    [Fact]
    public void HasClosedLoop_is_false_below_the_minimum_point_count()
    {
        var svc = Service();
        var shortPath = Enumerable.Range(0, GameConstants.MinLoopPoints - 1)
            .Select(i => new[] { AnchorLat + i * 0.0001, AnchorLng })
            .ToArray();
        Assert.False(svc.HasClosedLoop(shortPath));
    }

    [Fact]
    public void HasClosedLoop_is_false_for_an_open_straight_path()
    {
        // 30 points marching away in a straight line: endpoints are ~330 m apart,
        // well beyond the 50 m closure threshold, and no point revisits another.
        var svc = Service();
        var open = Enumerable.Range(0, 30)
            .Select(i => new[] { AnchorLat + i * 0.0001, AnchorLng })
            .ToArray();
        Assert.False(svc.HasClosedLoop(open));
    }

    [Fact]
    public void HasClosedLoop_is_true_when_the_path_returns_to_its_start()
    {
        // A 25-point square (~55 m sides) whose last point equals the first.
        var svc = Service();
        var loop = SquareLoop(AnchorLat, AnchorLng, 0.0005, 6);
        Assert.True(svc.HasClosedLoop(loop));
    }

    [Fact]
    public void ComputeCapturedTerritory_returns_the_trail_cells_it_walked()
    {
        var svc = Service();
        var loop = SquareLoop(AnchorLat, AnchorLng, 0.0005, 6);
        var territory = svc.ComputeCapturedTerritory(loop);

        // Every trail cell the path crosses must appear in the captured set.
        var trailIds = svc.GetTrailCells(loop).Select(c => c.CellId).ToHashSet();
        var capturedIds = territory.Cells.Select(c => c.CellId).ToHashSet();
        Assert.Superset(capturedIds, trailIds); // captured ⊇ trail (may add loop fill)
        Assert.NotEmpty(territory.Cells);
        Assert.True(territory.LoopCount >= 0);
    }

    [Fact]
    public void ComputeCapturedCells_matches_the_territory_cells()
    {
        var svc = Service();
        var loop = SquareLoop(AnchorLat, AnchorLng, 0.0005, 6);
        Assert.Equal(
            svc.ComputeCapturedTerritory(loop).Cells.Count,
            svc.ComputeCapturedCells(loop).Count);
    }
}
