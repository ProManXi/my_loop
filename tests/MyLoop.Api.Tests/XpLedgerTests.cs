using MyLoop.Api.Constants;
using MyLoop.Api.Entities;
using MyLoop.Api.Services;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// #132 / ML-ERR-035: XP → level mapping must live in ONE place so mission, claim and
/// achievement awards can never drift, and a rolled-back achievement can reverse its XP
/// (and level) cleanly. Pure math — no database needed.
/// </summary>
public class XpLedgerTests
{
    private static User NewUser() =>
        new() { FirebaseUid = "u", DisplayName = "U", Color = "#111", TotalXp = 0, Level = 1 };

    [Fact]
    public void Grant_adds_xp_and_recomputes_level()
    {
        var user = NewUser();
        XpLedger.Grant(user, 400);
        Assert.Equal(400, user.TotalXp);
        Assert.Equal(GameConstants.LevelFromXp(400), user.Level);
    }

    [Fact]
    public void Revoke_removes_xp_and_recomputes_level()
    {
        var user = NewUser();
        XpLedger.Grant(user, 500);
        XpLedger.Revoke(user, 100);
        Assert.Equal(400, user.TotalXp);
        Assert.Equal(GameConstants.LevelFromXp(400), user.Level);
    }

    [Fact]
    public void Grant_then_Revoke_of_the_same_amount_is_a_no_op()
    {
        var user = NewUser();
        XpLedger.Grant(user, 250);
        XpLedger.Grant(user, 175);
        XpLedger.Revoke(user, 175);
        Assert.Equal(250, user.TotalXp);
        Assert.Equal(GameConstants.LevelFromXp(250), user.Level);
    }

    [Fact]
    public void Revoke_floors_total_xp_at_zero()
    {
        var user = NewUser();
        XpLedger.Grant(user, 30);
        XpLedger.Revoke(user, 100); // more than granted
        Assert.Equal(0, user.TotalXp);
        Assert.Equal(1, user.Level); // level never drops below 1
    }
}
