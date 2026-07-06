using MyLoop.Api.Constants;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// IsValidRegionId is the server-side gate for SignalR JoinRegion (issue #98 / ML-ERR-001).
/// It must accept exactly the res-3 H3 ids the server broadcasts to and reject everything
/// else — most importantly the "user_{guid}" personal-group names, which would otherwise let
/// any caller subscribe to another user's private deltas.
/// </summary>
public class HexGridRegionIdTests
{
    private static HexGridService Service() => new(new GeoService());

    [Fact]
    public void Accepts_a_real_res3_region_id()
    {
        var svc = Service();
        // Derive a genuine res-3 parent from a real point, exactly as the server does.
        var cell = svc.GetCellAtPoint(37.7749, -122.4194);
        var regionId = svc.GetParentCellId(cell.CellId).ToString();

        Assert.True(svc.IsValidRegionId(regionId));
    }

    [Fact]
    public void Rejects_a_personal_group_name()
    {
        var svc = Service();
        Assert.False(svc.IsValidRegionId($"user_{System.Guid.NewGuid()}"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-number")]
    [InlineData("0")]
    public void Rejects_non_numeric_or_invalid_ids(string regionId)
    {
        var svc = Service();
        Assert.False(svc.IsValidRegionId(regionId));
    }

    [Fact]
    public void Rejects_a_finer_resolution_cell_id()
    {
        var svc = Service();
        // A valid H3 cell, but at the fine claim resolution — not a region. The server never
        // broadcasts to these, so JoinRegion must not let a caller subscribe to one.
        var fineCell = svc.GetCellAtPoint(37.7749, -122.4194).CellId;
        Assert.NotEqual(GameConstants.H3ParentResolution, GameConstants.H3Resolution);
        Assert.False(svc.IsValidRegionId(fineCell.ToString()));
    }
}
