using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Models;

namespace MyLoop.Api.Services;

public class UserService : IUserService
{
    private readonly AppDbContext _db;
    private readonly IValidationService _validation;

    public UserService(AppDbContext db, IValidationService validation)
    {
        _db = db;
        _validation = validation;
    }

    public async Task<User> Register(RegisterRequest request, string firebaseUid, string authProvider)
    {
        var existing = await _db.Users.FirstOrDefaultAsync(u => u.FirebaseUid == firebaseUid);
        if (existing != null) return existing;

        var user = BuildNewUser(firebaseUid, authProvider, request);
        _db.Users.Add(user);

        try
        {
            await _db.SaveChangesAsync();
        }
        catch (DbUpdateException)
        {
            return await HandleRegistrationRace(user, firebaseUid);
        }

        await CreateInitialLeaderboardEntry(user.Id);
        return user;
    }

    public async Task<User?> GetById(Guid id)
    {
        return await _db.Users.FindAsync(id);
    }

    public async Task<User?> GetByFirebaseUid(string firebaseUid)
    {
        return await _db.Users.FirstOrDefaultAsync(u => u.FirebaseUid == firebaseUid);
    }

    public async Task<User?> UpdateProfile(Guid id, UpdateUserRequest request)
    {
        var user = await _db.Users.FindAsync(id);
        if (user == null) return null;

        if (request.DisplayName != null) user.DisplayName = request.DisplayName.Trim();
        if (request.Color != null) user.Color = request.Color;
        if (request.AvatarId != null) user.AvatarId = request.AvatarId.Value;

        await _db.SaveChangesAsync();
        return user;
    }

    public async Task<UserProfileResponse?> GetRichProfile(Guid id)
    {
        var user = await _db.Users.FindAsync(id);
        if (user == null) return null;

        var (rank, totalPlayers) = await GetCurrentRanking(id);
        return MapToProfileResponse(user, rank, totalPlayers);
    }

    public async Task<bool> DeleteAccount(Guid userId)
    {
        var user = await _db.Users.FindAsync(userId);
        if (user == null) return false;

        await DeleteUserData(userId);
        _db.Users.Remove(user);
        await _db.SaveChangesAsync();
        return true;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ──────────────────────────────────────────────────────────────────────────

    private static User BuildNewUser(string firebaseUid, string authProvider, RegisterRequest request)
    {
        return new User
        {
            Id = Guid.NewGuid(),
            FirebaseUid = firebaseUid,
            DisplayName = request.DisplayName.Trim(),
            Color = request.Color,
            AvatarId = request.AvatarId,
            AuthProvider = authProvider,
        };
    }

    private async Task<User> HandleRegistrationRace(User failedUser, string firebaseUid)
    {
        _db.Entry(failedUser).State = EntityState.Detached;
        var raced = await _db.Users.FirstOrDefaultAsync(u => u.FirebaseUid == firebaseUid);
        return raced ?? throw new InvalidOperationException("Unexpected registration failure");
    }

    private async Task CreateInitialLeaderboardEntry(Guid userId)
    {
        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var totalUsers = await _db.Users.CountAsync();

        _db.Set<LeaderboardEntry>().Add(new LeaderboardEntry
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            Date = today,
            CellCount = 0,
            AreaM2 = 0,
            Rank = totalUsers,
        });
        await _db.SaveChangesAsync();
    }

    private async Task<(int Rank, int TotalPlayers)> GetCurrentRanking(Guid userId)
    {
        var today = DateOnly.FromDateTime(DateTime.UtcNow);

        var entry = await _db.LeaderboardEntries
            .Where(l => l.Date == today && l.UserId == userId)
            .FirstOrDefaultAsync();

        var totalPlayers = await _db.LeaderboardEntries
            .Where(l => l.Date == today)
            .CountAsync();

        return (entry?.Rank ?? 0, totalPlayers);
    }

    private static UserProfileResponse MapToProfileResponse(User user, int rank, int totalPlayers)
    {
        return new UserProfileResponse
        {
            Id = user.Id,
            DisplayName = user.DisplayName,
            Color = user.Color,
            AvatarId = user.AvatarId,
            HexCount = user.HexCount,
            Streak = user.Streak,
            MaxStreak = user.MaxStreak,
            DistanceKm = user.DistanceKm,
            TopThreeFinishes = user.TopThreeFinishes,
            TopTenFinishes = user.TopTenFinishes,
            TopHundredFinishes = user.TopHundredFinishes,
            TopThousandFinishes = user.TopThousandFinishes,
            IsStreakActive = user.IsStreakActive,
            JoinedAt = user.CreatedAt,
            CurrentRank = rank,
            TotalPlayers = totalPlayers,
        };
    }

    /// <summary>
    /// Removes ALL data belonging to a user prior to deleting the account row.
    /// There are no DB-level FK cascades configured (see <see cref="AppDbContext"/>),
    /// so every child table that carries a UserId MUST be purged explicitly here —
    /// otherwise account deletion silently orphans the user's rows (a privacy
    /// violation given the App Store "delete my data" guarantee in the privacy policy).
    /// </summary>
    private async Task DeleteUserData(Guid userId)
    {
        await _db.TerritoryCells.Where(c => c.OwnerId == userId).ExecuteDeleteAsync();
        await _db.Set<CellTransfer>().Where(t => t.FromUserId == userId || t.ToUserId == userId).ExecuteDeleteAsync();
        await _db.Claims.Where(c => c.UserId == userId).ExecuteDeleteAsync();
        await _db.LeaderboardEntries.Where(l => l.UserId == userId).ExecuteDeleteAsync();
        // Previously orphaned — these carry per-user (and PII-adjacent) data:
        await _db.ExploredCells.Where(e => e.UserId == userId).ExecuteDeleteAsync();
        await _db.DailyMissions.Where(m => m.UserId == userId).ExecuteDeleteAsync();
        await _db.UserAchievements.Where(a => a.UserId == userId).ExecuteDeleteAsync();
        await _db.DeviceTokens.Where(d => d.UserId == userId).ExecuteDeleteAsync();
    }
}
