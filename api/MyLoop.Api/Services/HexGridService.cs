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

    public double CalculateArea(int cellCount)
    {
        return cellCount * GameConstants.CellAreaSquareMeters;
    }

    public bool HasClosedLoop(double[][] path)
    {
        if (path.Length < GameConstants.MinLoopPoints) return false;

        for (int i = GameConstants.LoopSkipNeighbors; i < path.Length; i++)
        {
            for (int j = 0; j <= i - GameConstants.MinLoopPoints; j++)
            {
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

    private void FindClosureLoops(double[][] path, bool[] used, List<double[][]> loops)
    {
        for (int i = GameConstants.LoopSkipNeighbors; i < path.Length; i++)
        {
            if (used[i]) continue;

            for (int j = 0; j <= i - GameConstants.MinLoopPoints; j++)
            {
                if (used[j]) continue;

                var dist = _geoService.HaversineMeters(
                    path[i][0], path[i][1],
                    path[j][0], path[j][1]);

                if (dist > GameConstants.LoopClosureDistanceMeters) continue;

                var loopLength = i - j + 1;
                var loop = new double[loopLength][];
                Array.Copy(path, j, loop, 0, loopLength);
                loops.Add(loop);

                for (int k = j; k <= i; k++)
                    used[k] = true;

                break;
            }
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

    // Computed fresh every call (~5 µs): a static cache here grew one entry per distinct
    // cell ever touched with no eviction — an unbounded leak that bought microseconds (#115).
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
