using H3;
using H3.Algorithms;
using H3.Extensions;
using H3.Model;
using NetTopologySuite.Geometries;
using NetTopologySuite.Geometries.Utilities;
using MyLoop.Api.Constants;
using MyLoop.Api.Models;

namespace MyLoop.Api.Services;

public class HexGridService : IHexGridService
{
    private readonly IGeoService _geoService;
    private static readonly GeometryFactory GeomFactory = new();

    public HexGridService(IGeoService geoService)
    {
        _geoService = geoService;
    }

    public List<HexCell> ComputeCapturedCells(double[][] path)
        => ComputeCapturedTerritory(path).Cells;

    public CapturedTerritory ComputeCapturedTerritory(double[][] path)
    {
        var allCells = new Dictionary<long, double[][]>();

        AddTrailCells(path, allCells);
        var loopCount = AddLoopFillCells(path, allCells);

        var cells = allCells
            .Select(p => new HexCell { CellId = p.Key, Boundary = p.Value })
            .ToList();

        return new CapturedTerritory(cells, loopCount);
    }

    public List<HexCell> GetTrailCells(double[][] points)
    {
        var cells = new Dictionary<long, double[][]>();
        AddTrailCells(points, cells);
        return cells
            .Select(p => new HexCell { CellId = p.Key, Boundary = p.Value })
            .ToList();
    }

    public HexCell GetCellAtPoint(double lat, double lng)
    {
        var index = PointToH3Index(lat, lng);
        var cellId = (long)(ulong)index;
        return new HexCell
        {
            CellId = cellId,
            Boundary = GetCellBoundaryVertices(index),
        };
    }

    public GeoCoordinate GetCellCenter(long cellId)
    {
        var latLng = ToH3Index(cellId).ToLatLng();
        return new GeoCoordinate
        {
            Lat = latLng.LatitudeDegrees,
            Lng = latLng.LongitudeDegrees
        };
    }

    public long GetParentCellId(long cellId)
    {
        var parent = ToH3Index(cellId).GetParentForResolution(GameConstants.H3ParentResolution);
        return (long)(ulong)parent;
    }

    public long GetNeighborhoodId(long cellId)
    {
        var parent = ToH3Index(cellId).GetParentForResolution(GameConstants.H3NeighborhoodResolution);
        return (long)(ulong)parent;
    }

    public bool IsValidRegionId(string regionId)
    {
        if (!long.TryParse(regionId, out var cellId))
            return false;

        var index = ToH3Index(cellId);
        return index.IsValidCell && index.Resolution == GameConstants.H3ParentResolution;
    }

    public double CalculateArea(int cellCount)
    {
        return cellCount * GameConstants.CellAreaSquareMeters;
    }

