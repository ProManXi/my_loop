using System.Data;
using System.Text;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Models;

namespace MyLoop.Api.Services;

public class TerritoryService : ITerritoryService
{
    private readonly AppDbContext _db;
    private readonly IHexGridService _hexGrid;
    private readonly IGeoService _geo;
    private readonly ITerritoryNotifier _notifier;
    private readonly IPathValidationService _pathValidator;
    private readonly IPushNotificationService _pushService;
    private readonly GeocodingService _geocoding;
    private readonly IMissionService _missionService;
    private readonly IAchievementService _achievementService;
    private readonly ILogger<TerritoryService> _logger;

    public TerritoryService(AppDbContext db, IHexGridService hexGrid, IGeoService geo,
        ITerritoryNotifier notifier, IPathValidationService pathValidator,
        IPushNotificationService pushService, GeocodingService geocoding,
        IMissionService missionService, IAchievementService achievementService,
        ILogger<TerritoryService> logger)
    {
        _db = db;
        _hexGrid = hexGrid;
        _geo = geo;
        _notifier = notifier;
        _pathValidator = pathValidator;
        _pushService = pushService;
        _geocoding = geocoding;
        _missionService = missionService;
        _achievementService = achievementService;
        _logger = logger;
    }

    public async Task<ClaimResult> ProcessClaim(
        Guid userId, double[][] path, Guid walkSessionId, string? clientLocalDate = null)
    {
        // The player's local day drives today's daily missions (one "today", shared with streaks).
        var gameDay = GameDay.Resolve(clientLocalDate);

        var validationError = await ValidateClaim(userId, path);
        if (validationError != null)
            return ClaimResult.Failure(validationError);

        var pathError = _pathValidator.Validate(path);
        if (pathError != null)
            return ClaimResult.Failure(pathError);

        var cells = _hexGrid.ComputeCapturedCells(path);
        if (cells.Count == 0)
            return ClaimResult.Failure("No hexes captured — walk a closed loop to claim territory");

        if (!_hexGrid.HasClosedLoop(path))
            return ClaimResult.Failure("No closed loop detected — walk back near your starting point");

        var area = _hexGrid.CalculateArea(cells.Count);
        if (area > GameConstants.MaxClaimAreaSquareMeters)
            return ClaimResult.Failure("Claim too large — max 5km² per claim");
        if (cells.Count > GameConstants.MaxCellsPerClaim)
            return ClaimResult.Failure("Claim too large — too many cells");

        // Serializable isolation + per-user advisory lock + bounded retry. This makes two
        // concurrent claims over the same hex deterministic (exactly one owner) and the
        // per-day cap accurate (checked inside the transaction, not before it).
        //
        // The loop runs inside CreateExecutionStrategy because EnableRetryOnFailure forbids a
        // direct BeginTransactionAsync and lets EF re-run the block on a transient connection drop
        // (Neon cold start). Serialization conflicts are still handled by the inner loop; only
        // connection-level transients fall through the bare catch to be retried by the strategy.
        var strategy = _db.Database.CreateExecutionStrategy();
        var commit = await strategy.ExecuteAsync(async () =>
        {
        for (var attempt = 1; ; attempt++)
        {
            _db.ChangeTracker.Clear();
            await using var transaction =
                await _db.Database.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                await _db.Database.ExecuteSqlRawAsync(
                    "SELECT pg_advisory_xact_lock({0})", BitConverter.ToInt64(userId.ToByteArray(), 0));

                // Resolve the session's Claim id first: this walk's batch-step drains may have
                // already created the Claim earlier today, so it is excluded from the per-day cap —
                // the cap counts distinct walks, not the batches/loop within one walk (#56).
                var claimId = await ResolveSessionClaimId(userId, walkSessionId);
                if (await IsDailyClaimCapReached(userId, claimId))
                {
                    await transaction.RollbackAsync();
                    return new TerritoryCommit<ClaimResult>(
                        ClaimResult.Failure(DailyClaimCapMessage),
                        Pushed: false, [], [], null, null, 0, null, []);
                }

            var (boundaries, transfers) = await AssignCells(userId, cells, claimId);

            _db.CellTransfers.AddRange(transfers);

            // One walk = one Claim (#56): upsert the session Claim rather than inserting a new
            // row per loop/batch. CellCount accumulates the NET cells this walk added (transfer
            // count — disjoint from cells already owned, which AssignCells skips), and AreaM2 is
            // derived from the canonical cell area, never the legacy 4234 literal.
            var claim = await GetOrCreateSessionClaim(userId, claimId, path);
            claim.CellCount += transfers.Count;
            claim.AreaM2 = claim.CellCount * GameConstants.CellAreaSquareMeters;

            var totalDistance = _geo.CalculatePathDistance(path);
            // Distance stats are owned by the live batch-step path (#54). The loop claim
            // only fills interior hexes and awards the one-time distance XP computed below;
            // it must not re-add DistanceKm or WalkDistance mission progress, which the
            // batch-step drain already accumulated during the walk.
            await UpdateUserStats(userId, transfers);

            // Record exploration for all captured cells (single batched upsert)
            var newExplorations = await RecordExplorationBatch(userId, cells.Select(c => c.CellId));

            // Award XP for captured hexes + distance walked
            var newCells = transfers.Count(t => t.FromUserId == null);
            var stolenCells = transfers.Count(t => t.FromUserId != null);
            var distanceKm = totalDistance / 1000.0;
            var xpAmount = newCells * GameConstants.XpPerHexCaptured
                         + stolenCells * GameConstants.XpPerHexStolen
                         + (int)(distanceKm * GameConstants.XpPerKmWalked);

            // Progress daily missions
            MissionProgressResult? missionResult = null;
            if (newCells + stolenCells > 0)
                missionResult = await _missionService.RecordProgress(userId, MissionType.CaptureHexes, newCells + stolenCells, gameDay);
            if (stolenCells > 0)
                await _missionService.RecordProgress(userId, MissionType.StealHex, stolenCells, gameDay);
            await _missionService.RecordProgress(userId, MissionType.CaptureInOneWalk, newCells + stolenCells, gameDay);
            // WalkDistance mission progress is recorded by the live batch-step path (#54),
            // not here, to avoid double-counting this walk's distance.
            if (newExplorations > 0)
                await _missionService.RecordProgress(userId, MissionType.ExploreNewArea, newExplorations, gameDay);

            // Check achievements
            var newAchievements = await _achievementService.CheckAndUnlock(userId);

            // Award XP (also saves changes)
            var xpResult = await _missionService.AwardXp(userId, xpAmount, "loop_claim");

            await _db.SaveChangesAsync();
            await transaction.CommitAsync();

            var response = ClaimResult.Succeeded(new ClaimResponse
            {
                Id = claim.Id,
                // CellCount/AreaM2 describe THIS loop submission's enclosed area (cells.Count),
                // not the stored session total — the response contract is unchanged. The client
                // shows NewlyClaimedCount, not CellCount (#55).
                CellCount = cells.Count,
                // transfers excludes cells the user already owned (AssignCells skips them),
                // so this is the bonus the client adds to its live count, with no double
                // count of trail hexes already claimed during the walk (#55).
                NewlyClaimedCount = transfers.Count,
                AreaM2 = area,
                StolenFromOthers = transfers.Count(t => t.FromUserId != null),
                Boundaries = boundaries,
            });

            // Carry the post-commit payload out; broadcasts/pushes run AFTER ExecuteAsync returns
            // (outside the retriable block) so a transient there can't re-run a committed claim.
            return new TerritoryCommit<ClaimResult>(
                response, Pushed: true, cells, transfers, User: null,
                xpResult, xpAmount, missionResult, newAchievements);
            }
            catch (Exception ex) when (attempt < MaxClaimRetries && IsTransientConflict(ex))
            {
                await transaction.RollbackAsync();
                _logger.LogWarning("Claim retry {Attempt} for user {UserId} after a write conflict", attempt, userId);
            }
            catch
            {
                // Preserve the original (possibly transient) exception for the execution strategy to
                // classify — a rollback on a dropped connection would otherwise throw and mask it.
                try
                {
                    await transaction.RollbackAsync();
                }
                catch (Exception rollbackEx)
                {
                    _logger.LogWarning(rollbackEx,
                        "Rollback after a failed claim attempt for user {UserId} also failed; surfacing the original error",
                        userId);
                }
                throw;
            }
        }
        });

