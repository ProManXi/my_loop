using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Entities;

namespace MyLoop.Api.Data;

/// <summary>
/// Entity Framework Core database context for the MyLoop application.
/// Manages all entity sets and configures the relational model (indexes, keys, constraints).
/// Backed by PostgreSQL via Npgsql.
/// </summary>
public class AppDbContext : DbContext
{
    /// <summary>
    /// Initializes a new instance of <see cref="AppDbContext"/> with the specified options.
    /// </summary>
    /// <param name="options">The database context configuration options (connection string, provider, etc.).</param>
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

    /// <summary>Gets the set of registered players.</summary>
    public DbSet<User> Users => Set<User>();

    /// <summary>Gets the set of completed territory claims (loop submissions).</summary>
    public DbSet<Claim> Claims => Set<Claim>();

    /// <summary>Gets the set of individual hex cells that make up the territory map.</summary>
    public DbSet<TerritoryCell> TerritoryCells => Set<TerritoryCell>();

    /// <summary>Gets the set of ownership transfer events (cell ownership history).</summary>
    public DbSet<CellTransfer> CellTransfers => Set<CellTransfer>();

    /// <summary>Gets the set of daily leaderboard snapshots.</summary>
    public DbSet<LeaderboardEntry> LeaderboardEntries => Set<LeaderboardEntry>();

    /// <summary>Gets the set of FCM device tokens for push notifications.</summary>
    public DbSet<DeviceToken> DeviceTokens => Set<DeviceToken>();

    /// <summary>Gets the set of explored hex cells (permanent discovery records).</summary>
    public DbSet<ExploredCell> ExploredCells => Set<ExploredCell>();

    /// <summary>Gets the set of daily missions assigned to users.</summary>
    public DbSet<DailyMission> DailyMissions => Set<DailyMission>();

    /// <summary>Gets the set of unlocked achievements per user.</summary>
    public DbSet<UserAchievement> UserAchievements => Set<UserAchievement>();

    /// <summary>
    /// Configures the entity model: primary keys, unique constraints, and indexes
    /// for efficient query patterns used by the game.
    /// </summary>
    /// <param name="modelBuilder">The builder used to construct the EF Core model.</param>
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        // User: firebase UID must be unique (no duplicate accounts)
        modelBuilder.Entity<User>(e =>
        {
            e.HasIndex(u => u.FirebaseUid).IsUnique();
        });

        // TerritoryCell: the H3 cell ID is the primary key (one owner per hex)
        modelBuilder.Entity<TerritoryCell>(e =>
        {
            e.HasKey(t => t.CellId);
            e.HasIndex(t => t.OwnerId); // fast lookup: "give me all cells owned by this user"
            e.HasIndex(t => new { t.CenterLat, t.CenterLng }); // viewport queries (will upgrade to point+GiST via raw SQL)
            e.HasIndex(t => t.ParentCellId); // geohash-style partition pruning by area
        });

        // CellTransfer: ownership history for revenge/recapture features
        modelBuilder.Entity<CellTransfer>(e =>
        {
            e.HasIndex(t => new { t.FromUserId, t.TransferredAt }); // "hexes stolen from me, most recent first"
            e.HasIndex(t => new { t.ToUserId, t.TransferredAt }); // "hexes I've captured"
            e.HasIndex(t => t.CellId); // "full history of this hex"
        });

        // LeaderboardEntry: one entry per user per day
        modelBuilder.Entity<LeaderboardEntry>(e =>
        {
            e.HasIndex(l => new { l.Date, l.Rank }); // fast lookup: "top N on this date"
            e.HasIndex(l => new { l.UserId, l.Date }).IsUnique(); // prevent duplicate entries per user/day
        });

        // ExploredCell: permanent record of hex discovery (for exploration %)
        modelBuilder.Entity<ExploredCell>(e =>
        {
            e.HasKey(x => new { x.UserId, x.CellId }); // composite PK
            e.HasIndex(x => new { x.UserId, x.NeighborhoodId }); // fast: "how many cells has user explored in this neighborhood"
            e.HasIndex(x => x.NeighborhoodId); // fast: "total explored cells in neighborhood"
        });

        // DailyMission: user missions per day
        modelBuilder.Entity<DailyMission>(e =>
        {
            // Unique: one mission per type per user-day. Two concurrent first-of-day
            // generations (e.g. /game-state hydration racing a claim's RecordProgress) must
            // collapse into ONE mission set — the loser's insert violates and requeries (#131).
            // The (UserId, Date) prefix still serves the "get today's missions" lookup.
            e.HasIndex(m => new { m.UserId, m.Date, m.Type }).IsUnique();
        });

        // UserAchievement: one unlock per user per achievement
        modelBuilder.Entity<UserAchievement>(e =>
        {
            e.HasIndex(a => a.UserId); // fast: "all achievements for user"
            e.HasIndex(a => new { a.UserId, a.AchievementId }).IsUnique(); // prevent duplicates
        });
    }
}