    public bool HasClosedLoop(double[][] path)
    {
        if (path.Length < GameConstants.MinLoopPoints) return false;

        // Spatial hash instead of the previous O(n²) all-pairs haversine scan (#116): with
        // MaxClaimPathPoints at 50k that admitted ~2.5×10⁹ haversines per request, a pure-CPU
        // DoS on the pre-transaction claim path. The index only surfaces points within the
        // closure radius, and the exact haversine check below preserves the original semantics.
        var index = ClosureSpatialIndex.Build(path);
        for (int i = GameConstants.LoopSkipNeighbors; i < path.Length; i++)
        {
            var maxJ = i - GameConstants.MinLoopPoints;
            foreach (var j in index.Candidates(path[i][0], path[i][1]))
            {
                if (j > maxJ) continue;
                var dist = _geoService.HaversineMeters(
                    path[i][0], path[i][1], path[j][0], path[j][1]);
                if (dist <= GameConstants.LoopClosureDistanceMeters) return true;
            }
        }

        return IsLoopClosed(path);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Trail cells — hexes the GPS path physically crosses
    // ──────────────────────────────────────────────────────────────────────────

    private void AddTrailCells(double[][] path, Dictionary<long, double[][]> cells)
    {
        foreach (var point in path)
        {
            var index = PointToH3Index(point[0], point[1]);
            var cellId = (long)(ulong)index;

            if (!cells.ContainsKey(cellId))
            {
                cells[cellId] = GetCellBoundaryVertices(index);
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Loop detection and interior fill
    // ──────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// Fills the interiors of the path's valid, de-duplicated loops into
    /// <paramref name="cells"/> and returns how many distinct loops were filled.
    /// This count — area-validated and de-duplicated, not the raw closure count —
    /// is the authoritative number of loops the user actually made (issue #21).
    /// </summary>
    private int AddLoopFillCells(double[][] path, Dictionary<long, double[][]> cells)
    {
        var loops = ExtractLoops(path);
        if (loops.Count == 0) return 0;

        var polygons = BuildValidPolygons(loops);
        if (polygons.Count == 0) return 0;

        var unique = DeduplicatePolygons(polygons);
        FillPolygonInteriors(unique, cells);
        return unique.Count;
    }

    private List<Geometry> BuildValidPolygons(List<double[][]> loops)
    {
        var result = new List<Geometry>();
        foreach (var loop in loops)
        {
            var area = _geoService.CalculatePolygonArea(loop);
            if (area < GameConstants.MinFillAreaSquareMeters) continue;

            var poly = BuildRepairedPolygon(loop);
            if (poly is { IsEmpty: false } && poly.Area > 0)
                result.Add(poly);
        }
        return result;
    }

    private static void FillPolygonInteriors(List<Geometry> polygons, Dictionary<long, double[][]> cells)
    {
        foreach (var poly in polygons)
        {
            try
            {
                var interiorCells = poly.Fill(GameConstants.H3Resolution);
                foreach (var cell in interiorCells)
                {
                    var id = (long)(ulong)cell;
                    if (!cells.ContainsKey(id))
                    {
                        cells[id] = GetCellBoundaryVertices(cell);
                    }
                }
            }
            catch { /* Skip loops that fail geometry operations */ }
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Loop extraction — detects closed sub-paths in the GPS trail
    // ──────────────────────────────────────────────────────────────────────────

    private List<double[][]> ExtractLoops(double[][] path)
    {
        if (path.Length < GameConstants.MinLoopPoints) return [];

        var loops = new List<double[][]>();
        var used = new bool[path.Length];

        FindClosureLoops(path, used, loops);

        if (loops.Count == 0 && IsLoopClosed(path))
        {
            loops.Add(path);
        }

        loops.Sort((a, b) =>
            _geoService.CalculatePolygonArea(b).CompareTo(_geoService.CalculatePolygonArea(a)));

        return loops;
    }

    // internal (not private) so the equivalence test can drive it directly against a brute-force
    // reference; InternalsVisibleTo MyLoop.Api.Tests is configured in the csproj.
    internal void FindClosureLoops(double[][] path, bool[] used, List<double[][]> loops)
    {
        // Spatial hash replacing the previous O(n²) inner scan (#116). The original picked, for
        // each i, the SMALLEST unused j ≤ i-MinLoopPoints within the closure radius; we reproduce
        // that exactly by taking the minimum qualifying candidate the index surfaces. The index is
        // a superset of all within-radius points, and the haversine check below is unchanged, so
        // the loop set is identical to the brute-force version (proven by the equivalence test).
        var index = ClosureSpatialIndex.Build(path);
        for (int i = GameConstants.LoopSkipNeighbors; i < path.Length; i++)
        {
            if (used[i]) continue;

            var maxJ = i - GameConstants.MinLoopPoints;
            var bestJ = -1;
            foreach (var j in index.Candidates(path[i][0], path[i][1]))
            {
                if (j > maxJ || used[j] || j >= bestJ && bestJ != -1) continue;

                var dist = _geoService.HaversineMeters(
                    path[i][0], path[i][1],
                    path[j][0], path[j][1]);

                if (dist <= GameConstants.LoopClosureDistanceMeters)
                    bestJ = j;
            }

            if (bestJ < 0) continue;

            var loopLength = i - bestJ + 1;
            var loop = new double[loopLength][];
            Array.Copy(path, bestJ, loop, 0, loopLength);
            loops.Add(loop);

            for (int k = bestJ; k <= i; k++)
                used[k] = true;
        }
    }

    private bool IsLoopClosed(double[][] path)
    {
        if (path.Length < GameConstants.MinLoopPoints) return false;
        var start = path[0];
        var end = path[^1];
        return _geoService.HaversineMeters(start[0], start[1], end[0], end[1])
               <= GameConstants.LoopClosureDistanceMeters;
    }

    /// <summary>
    /// Uniform-grid spatial hash over a GPS path used to find loop-closure candidates without an
    /// O(n²) all-pairs scan (#116). Each grid cell is sized so that BOTH its north-south and
    /// east-west extent are ≥ <see cref="GameConstants.LoopClosureDistanceMeters"/> everywhere on
    /// the path: cell height is fixed at the closure distance, and cell width uses the path's
    /// maximum absolute latitude (where a degree of longitude is shortest, so cells are widest in
    /// meters elsewhere). Because the north-south and east-west separations of any two points are
    /// each ≤ their great-circle distance, two points within the closure radius differ by ≤ one
    /// cell on each axis — so scanning a point's own cell plus its 8 neighbours is a guaranteed
    /// superset of its within-radius partners. The caller applies the exact haversine test, so
    /// results are identical to the brute-force scan.
    /// </summary>
    private sealed class ClosureSpatialIndex
    {
        private readonly Dictionary<(int, int), List<int>> _buckets;
        private readonly double _degPerCellLat;
        private readonly double _degPerCellLng;

        private ClosureSpatialIndex(
            Dictionary<(int, int), List<int>> buckets, double degPerCellLat, double degPerCellLng)
        {
            _buckets = buckets;
            _degPerCellLat = degPerCellLat;
            _degPerCellLng = degPerCellLng;
        }

        public static ClosureSpatialIndex Build(double[][] path)
        {
            var maxAbsLat = 0.0;
            foreach (var p in path)
                maxAbsLat = Math.Max(maxAbsLat, Math.Abs(p[0]));

            var degPerCellLat = GameConstants.LoopClosureDistanceMeters / GameConstants.MetersPerDegreeLat;
            // Clamp cos away from 0 so a (degenerate) near-polar path can't produce an infinite
            // cell width; no real walk occurs there.
            var cosLat = Math.Max(Math.Cos(maxAbsLat * Math.PI / 180.0), 0.01);
            var degPerCellLng = GameConstants.LoopClosureDistanceMeters / (GameConstants.MetersPerDegreeLat * cosLat);

            var buckets = new Dictionary<(int, int), List<int>>();
            for (var i = 0; i < path.Length; i++)
            {
                var key = CellKey(path[i][0], path[i][1], degPerCellLat, degPerCellLng);
                if (!buckets.TryGetValue(key, out var list))
                {
                    list = new List<int>();
                    buckets[key] = list;
                }
                list.Add(i); // ascending index order preserved
            }

            return new ClosureSpatialIndex(buckets, degPerCellLat, degPerCellLng);
        }

        /// <summary>
        /// Yields every point index in the query point's own cell and its 8 neighbours — a
        /// superset of the points within the closure radius (never fewer).
        /// </summary>
        public IEnumerable<int> Candidates(double lat, double lng)
        {
            var (bx, by) = CellKey(lat, lng, _degPerCellLat, _degPerCellLng);
            for (var dx = -1; dx <= 1; dx++)
            {
                for (var dy = -1; dy <= 1; dy++)
                {
                    if (_buckets.TryGetValue((bx + dx, by + dy), out var list))
                    {
                        foreach (var idx in list)
                            yield return idx;
                    }
                }
            }
        }

        private static (int, int) CellKey(double lat, double lng, double degPerCellLat, double degPerCellLng)
            => ((int)Math.Floor(lat / degPerCellLat), (int)Math.Floor(lng / degPerCellLng));
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Polygon repair and deduplication
    // ──────────────────────────────────────────────────────────────────────────

    private static Geometry? BuildRepairedPolygon(double[][] loop)
    {
        if (loop.Length < 4) return null;

        var coordinates = loop.Select(p => new Coordinate(p[1], p[0])).ToList();

        if (coordinates[0] != coordinates[^1])
            coordinates.Add(coordinates[0]);

        try
        {
            var ring = GeomFactory.CreateLinearRing(coordinates.ToArray());
            var rawPolygon = GeomFactory.CreatePolygon(ring);

            Geometry repaired;
            try { repaired = rawPolygon.Buffer(0); }
            catch { repaired = GeometryFixer.Fix(rawPolygon); }

            return repaired is { IsEmpty: false, Area: > 0 } ? repaired : null;
        }
        catch { return null; }
    }

    private static List<Geometry> DeduplicatePolygons(List<Geometry> polygons)
    {
        if (polygons.Count <= 1) return polygons;

        var sorted = polygons.OrderByDescending(p => p.Area).ToList();
        var kept = new List<Geometry>();

        foreach (var candidate in sorted)
        {
            if (!IsDuplicateOf(candidate, kept))
                kept.Add(candidate);
        }

        return kept;
    }

    private static bool IsDuplicateOf(Geometry candidate, List<Geometry> existing)
    {
        foreach (var other in existing)
        {
            try
            {
                var intersection = other.Intersection(candidate);
                if (intersection.Area / candidate.Area > GameConstants.DeduplicationOverlapThreshold)
                    return true;
            }
            catch (TopologyException) { /* Can't compare — treat as unique */ }
        }
        return false;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // H3 index helpers
    // ──────────────────────────────────────────────────────────────────────────

    private static H3Index PointToH3Index(double lat, double lng)
    {
        var latRad = lat * Math.PI / 180.0;
        var lngRad = lng * Math.PI / 180.0;
        return H3Index.FromLatLng(new LatLng(latRad, lngRad), GameConstants.H3Resolution);
    }

    private static H3Index ToH3Index(long cellId)
    {
        return (H3Index)(ulong)cellId;
    }

    // Computed on demand. A previous version memoized this in an unbounded static
    // ConcurrentDictionary keyed by cell id, which leaked ~500 B per distinct res-11 cell
    // ever touched — unbounded growth on a long-lived server accumulating players across
    // cities (#115). The H3 boundary math is microseconds and each cell is already computed
    // at most once per request (the caller de-duplicates by cell id), so the cross-request
    // cache bought little and is removed rather than bounded.
    private static double[][] GetCellBoundaryVertices(H3Index index)
    {
        var polygon = index.GetCellBoundary(GeomFactory);
        var coords = polygon.ExteriorRing.Coordinates;

        var vertices = new double[coords.Length][];
        for (int i = 0; i < coords.Length; i++)
        {
            vertices[i] = [coords[i].Y, coords[i].X];
        }

        return vertices;
    }

    public List<long> GetNearbyNeighborhoods(double lat, double lng, int k = 1)
    {
        var latRad = lat * Math.PI / 180.0;
        var lngRad = lng * Math.PI / 180.0;
        var center = H3Index.FromLatLng(new LatLng(latRad, lngRad), GameConstants.H3NeighborhoodResolution);

        var disk = center.GridDiskDistances(k);
        return disk.Select(d => (long)(ulong)d.Index).ToList();
    }
}