        // Post-commit side effects run OUTSIDE the retrying execution strategy (see TerritoryCommit):
        // the claim is durably committed, so a transient here must never re-run it.
        if (!commit.Pushed)
            return commit.Response;

        await BroadcastOwnershipChanges(userId, commit.CapturedHexes, commit.Transfers);
        await NotifyVictimsOfTheft(userId, commit.Transfers);

        var user = await _db.Users.AsNoTracking().FirstOrDefaultAsync(u => u.Id == userId);
        await PushPersonalDeltas(userId, user, commit.XpResult!, commit.XpAmount, commit.MissionResult, commit.NewAchievements);

        foreach (var victimId in commit.Transfers.Where(t => t.FromUserId != null).Select(t => t.FromUserId!.Value).Distinct())
            await PushVictimDelta(victimId);

        return commit.Response;
    }

    public async Task<BatchStepClaimResponse> ProcessBatchStepClaim(
        Guid userId, string? clientLocalDate, List<BatchStepPoint> points, Guid walkSessionId)
    {
        if (points == null || points.Count == 0)
            return new BatchStepClaimResponse();

        // Fail loud on oversized batches — truncating instead would drop points without
        // ACKing them, and the client WAL only evicts ACKed points, jamming its queue
        // forever (#117). The controller 400s first; this guards against that check drifting.
        if (points.Count > GameConstants.MaxBatchStepPoints)
            throw new ArgumentException(
                $"Batch exceeds {GameConstants.MaxBatchStepPoints} points", nameof(points));

        // The player's local day drives BOTH the streak and today's daily missions (one "today").
        var gameDay = GameDay.Resolve(clientLocalDate);

        // 1. Resolve each point to its H3 hex (in memory, no DB)
        var resolved = points.Select(p => new
        {
            Point = p,
            Hex = _hexGrid.GetCellAtPoint(p.Lat, p.Lng),
        }).ToList();

        var allCellIds = resolved.Select(r => r.Hex.CellId).Distinct().ToList();

        // Serializable + per-user advisory lock + bounded retry (see ProcessClaim). The loop runs
        // inside CreateExecutionStrategy so EnableRetryOnFailure tolerates Neon cold-start
        // connection drops; the inner loop still handles serialization conflicts.
        var strategy = _db.Database.CreateExecutionStrategy();
        var commit = await strategy.ExecuteAsync(async () =>
        {
        for (var attempt = 1; ; attempt++)
        {
            _db.ChangeTracker.Clear();
            await using var transaction =
                await _db.Database.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                await _db.Database.ExecuteSqlRawAsync(
                    "SELECT pg_advisory_xact_lock({0})", BitConverter.ToInt64(userId.ToByteArray(), 0));

                // Re-read inside the transaction so retries observe fresh ownership state.
                var existingCells = await _db.TerritoryCells
                    .Include(t => t.Owner)
                    .Where(t => allCellIds.Contains(t.CellId))
                    .ToDictionaryAsync(t => t.CellId);

                var user = await _db.Users.FindAsync(userId);
                if (user == null)
                {
                    await transaction.RollbackAsync();
                    return new TerritoryCommit<BatchStepClaimResponse>(
                        new BatchStepClaimResponse(), Pushed: false, [], [], null, null, 0, null, []);
                }

            var cooldownExpiry = DateTime.UtcNow.AddHours(GameConstants.CellCooldownHours);
            // One walk = one Claim (#56): all of this walk's batch drains share the client's
            // walkSessionId, so they upsert the same Claim instead of each adding a row.
            var claimId = await ResolveSessionClaimId(userId, walkSessionId);

            // Enforce the daily cap on the batch-step path too (#87). It was previously only on the
            // loop path, so the primary claiming route was uncapped. Checked inside the transaction
            // (mirroring ProcessClaim) and counting distinct walks/day — the session's own Claim is
            // excluded, so multiple batches of THIS walk never count as separate claims.
            if (await IsDailyClaimCapReached(userId, claimId))
            {
                await transaction.RollbackAsync();
                return new TerritoryCommit<BatchStepClaimResponse>(
                    new BatchStepClaimResponse { RejectionReason = DailyClaimCapMessage },
                    Pushed: false, [], [], null, null, 0, null, []);
            }

            // Aggregate state across batch
            var results = new List<BatchStepResult>(points.Count);
            var transfers = new List<CellTransfer>();
            var capturedHexes = new List<HexCell>(); // for ownership broadcast
            var processedThisBatch = new HashSet<long>(); // dedupe same hex hit twice
            var newCellsCount = 0;
            var stolenCellsCount = 0;
            var newExplorations = 0;

            // Build path for the synthetic Claim entity (stitches all points together)
            var pathPoints = points.Select(p => new[] { p.Lat, p.Lng }).ToArray();

            // 4. Process each point
            foreach (var item in resolved)
            {
                var p = item.Point;
                var hexCell = item.Hex;
                var cellId = hexCell.CellId;

                // Already processed earlier in this batch — skip silently
                if (processedThisBatch.Contains(cellId))
                {
                    results.Add(new BatchStepResult
                    {
                        ClientId = p.ClientId,
                        Claimed = false,
                        SkipReason = "duplicate",
                    });
                    continue;
                }

                existingCells.TryGetValue(cellId, out var existing);

                // Already ours — refresh decay timer + record exploration
                if (existing != null && existing.OwnerId == userId)
                {
                    existing.LastRefreshedAt = DateTime.UtcNow;
                    await RecordExploration(userId, cellId);
                    processedThisBatch.Add(cellId);
                    results.Add(new BatchStepResult
                    {
                        ClientId = p.ClientId,
                        Claimed = false,
                        CellId = cellId,
                        SkipReason = "owned",
                    });
                    continue;
                }

                // On cooldown — can't steal yet
                if (existing != null && IsOnCooldown(existing))
                {
                    results.Add(new BatchStepResult
                    {
                        ClientId = p.ClientId,
                        Claimed = false,
                        CellId = cellId,
                        SkipReason = "cooldown",
                    });
                    continue;
                }

                var cellCenter = _hexGrid.GetCellCenter(cellId);
                var decayDays = await CalculateDecayDays(user, cellCenter.Lat, cellCenter.Lng);

                string? previousOwnerName = null;
                bool wasStolen;

                if (existing != null)
                {
                    previousOwnerName = existing.Owner?.DisplayName;
                    var transfer = CreateTransfer(cellId, existing.OwnerId, userId, claimId);
                    _db.CellTransfers.Add(transfer);
                    transfers.Add(transfer);
                    UpdateExistingCell(existing, userId, claimId, hexCell, cooldownExpiry);
                    existing.DecayDays = decayDays;
                    wasStolen = true;
                    stolenCellsCount++;
                }
                else
                {
                    var newCell = CreateNewCell(userId, claimId, hexCell, cooldownExpiry, decayDays);
                    _db.TerritoryCells.Add(newCell);
                    var transfer = CreateTransfer(cellId, null, userId, claimId);
                    _db.CellTransfers.Add(transfer);
                    transfers.Add(transfer);
                    wasStolen = false;
                    newCellsCount++;
                }

                if (await RecordExploration(userId, cellId))
                    newExplorations++;

                processedThisBatch.Add(cellId);
                capturedHexes.Add(hexCell);

                results.Add(new BatchStepResult
                {
                    ClientId = p.ClientId,
                    Claimed = true,
                    CellId = cellId,
                    Boundary = hexCell.Boundary,
                    WasStolen = wasStolen,
                    PreviousOwnerName = previousOwnerName,
                });
            }

            var totalClaimedThisBatch = newCellsCount + stolenCellsCount;

            // Real distance walked this slice (full GPS path, including travel over cells
            // already owned). Fixes HIGH-11: DistanceKm was never incremented on the
            // batch-step path, so the Distance achievement / leaderboard distance and the
            // WalkDistance mission stayed permanently stuck for walk-and-claim players.
            // The batch already passed inter-point speed anti-cheat at the controller.
            var batchDistanceMeters = points.Count >= 2 ? _geo.CalculatePathDistance(pathPoints) : 0.0;
            if (batchDistanceMeters > 0)
                user.DistanceKm += batchDistanceMeters / 1000.0;

            // 5. Upsert the walk's single Claim (FK target for transfers, #56). CellCount
            // accumulates the net cells claimed across all of this walk's batches; AreaM2 is
            // derived from the canonical cell area, not the legacy 4234 literal.
            if (totalClaimedThisBatch > 0)
            {
                var claim = await GetOrCreateSessionClaim(userId, claimId, pathPoints);
                claim.CellCount += totalClaimedThisBatch;
                claim.AreaM2 = claim.CellCount * GameConstants.CellAreaSquareMeters;

                // 6. Update user stats (atomic)
                user.HexCount += totalClaimedThisBatch;
                user.TotalHexesCaptured += totalClaimedThisBatch;
                user.TotalHexesStolen += stolenCellsCount;

                UpdateStreak(user, gameDay);

                if (transfers.Count > 0)
                    await DecrementVictimHexCounts(userId, transfers);
            }

            // 7. Mission progress (claim-gated types only)
            MissionProgressResult? missionResult = null;
            if (totalClaimedThisBatch > 0)
            {
                missionResult = await _missionService.RecordProgress(
                    userId, MissionType.CaptureHexes, totalClaimedThisBatch, gameDay);
                if (stolenCellsCount > 0)
                    await _missionService.RecordProgress(userId, MissionType.StealHex, stolenCellsCount, gameDay);
                await _missionService.RecordProgress(userId, MissionType.CaptureInOneWalk, totalClaimedThisBatch, gameDay);
                if (newExplorations > 0)
                    await _missionService.RecordProgress(userId, MissionType.ExploreNewArea, newExplorations, gameDay);
                if (user.IsStreakActive)
                    await _missionService.RecordProgress(userId, MissionType.MaintainStreak, 1, gameDay);
            }

            // WalkDistance mirrors the DistanceKm stat accrued above, so it progresses on
            // EVERY slice with movement — including zero-claim laps inside territory the
            // user already owns, which previously advanced the profile stat while the
            // "Walk N meters" mission stayed frozen (#118). Real GPS distance, rounded to
            // whole meters (not the old ~30m-per-hex approximation).
            var walkMeters = (int)Math.Round(batchDistanceMeters);
            if (walkMeters > 0)
            {
                var walkResult = await _missionService.RecordProgress(
                    userId, MissionType.WalkDistance, walkMeters, gameDay);
                // On a zero-claim slice this is the only mission update; carry it into the
                // response so the client's mission card moves. When claims happened,
                // missionResult's tracked mission list already reflects this call.
                missionResult ??= walkResult;
            }

            // 8. Achievements
            var newAchievements = totalClaimedThisBatch > 0
                ? await _achievementService.CheckAndUnlock(userId)
                : new List<AchievementUnlock>();

            // 9. XP
            var xpAmount = newCellsCount * GameConstants.XpPerHexCaptured
                         + stolenCellsCount * GameConstants.XpPerHexStolen;
            XpGainResult xpResult;
            if (xpAmount > 0)
            {
                xpResult = await _missionService.AwardXp(userId, xpAmount, "batch_step_claim");
            }
            else
            {
                xpResult = new XpGainResult
                {
                    TotalXp = user.TotalXp,
                    Level = user.Level,
                    LeveledUp = false,
                };
            }

            // Persist every batch write (claim upsert, cells, transfers, stats, "owned"
            // refreshes) before committing. The claimed path previously relied on AwardXp's
            // internal SaveChangesAsync, so the whole batch silently stayed uncommitted whenever
            // no XP was awarded — a hidden coupling. Save explicitly, mirroring ProcessClaim.
            await _db.SaveChangesAsync();
            await transaction.CommitAsync();

            // Build response (in-memory only); the consolidated push is deferred to after the block.
            var neededXp = GameConstants.XpForLevel(xpResult.Level + 1) - GameConstants.XpForLevel(xpResult.Level);
            var progressXp = (int)(xpResult.TotalXp - GameConstants.XpForLevel(xpResult.Level));

            var response = new BatchStepClaimResponse
            {
                Results = results,
                Stats = new BatchStepStats
                {
                    HexCount = user.HexCount,
                    TotalHexesCaptured = user.TotalHexesCaptured,
                    TotalHexesStolen = user.TotalHexesStolen,
                    Streak = user.Streak,
                    IsStreakActive = user.IsStreakActive,
                    DistanceKm = user.DistanceKm,
                },
                Xp = new BatchStepXp
                {
                    XpGained = xpAmount + (missionResult?.XpEarned ?? 0),
                    TotalXp = xpResult.TotalXp,
                    Level = xpResult.Level,
                    LeveledUp = xpResult.LeveledUp,
                    ProgressXp = progressXp,
                    NeededXp = neededXp,
                    ProgressPercent = neededXp > 0 ? (double)progressXp / neededXp : 0,
                },
                Missions = missionResult?.Missions?.Select(m => new BatchMissionUpdate
                {
                    MissionId = m.Id,
                    Type = m.Type.ToString(),
                    CurrentProgress = m.CurrentProgress,
                    TargetValue = m.TargetValue,
                    Completed = m.IsCompleted,
                    XpAwarded = m.IsCompleted ? m.XpReward : 0,
                }).ToList() ?? new List<BatchMissionUpdate>(),
                Achievements = newAchievements.Select(a => new AchievementUnlockedDto
                {
                    Id = a.AchievementId,
                    Name = a.Name,
                    Icon = a.Icon,
                    XpAwarded = a.XpAwarded,
                }).ToList(),
            };

            // Carry the post-commit payload out; the consolidated push runs AFTER ExecuteAsync
            // returns (outside the retriable block) so a transient there can't re-run the committed slice.
            return new TerritoryCommit<BatchStepClaimResponse>(
                response, Pushed: capturedHexes.Count > 0, capturedHexes, transfers, user,
                xpResult, xpAmount, missionResult, newAchievements);
            }
            catch (Exception ex) when (attempt < MaxClaimRetries && IsTransientConflict(ex))
            {
                await transaction.RollbackAsync();
                _logger.LogWarning("Batch-step retry {Attempt} for user {UserId} after a write conflict", attempt, userId);
            }
            catch
            {
                // Preserve the original (possibly transient) exception for the execution strategy to
                // classify — a rollback on a dropped connection would otherwise throw and mask it.
                // (database-retry-resilience rule 3: never let a rollback replace the real error.)
                try
                {
                    await transaction.RollbackAsync();
                }
                catch (Exception rollbackEx)
                {
                    _logger.LogWarning(rollbackEx,
                        "Rollback after a failed batch-step attempt for user {UserId} also failed; surfacing the original error",
                        userId);
                }
                throw;
            }
        }
        });

        // Consolidated push runs OUTSIDE the retrying execution strategy (see TerritoryCommit): the
        // slice is committed, so a transient here must never re-run it. Reuses the in-memory user
        // captured at commit time (no post-commit DB read).
        if (commit.Pushed)
        {
            await BroadcastOwnershipChanges(userId, commit.CapturedHexes, commit.Transfers);
            await PushPersonalDeltas(userId, commit.User, commit.XpResult!, commit.XpAmount, commit.MissionResult, commit.NewAchievements);

            foreach (var victimId in commit.Transfers.Where(t => t.FromUserId != null).Select(t => t.FromUserId!.Value).Distinct())
                await PushVictimDelta(victimId);
        }

        return commit.Response;
    }

    public async Task<List<TerritoryCellResponse>> GetTerritoriesInViewport(
        double minLat, double minLng, double maxLat, double maxLng)
    {
        var filtered = await _db.TerritoryCells
            .AsNoTracking()
            .Where(t => t.CenterLat >= minLat && t.CenterLat <= maxLat
                     && t.CenterLng >= minLng && t.CenterLng <= maxLng)
            .Take(GameConstants.MaxViewportCells)
            .Select(t => new
            {
                t.CellId, t.BoundaryJson, t.OwnerId,
                OwnerColor = t.Owner!.Color,
                OwnerName = t.Owner!.DisplayName,
                t.CooldownExpiresAt,
                t.ParentCellId,
                t.LastRefreshedAt,
                t.DecayDays
            })
            .ToListAsync();

        return filtered.Select(t => new TerritoryCellResponse
        {
            CellId = t.CellId,
            Boundary = JsonSerializer.Deserialize<double[][]>(t.BoundaryJson),
            OwnerId = t.OwnerId,
            OwnerColor = t.OwnerColor,
            OwnerName = t.OwnerName,
            CooldownExpiresAtUtc = t.CooldownExpiresAt,
            ParentCellId = t.ParentCellId,
            DecayProgress = ComputeDecayProgress(t.LastRefreshedAt, t.DecayDays),
        }).ToList();
    }

    /// <summary>
    /// Fraction of a cell's OWN decay window elapsed since its last refresh (0..1). Each cell
    /// carries its capture-time DecayDays (7–90 by home distance) — using the global default
    /// here made every slow-decay cell render fully decayed after 7 days (#105).
    /// </summary>
    private static double ComputeDecayProgress(DateTime lastRefreshedAt, int decayDays)
    {
        var decaySeconds = decayDays * 86400.0;
        return Math.Clamp((DateTime.UtcNow - lastRefreshedAt).TotalSeconds / decaySeconds, 0.0, 1.0);
    }

    public async Task<TerritoryStatsResponse> GetUserStats(Guid userId)
    {
        var cellCount = await _db.TerritoryCells.CountAsync(t => t.OwnerId == userId);
        return new TerritoryStatsResponse
        {
            CellCount = cellCount,
            AreaM2 = _hexGrid.CalculateArea(cellCount),
        };
    }

    public async Task<StolenCellsResponse> GetStolenCells(Guid userId, int days)
    {
        var clampedDays = Math.Clamp(days, 1, GameConstants.MaxStolenDaysLookback);
        var since = DateTime.UtcNow.AddDays(-clampedDays);

        var stolen = await _db.CellTransfers
            .Where(t => t.FromUserId == userId && t.TransferredAt >= since)
            .OrderByDescending(t => t.TransferredAt)
            .Select(t => new StolenCellDetail
            {
                CellId = t.CellId,
                ToUserId = t.ToUserId,
                TransferredAt = t.TransferredAt,
                ClaimId = t.ClaimId,
            })
            .ToListAsync();

        var byStealer = stolen
            .GroupBy(s => s.ToUserId)
            .Select(g => new StealerSummary { UserId = g.Key, CellsStolen = g.Count() })
            .OrderByDescending(g => g.CellsStolen)
            .ToList();

        return new StolenCellsResponse
        {
            TotalStolen = stolen.Count,
            Since = since,
            ByStealer = byStealer,
            Cells = stolen.Take(GameConstants.MaxStolenCellsResponse).ToList(),
        };
    }

    public async Task<CellHistoryResponse> GetCellHistory(long cellId)
    {
        var history = await _db.CellTransfers
            .Where(t => t.CellId == cellId)
            .OrderByDescending(t => t.TransferredAt)
            .Take(GameConstants.MaxHistoryDepth)
            .Select(t => new CellTransferDetail
            {
                FromUserId = t.FromUserId,
                ToUserId = t.ToUserId,
                TransferredAt = t.TransferredAt,
                ClaimId = t.ClaimId,
            })
            .ToListAsync();

        var currentOwner = await _db.TerritoryCells
            .Where(t => t.CellId == cellId)
            .Select(t => new CellOwnerInfo { OwnerId = t.OwnerId, ClaimedAt = t.ClaimedAt })
            .FirstOrDefaultAsync();

        return new CellHistoryResponse
        {
            CellId = cellId,
            CurrentOwner = currentOwner,
            TransferCount = history.Count,
            History = history,
        };
    }

    public async Task<List<TerritoryCellResponse>> GetUserTerritories(Guid userId)
    {
        var cells = await _db.TerritoryCells
            .AsNoTracking()
            .Where(t => t.OwnerId == userId)
            .OrderByDescending(t => t.ClaimedAt)
            .Take(GameConstants.MaxUserTerritoryCells)
            .Select(t => new
            {
                t.CellId, t.BoundaryJson, t.OwnerId,
                OwnerColor = t.Owner!.Color,
                OwnerName = t.Owner!.DisplayName,
                t.CooldownExpiresAt,
                t.ParentCellId,
                t.LastRefreshedAt,
                t.DecayDays
            })
            .ToListAsync();

        return cells.Select(t => new TerritoryCellResponse
        {
            CellId = t.CellId,
            Boundary = JsonSerializer.Deserialize<double[][]>(t.BoundaryJson),
            OwnerId = t.OwnerId,
            OwnerColor = t.OwnerColor,
            OwnerName = t.OwnerName,
            CooldownExpiresAtUtc = t.CooldownExpiresAt,
            ParentCellId = t.ParentCellId,
            DecayProgress = ComputeDecayProgress(t.LastRefreshedAt, t.DecayDays),
        }).ToList();
    }

    public async Task<List<ClaimHistoryEntry>> GetClaimHistory(Guid userId)
    {
        // Aggregate the IMMUTABLE claim log by day — NOT live TerritoryCells. Grouping current
        // ownership made a past day's count shrink as those hexes later decayed or were stolen, so
        // "history" appeared to rewrite itself. The Claims table is append-only, so a day's total is
        // fixed, and it reconciles with the per-walk rows the Walk History screen reads from the
        // same table. AreaM2 is the stored per-claim value (summed), so both surfaces agree by
        // construction regardless of the cell-area constant.
        var dailyTotals = await _db.Claims
            .Where(c => c.UserId == userId)
            .GroupBy(c => c.CreatedAt.Date)
            .Select(g => new
            {
                Date = g.Key,
                CellCount = g.Sum(c => c.CellCount),
                AreaM2 = g.Sum(c => c.AreaM2),
            })
            .OrderByDescending(x => x.Date)
            .Take(GameConstants.ClaimHistoryDays)
            .ToListAsync();

        return dailyTotals.Select(d => new ClaimHistoryEntry
        {
            // A daily summary spans multiple claims, so there is no single claim id.
            ClaimId = Guid.Empty,
            CellCount = d.CellCount,
            AreaM2 = d.AreaM2,
            Date = d.Date,
        }).ToList();
    }

    public async Task<List<ExplorationNeighborhood>> GetExplorationStats(Guid userId, double lat, double lng)
    {
        // Group by res-8 neighborhood — use average of actual cell centers for geocoding
        var areas = await _db.ExploredCells
            .AsNoTracking()
            .Where(e => e.UserId == userId)
            .Join(_db.TerritoryCells.AsNoTracking(),
                e => e.CellId,
                t => t.CellId,
                (e, t) => new { e.NeighborhoodId, t.CenterLat, t.CenterLng })
            .GroupBy(x => x.NeighborhoodId)
            .Select(g => new
            {
                NeighborhoodId = g.Key,
                ExploredCount = g.Count(),
                AvgLat = g.Average(x => x.CenterLat),
                AvgLng = g.Average(x => x.CenterLng)
            })
            .ToListAsync();

        if (areas.Count == 0) return [];

        // Query owned cells per neighborhood (separate query — cells may not all be explored)
        var ownedByNeighborhood = await _db.TerritoryCells
            .AsNoTracking()
            .Where(t => t.OwnerId == userId)
            .GroupBy(t => t.NeighborhoodId)
            .Select(g => new { NeighborhoodId = g.Key, OwnedCount = g.Count() })
            .ToDictionaryAsync(x => x.NeighborhoodId, x => x.OwnedCount);

        // Geocode neighborhoods in parallel-safe manner:
        // First pass: resolve names (cached hits are instant, uncached queued)
        var results = new List<ExplorationNeighborhood>();
        var geocodeTasks = new List<(int Index, Task<string> Task)>();

        foreach (var a in areas.OrderByDescending(a => a.ExploredCount))
        {
            var percent = Math.Round(a.ExploredCount * 100.0 / GameConstants.CellsPerNeighborhood, 1);
            ownedByNeighborhood.TryGetValue(a.NeighborhoodId, out var owned);

            results.Add(new ExplorationNeighborhood
            {
                NeighborhoodId = a.NeighborhoodId,
                CenterLat = a.AvgLat,
                CenterLng = a.AvgLng,
                ExploredCount = a.ExploredCount,
                OwnedCount = owned,
                TotalCount = GameConstants.CellsPerNeighborhood,
                Percent = Math.Min(percent, 100.0),
                AreaName = "", // Will be filled below
            });

            geocodeTasks.Add((results.Count - 1, _geocoding.GetAreaName(a.AvgLat, a.AvgLng)));
        }

        // Await all geocoding (throttled internally, but cached hits resolve instantly)
        // Cap at 5 seconds total — return what we have if Nominatim is slow
        var allNames = Task.WhenAll(geocodeTasks.Select(t => t.Task));
        if (await Task.WhenAny(allNames, Task.Delay(5000)) == allNames)
        {
            var names = await allNames;
            for (int i = 0; i < geocodeTasks.Count; i++)
                results[geocodeTasks[i].Index].AreaName = names[i];
        }
        else
        {
            // Timeout — fill in whatever completed
            for (int i = 0; i < geocodeTasks.Count; i++)
            {
                if (geocodeTasks[i].Task.IsCompletedSuccessfully)
                    results[geocodeTasks[i].Index].AreaName = geocodeTasks[i].Task.Result;
                else
                    results[geocodeTasks[i].Index].AreaName = $"Area {i + 1}";
            }
        }

        // Merge neighborhoods that geocode to the same area name
        var merged = results
            .GroupBy(r => r.AreaName)
            .Select(g => new ExplorationNeighborhood
            {
                NeighborhoodId = g.First().NeighborhoodId,
                CenterLat = g.Average(r => r.CenterLat),
                CenterLng = g.Average(r => r.CenterLng),
                ExploredCount = g.Sum(r => r.ExploredCount),
                OwnedCount = g.Sum(r => r.OwnedCount),
                TotalCount = g.Sum(r => r.TotalCount),
                Percent = Math.Min(Math.Round(g.Sum(r => r.ExploredCount) * 100.0 / g.Sum(r => r.TotalCount), 1), 100.0),
                AreaName = g.Key,
            })
            .OrderByDescending(r => r.ExploredCount)
            .ToList();

        return merged;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Private helpers — ProcessClaim decomposition
    // ──────────────────────────────────────────────────────────────────────────

    private async Task<string?> ValidateClaim(Guid userId, double[][] path)
    {
        if (path.Length < GameConstants.MinGpsPointsPerClaim)
            return "Path too short — need at least 10 GPS points";

        var totalDistance = _geo.CalculatePathDistance(path);
        if (totalDistance < GameConstants.MinWalkDistanceMeters)
            return "Walk at least 200 meters before claiming";

        // The per-day cap is enforced INSIDE the claim transaction (under a per-user advisory
        // lock) so concurrent submissions can't slip past it via a check-then-act race.
        await Task.CompletedTask;
        return null;
    }

    private const int MaxClaimRetries = 3;

    /// <summary>
    /// Carries a committed claim's response plus the data its post-commit side effects need, so the
    /// broadcasts/pushes run <b>outside</b> the retrying execution strategy. Running them inside risks
    /// a transient (e.g. a Neon connection drop on a post-commit read) propagating out of the lambda
    /// and making EF re-run an already-committed claim — duplicate Claim row, double XP, re-fired
    /// broadcasts. <see cref="Pushed"/> is false for early-exit paths (e.g. daily cap) that did not commit.
    /// </summary>
    private sealed record TerritoryCommit<TResponse>(
        TResponse Response,
        bool Pushed,
        List<HexCell> CapturedHexes,
        List<CellTransfer> Transfers,
        Entities.User? User,
        XpGainResult? XpResult,
        int XpAmount,
        MissionProgressResult? MissionResult,
        List<AchievementUnlock> NewAchievements);

    /// <summary>
    /// True when an exception represents a write conflict worth retrying — a serialization
    /// failure (40001), deadlock (40P01), unique-violation from a concurrent insert (23505),
    /// or an EF optimistic-concurrency miss.
    /// </summary>
    private static bool IsTransientConflict(Exception ex)
    {
        for (Exception? e = ex; e != null; e = e.InnerException)
        {
            if (e is DbUpdateConcurrencyException) return true;
            if (e is Npgsql.PostgresException pg && pg.SqlState is "40001" or "40P01" or "23505")
                return true;
        }
        return false;
    }

    /// <summary>
    /// Records exploration for many cells in a single round-trip (replaces the per-cell N+1).
    /// Returns the number of genuinely new explorations.
    /// </summary>
    private async Task<int> RecordExplorationBatch(Guid userId, IEnumerable<long> cellIds)
    {
        var ids = cellIds.Distinct().ToList();
        if (ids.Count == 0) return 0;

        var now = DateTime.UtcNow;
        var sql = new StringBuilder(
            "INSERT INTO \"ExploredCells\" (\"UserId\", \"CellId\", \"NeighborhoodId\", \"FirstVisitedAt\") VALUES ");
        var args = new List<object>(ids.Count * 4);
        for (var i = 0; i < ids.Count; i++)
        {
            var b = i * 4;
            if (i > 0) sql.Append(',');
            sql.Append($"({{{b}}}, {{{b + 1}}}, {{{b + 2}}}, {{{b + 3}}})");
            args.Add(userId);
            args.Add(ids[i]);
            args.Add(_hexGrid.GetNeighborhoodId(ids[i]));
            args.Add(now);
        }
        sql.Append(" ON CONFLICT (\"UserId\", \"CellId\") DO NOTHING");
        return await _db.Database.ExecuteSqlRawAsync(sql.ToString(), args.ToArray());
    }

    // ────────────────────────────────────────────────────────────────────────────
    // Walk-session Claim correlation (#56 — one walk = one Claim)
    //
    // A "walk" is one continuous outing. The client stamps every batch-step drain and the
    // final loop claim with a single walkSessionId; the server uses it as the Claim primary
    // key so all of a walk's captures fold into one Claim (and one Walk History row) instead
    // of fragmenting into one row per drained batch plus a loop row.
    // ────────────────────────────────────────────────────────────────────────────

    /// <summary>Rejection message shared by both claim paths when the daily cap is hit.</summary>
    private static string DailyClaimCapMessage =>
        $"Daily limit reached — max {GameConstants.MaxClaimsPerDay} claims per day";

    /// <summary>
    /// True when the user has already reached <see cref="GameConstants.MaxClaimsPerDay"/> distinct
    /// walks today. One walk = one Claim (#56), so this counts today's Claims excluding this
    /// session's own Claim — the loop and every batch drain of a single walk must not each count.
    /// The single source of truth for the cap, shared by <c>ProcessClaim</c> and
    /// <c>ProcessBatchStepClaim</c>; call inside the claim transaction so the count is consistent
    /// with concurrent claims.
    /// </summary>
    private async Task<bool> IsDailyClaimCapReached(Guid userId, Guid sessionClaimId)
    {
        var todayStart = DateTime.UtcNow.Date;
        var todayClaimCount = await _db.Claims
            .CountAsync(c => c.UserId == userId && c.CreatedAt >= todayStart && c.Id != sessionClaimId);
        return todayClaimCount >= GameConstants.MaxClaimsPerDay;
    }

    /// <summary>
    /// Resolves the Claim id that should record this walk. Empty (older client) → a fresh id,
    /// so each batch stays a standalone claim as before. A supplied id that already belongs to
    /// ANOTHER user is never trusted (it would let a caller mutate someone else's claim) — a
    /// fresh id is used instead. Call inside the claim transaction so the lookup is consistent.
    /// </summary>
    private async Task<Guid> ResolveSessionClaimId(Guid userId, Guid walkSessionId)
    {
        if (walkSessionId == Guid.Empty)
            return Guid.NewGuid();

        var ownerId = await _db.Claims
            .Where(c => c.Id == walkSessionId)
            .Select(c => (Guid?)c.UserId)
            .FirstOrDefaultAsync();

        // No existing claim → safe to adopt. Already ours → reuse (merge into this walk).
        return ownerId == null || ownerId == userId ? walkSessionId : Guid.NewGuid();
    }

    /// <summary>
    /// Returns the walk's Claim, creating it on the first capture of the session. The id is
    /// assumed already resolved by <see cref="ResolveSessionClaimId"/> (i.e. unused or owned by
    /// this user). Loaded fresh inside the transaction so callers can additively accumulate
    /// CellCount idempotently across execution-strategy retries.
    /// </summary>
    private async Task<Claim> GetOrCreateSessionClaim(Guid userId, Guid claimId, double[][] path)
    {
        var claim = await _db.Claims.FindAsync(claimId);
        if (claim == null)
        {
            claim = new Claim { Id = claimId, UserId = userId, CreatedAt = DateTime.UtcNow };
            claim.SetPolygon(path);
            _db.Claims.Add(claim);
        }
        else
        {
            // Accumulate the whole walk's geometry into its single Claim (#56) — not just the
            // first batch — so anti-cheat forensics retain the full GPS path. The claim is
            // re-read fresh inside the cleared transaction block, so the append stays idempotent
            // across execution-strategy retries (a retry re-reads the committed path and re-adds
            // only this batch's slice).
            claim.AppendToPolygon(path, GameConstants.MaxClaimPathPoints);
        }
        return claim;
    }

    private async Task<(List<double[][]> Boundaries, List<CellTransfer> Transfers)> AssignCells(
        Guid userId, List<HexCell> cells, Guid claimId)
    {
        var transfers = new List<CellTransfer>();
        var boundaries = new List<double[][]>();
        var cooldownExpiry = DateTime.UtcNow.AddHours(GameConstants.CellCooldownHours);

        var cellIds = cells.Select(c => c.CellId).ToList();
        var existingCells = await _db.TerritoryCells
            .Where(t => cellIds.Contains(t.CellId))
            .ToDictionaryAsync(t => t.CellId);

        // Load user for decay calculation
        var assignUser = await _db.Users.FindAsync(userId);

        foreach (var hexCell in cells)
        {
            var cellCenter = _hexGrid.GetCellCenter(hexCell.CellId);

            // Calculate per-cell decay based on geographic comparison
            var cellDecayDays = await CalculateDecayDays(assignUser, cellCenter.Lat, cellCenter.Lng);

            if (existingCells.TryGetValue(hexCell.CellId, out var existing))
            {
                if (IsOnCooldown(existing)) continue;
                if (existing.OwnerId == userId) continue;
                transfers.Add(CreateTransfer(hexCell.CellId, existing.OwnerId, userId, claimId));
                UpdateExistingCell(existing, userId, claimId, hexCell, cooldownExpiry);
                existing.DecayDays = cellDecayDays;
            }
            else
            {
                var newCell = CreateNewCell(userId, claimId, hexCell, cooldownExpiry, cellDecayDays);
                _db.TerritoryCells.Add(newCell);
                transfers.Add(CreateTransfer(hexCell.CellId, null, userId, claimId));
            }

            boundaries.Add(hexCell.Boundary);
        }

        return (boundaries, transfers);
    }

    private static bool IsOnCooldown(TerritoryCell cell)
    {
        return cell.CooldownExpiresAt.HasValue && cell.CooldownExpiresAt.Value > DateTime.UtcNow;
    }

    private static CellTransfer CreateTransfer(long cellId, Guid? fromUserId, Guid toUserId, Guid claimId)
    {
        return new CellTransfer
        {
            Id = Guid.NewGuid(),
            CellId = cellId,
            FromUserId = fromUserId == toUserId ? null : fromUserId,
            ToUserId = toUserId,
            ClaimId = claimId,
            TransferredAt = DateTime.UtcNow,
        };
    }

    private void UpdateExistingCell(TerritoryCell cell, Guid userId, Guid claimId,
        HexCell hexCell, DateTime cooldownExpiry)
    {
        var center = _hexGrid.GetCellCenter(hexCell.CellId);
        cell.OwnerId = userId;
        cell.ClaimId = claimId;
        cell.ClaimedAt = DateTime.UtcNow;
        cell.LastRefreshedAt = DateTime.UtcNow;
        cell.CooldownExpiresAt = cooldownExpiry;
        cell.CenterLat = center.Lat;
        cell.CenterLng = center.Lng;
        cell.ParentCellId = _hexGrid.GetParentCellId(hexCell.CellId);
        cell.NeighborhoodId = _hexGrid.GetNeighborhoodId(hexCell.CellId);
        cell.SetBoundary(hexCell.Boundary);
    }

    private TerritoryCell CreateNewCell(Guid userId, Guid claimId, HexCell hexCell, DateTime cooldownExpiry, int decayDays = GameConstants.DecayDays)
    {
        var center = _hexGrid.GetCellCenter(hexCell.CellId);
        var cell = new TerritoryCell
        {
            CellId = hexCell.CellId,
            OwnerId = userId,
            ClaimId = claimId,
            ClaimedAt = DateTime.UtcNow,
            LastRefreshedAt = DateTime.UtcNow,
            CooldownExpiresAt = cooldownExpiry,
            CenterLat = center.Lat,
            CenterLng = center.Lng,
            ParentCellId = _hexGrid.GetParentCellId(hexCell.CellId),
            NeighborhoodId = _hexGrid.GetNeighborhoodId(hexCell.CellId),
            DecayDays = decayDays,
        };
        cell.SetBoundary(hexCell.Boundary);
        return cell;
    }

    /// <summary>
    /// Calculates decay days for a hex at (lat, lng) relative to the user's home.
    /// - If user has no home set → default 7 days (they need to set home in onboarding).
    /// - If within 30km of home → 7 days (skip geocoding, definitely same city).
    /// - If farther → reverse-geocode and compare city/state/country/continent.
    /// Geocoding results are cached per coordinate bucket so repeated nearby hexes are fast.
    /// </summary>
    private async Task<int> CalculateDecayDays(User? user, double hexLat, double hexLng)
    {
        // No home set → use default (user hasn't completed onboarding)
        if (user == null || user.HomeLat == null || user.HomeLng == null)
            return GameConstants.DecayDays;

        // Fast path: within 30km of home = definitely same city, no geocoding needed
        var distanceKm = _geo.HaversineMeters(
            user.HomeLat.Value, user.HomeLng.Value, hexLat, hexLng) / 1000.0;

        if (distanceKm < GameConstants.SameCityDistanceKm)
            return GameConstants.DecayDays;

        // Far from home → geocode the hex location and compare against user's home
        // GeocodingService caches results, so repeated calls for nearby hexes are free
        var hexLocation = await _geocoding.GetLocationInfo(hexLat, hexLng);

        if (hexLocation.IsEmpty)
        {
            // Geocoding failed — fall back to distance-based estimate
            return GameConstants.GetDecayDaysForDistance(distanceKm);
        }

        return GameConstants.GetDecayDaysFromLocation(
            user.HomeCity, user.HomeState, user.HomeCountry, user.HomeContinent,
            hexLocation.City, hexLocation.State, hexLocation.Country, hexLocation.Continent);
    }

    private async Task UpdateUserStats(Guid userId, List<CellTransfer> transfers)
    {
        var user = await _db.Users.FindAsync(userId);
        if (user == null) return;

        var newCells = transfers.Count(t => t.FromUserId == null);
        var stolenCells = transfers.Count(t => t.FromUserId != null);
        user.HexCount += newCells + stolenCells;
        user.TotalHexesCaptured += newCells + stolenCells;
        // NOTE: DistanceKm is intentionally NOT updated here. The live batch-step claim
        // path is the single source of truth for walked distance (#54) — it accumulated
        // this walk's full GPS distance before this loop-claim runs, so re-adding it here
        // would double-count distance on every walk-and-loop journey.

        UpdateStreak(user);
        await DecrementVictimHexCounts(userId, transfers);
    }

    private static void UpdateStreak(User user)
    {
        UpdateStreak(user, DateOnly.FromDateTime(DateTime.UtcNow));
    }

    /// <summary>
    /// Updates the user's streak using the supplied date as "today".
    /// Caller passes client's local date (clamped to UTC ±1 day) so users near
    /// timezone boundaries don't lose streaks. First-ever claim seeds streak=1
    /// without resetting an existing streak that was set elsewhere.
    ///
    /// Pairs with the background reaper <c>DecayCleanupService.BreakStaleStreaksAsync</c>: because
    /// this records LastClaimDate in the player's LOCAL frame (clamped to UTC ±1), the UTC-only
    /// reaper must allow a matching grace (<see cref="GameConstants.StreakBreakUtcGraceDays"/>) so
    /// it never breaks a streak this method still considers alive.
    /// </summary>
    private static void UpdateStreak(User user, DateOnly today)
    {
        if (user.LastClaimDate == null)
        {
            // First claim ever — start streak only if not already seeded by admin/import.
            if (user.Streak <= 0) user.Streak = 1;
        }
        else if (user.LastClaimDate < today.AddDays(-1))
        {
            user.Streak = 1; // Gap > 1 day → reset
        }
        else if (user.LastClaimDate == today.AddDays(-1))
        {
            user.Streak += 1; // Exactly yesterday → increment
        }
        // Same day → no change

        user.LastClaimDate = today;
        user.IsStreakActive = true;
        if (user.Streak > user.MaxStreak)
            user.MaxStreak = user.Streak;
    }


    private async Task<bool> RecordExploration(Guid userId, long cellId)
    {
        var neighborhoodId = _hexGrid.GetNeighborhoodId(cellId);
        var now = DateTime.UtcNow;

        // Upsert: INSERT ... ON CONFLICT DO NOTHING — single round-trip, no race conditions
        var rowsAffected = await _db.Database.ExecuteSqlAsync($"""
            INSERT INTO "ExploredCells" ("UserId", "CellId", "NeighborhoodId", "FirstVisitedAt")
            VALUES ({userId}, {cellId}, {neighborhoodId}, {now})
            ON CONFLICT ("UserId", "CellId") DO NOTHING
            """);
        return rowsAffected > 0;
    }

    private async Task DecrementVictimHexCounts(Guid userId, List<CellTransfer> transfers)
    {
        var stolenGroups = transfers
            .Where(t => t.FromUserId != null && t.FromUserId != userId)
            .GroupBy(t => t.FromUserId!.Value)
            .ToList();

        if (stolenGroups.Count == 0) return;

        var victimIds = stolenGroups.Select(g => g.Key).ToList();
        var victims = await _db.Users
            .Where(u => victimIds.Contains(u.Id))
            .ToDictionaryAsync(u => u.Id);

        foreach (var group in stolenGroups)
        {
            if (victims.TryGetValue(group.Key, out var victim))
            {
                victim.HexCount = Math.Max(0, victim.HexCount - group.Count());
            }
        }
    }

    // NOTE: All post-commit notification helpers are AWAITED by callers (so they run
    // while the request-scoped DbContext is still alive) and self-protect with try/catch
    // (so a push/broadcast failure can never fail or roll back an already-committed claim).
    private async Task BroadcastOwnershipChanges(
        Guid userId, List<HexCell> cells, List<CellTransfer> transfers)
    {
        try
        {
            var user = await _db.Users.FindAsync(userId);
            if (user == null) return;

            var transferLookup = transfers
                .Where(t => t.FromUserId != null)
                .ToDictionary(t => t.CellId, t => t.FromUserId);

            var changes = cells.Select(c =>
            {
                var center = _hexGrid.GetCellCenter(c.CellId);
                return new HexChangeEvent(
                    H3Index: c.CellId.ToString(),
                    CenterLat: center.Lat,
                    CenterLng: center.Lng,
                    NewOwnerId: userId,
                    NewOwnerColor: user.Color,
                    NewOwnerDisplayName: user.DisplayName,
                    PreviousOwnerId: transferLookup.GetValueOrDefault(c.CellId),
                    ParentCellId: _hexGrid.GetParentCellId(c.CellId)
                );
            }).ToList();

            await _notifier.NotifyHexOwnershipChanged(changes);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to broadcast ownership changes for user {UserId}", userId);
        }
    }

    private async Task NotifyVictimsOfTheft(Guid thiefUserId, List<CellTransfer> transfers)
    {
        try
        {
            var thief = await _db.Users.FindAsync(thiefUserId);
            if (thief == null) return;

            var victimGroups = transfers
                .Where(t => t.FromUserId != null && t.FromUserId != thiefUserId)
                .GroupBy(t => t.FromUserId!.Value);

            foreach (var group in victimGroups)
            {
                await _pushService.NotifyHexStolen(group.Key, thief.DisplayName, group.Count());
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify theft victims for thief {UserId}", thiefUserId);
        }
    }

    /// <summary>
    /// Pushes all personal state deltas to the claiming user via SignalR.
    /// Fire-and-forget — errors are logged but don't block the claim response.
    /// </summary>
    private async Task PushPersonalDeltas(
        Guid userId,
        Entities.User? user,
        XpGainResult xpResult,
        int xpAmount,
        MissionProgressResult? missionResult,
        List<AchievementUnlock> newAchievements)
    {
        try
        {
            if (user == null) return;

            // 1. User stats (absolute values)
            var statsDelta = new UserStatsDelta(
                HexCount: user.HexCount,
                TotalHexesCaptured: user.TotalHexesCaptured,
                TotalHexesStolen: user.TotalHexesStolen,
                Streak: user.Streak,
                IsStreakActive: user.IsStreakActive,
                DistanceKm: user.DistanceKm
            );
            await _notifier.NotifyUserStatsAsync(userId, statsDelta);

            // 2. XP delta
            var neededXp = GameConstants.XpForLevel(xpResult.Level + 1) - GameConstants.XpForLevel(xpResult.Level);
            var progressXp = (int)(xpResult.TotalXp - GameConstants.XpForLevel(xpResult.Level));
            var progressPercent = neededXp > 0 ? (double)progressXp / neededXp : 0;

            var xpDelta = new XpDelta(
                XpGained: xpAmount + (missionResult?.XpEarned ?? 0),
                TotalXp: xpResult.TotalXp,
                Level: xpResult.Level,
                LeveledUp: xpResult.LeveledUp,
                ProgressXp: progressXp,
                NeededXp: neededXp,
                ProgressPercent: progressPercent
            );
            await _notifier.NotifyXpAsync(userId, xpDelta);

            // 3. Mission progress
            if (missionResult?.Missions != null)
            {
                var missionUpdates = missionResult.Missions.Select(m => new MissionUpdate(
                    MissionId: m.Id,
                    Type: m.Type.ToString(),
                    CurrentProgress: m.CurrentProgress,
                    TargetValue: m.TargetValue,
                    Completed: m.IsCompleted,
                    XpAwarded: m.IsCompleted ? m.XpReward : 0
                )).ToList();

                var missionDelta = new MissionDelta(
                    Updates: missionUpdates,
                    AllMissionsComplete: missionResult.AllMissionsComplete,
                    BonusXp: missionResult.BonusXp
                );
                await _notifier.NotifyMissionAsync(userId, missionDelta);
            }

            // 4. Achievement unlocks
            if (newAchievements.Count > 0)
            {
                var achievementDelta = new AchievementDelta(
                    Unlocks: newAchievements.Select(a => new AchievementUnlockEvent(
                        Id: a.AchievementId,
                        Name: a.Name,
                        Icon: a.Icon,
                        XpAwarded: a.XpAwarded
                    )).ToList()
                );
                await _notifier.NotifyAchievementAsync(userId, achievementDelta);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to push personal deltas to user {UserId}", userId);
        }
    }

    /// <summary>
    /// Pushes decremented stats to theft victim via SignalR.
    /// </summary>
    private async Task PushVictimDelta(Guid victimUserId)
    {
        try
        {
            var victim = await _db.Users.AsNoTracking().FirstOrDefaultAsync(u => u.Id == victimUserId);
            if (victim == null) return;

            var statsDelta = new UserStatsDelta(
                HexCount: victim.HexCount,
                TotalHexesCaptured: victim.TotalHexesCaptured,
                TotalHexesStolen: victim.TotalHexesStolen,
                Streak: victim.Streak,
                IsStreakActive: victim.IsStreakActive,
                DistanceKm: victim.DistanceKm
            );
            await _notifier.NotifyUserStatsAsync(victimUserId, statsDelta);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to push victim delta to user {UserId}", victimUserId);
        }
    }
}
