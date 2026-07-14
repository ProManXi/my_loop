/// Journey screen — live map view for recording territory-capturing walks.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import 'package:myloop/app/theme.dart';
import 'package:myloop/features/journey/journey_controller.dart';
import 'package:myloop/features/journey/hex_overlay.dart';
import 'package:myloop/features/journey/hex_territory_manager.dart';
import 'package:myloop/features/journey/celebration_dialog.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/mock/mock_walk_config.dart';
import 'package:myloop/shared/services/location_service.dart';
import 'package:myloop/features/dev/mock_walk_overlay.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/state/hydration.dart';
import 'package:myloop/shared/state/profile_slice.dart';
import 'package:myloop/shared/widgets/avatar_widget.dart';
import 'package:myloop/shared/widgets/big_button.dart';
import 'package:myloop/shared/models/territory_cell.dart';
import 'package:myloop/features/profile/user_profile_screen.dart';
import 'package:myloop/shared/constants/app_constants.dart';
import 'package:myloop/shared/services/notification_service.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Screen
// ──────────────────────────────────────────────────────────────────────────────

class JourneyScreen extends ConsumerStatefulWidget {
  const JourneyScreen({super.key});

  @override
  ConsumerState<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends ConsumerState<JourneyScreen> {
  final _mapKey = GlobalKey<_JourneyMapState>();
  bool _isSubmitting = false;
  bool _controlsVisible = true;

  Future<void> _onStopCapture() async {
    if (_isSubmitting) return;

    final journey = ref.read(journeyControllerProvider);
    final controller = ref.read(journeyControllerProvider.notifier);

    final walkDistance = journey.distanceMeters;
    final walkDuration = journey.elapsed;
    final claimedCount = journey.claimedCount;
    // Read before stopJourney so the loop claim shares this walk's session id, folding it
    // into the same Claim as the walk's batch-step captures (#56). Coalesce a null/empty id to
    // a fresh UUID — mirroring the batch drainer — so the wire value is always a parseable Guid
    // and the loop claim can never 400 on an empty string.
    final rawSessionId = controller.walkSessionId;
    final walkSessionId = (rawSessionId == null || rawSessionId.isEmpty)
        ? const Uuid().v4()
        : rawSessionId;
    final path = controller.stopJourney();

    // If user hasn't walked at all
    if (path.length < 2 && claimedCount == 0) {
      _showSnackbar('Walk a bit more to capture territory!', Colors.orange);
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      // Walk-through claims already captured hexes during the walk.
      // Try loop-based bonus claim if a loop was completed.
      int bonusCount = 0;
      int stolenCount = 0;
      if (journey.loopCount > 0 && path.length >= 2) {
        final api = ref.read(apiServiceProvider);
        final profile = ref.read(userProfileProvider);
        if (profile.userId != null) {
          final result = await api.submitClaim(
              userId: profile.userId!, path: path, walkSessionId: walkSessionId);
          // Use newlyClaimedCount (hexes this loop claim actually added — interior fill +
          // steals), NOT cellCount (total enclosed cells, which includes the trail hexes
          // already counted in claimedCount during the walk). Adding cellCount here
          // over-counts the capture celebration by the trail length (issue #55).
          bonusCount = (result['newlyClaimedCount'] as num?)?.toInt() ?? 0;
          stolenCount = (result['stolenFromOthers'] as num?)?.toInt() ?? 0;
          _renderCapturedHexes(result);
          // The bonus claim is reflected by the server's UserStatsDelta push
          // (consumed live by userProfileProvider) and reconciled authoritatively
          // by _refreshUserData below — no local optimistic add, which would
          // double-count the bonus on top of the pushed value (issue #30).
        }
      }

      _mapKey.currentState?.forceReloadHexes();

      final api = ref.read(apiServiceProvider);
      final profile = ref.read(userProfileProvider);
      if (profile.userId != null) {
        await _refreshUserData(profile, api);
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: AppConstants.celebrationDelayMs));
          if (mounted) {
            final user = await api.getUser(profile.userId!);
            final totalCaptured = claimedCount + bonusCount;
            _showCelebration(totalCaptured, stolenCount, walkDistance, walkDuration, user.streak, journey.xpGainedThisWalk);
          }
        }
      }
    } catch (e) {
      _showSnackbar('Error: ${e.toString().replaceFirst('Exception: ', '')}', AppColors.red);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _renderCapturedHexes(Map<String, dynamic> result) {
    final rawBoundaries = result['boundaries'] as List<dynamic>?;
    if (rawBoundaries == null || rawBoundaries.isEmpty) return;

    final boundaries = rawBoundaries
        .map<List<List<double>>>((b) => (b as List<dynamic>)
            .map<List<double>>(
                (point) => (point as List<dynamic>).map<double>((v) => (v as num).toDouble()).toList())
            .toList())
        .toList();
    _mapKey.currentState?.showCapturedHexes(boundaries);
  }

  Future<void> _refreshUserData(dynamic profile, ApiService api) async {
    // Re-hydrate all slices (single API call) — SignalR may already have
    // pushed deltas, but this ensures consistency for the celebration dialog.
    await hydrateAllSlices(ref);
    final ps = ref.read(profileSliceProvider);

    int updatedRank = profile.rank;
    try {
      // The board refreshes on a background timer now (#109), not on client request; read
      // whatever the latest snapshot is rather than forcing a recompute.
      final lb = await api.getLeaderboard(lat: 0, lng: 0, userId: profile.userId!, scope: 'city');
      updatedRank = lb.myRank ?? profile.rank;
    } catch (_) {}

    if (mounted) {
      ref.read(userProfileProvider.notifier).updateStats(
        hexCount: ps.hexCount,
        streak: ps.streak,
        distanceKm: ps.distanceKm,
        rank: updatedRank,
      );
    }
  }

  void _showCelebration(int hexCount, int stolenCount, double distance, Duration duration, int streak, int xpGained) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => CelebrationDialog(
        hexCount: hexCount,
        stolenCount: stolenCount,
        distanceMeters: distance,
        duration: duration,
        streak: streak,
        xpGained: xpGained,
      ),
    );
  }

  void _showSnackbar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(message), backgroundColor: color),
      );
  }

  @override
  Widget build(BuildContext context) {
    final journey = ref.watch(journeyControllerProvider);
    final controller = ref.read(journeyControllerProvider.notifier);
    final topPadding = MediaQuery.of(context).padding.top;

    ref.listen(journeyControllerProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        _showSnackbar(next.error!, AppColors.red);
      }
      // Level-up celebration
      if (next.levelUpTo != null && next.levelUpTo != prev?.levelUpTo) {
        _showSnackbar('🎉 Level Up! You reached Level ${next.levelUpTo}!', const Color(0xFFFFD700));
      }
      // Achievement unlock
      if (next.achievementUnlocked != null && next.achievementUnlocked != prev?.achievementUnlocked) {
        _showSnackbar('🏆 Achievement: ${next.achievementUnlocked}', const Color(0xFF8B5CF6));
      }
    });

    final mockEnabled = kDebugMode && ref.watch(mockWalkConfigProvider).enabled;

    return Scaffold(
      // Debug-only entry to the mock walk simulator (#29), shown before a walk starts.
      floatingActionButton: (kDebugMode && journey.status == JourneyStatus.idle)
          ? FloatingActionButton.small(
              heroTag: 'mockWalkFab',
              tooltip: 'Mock walk (debug)',
              onPressed: () => context.push('/dev/mock-walk'),
              child: const Icon(Icons.bug_report),
            )
          : null,
      body: Stack(
        children: [
          _JourneyMap(
            key: _mapKey,
            journey: journey,
            onMapTapEmpty: () {
              if (journey.status == JourneyStatus.tracking) {
                setState(() => _controlsVisible = !_controlsVisible);
              }
            },
          ),
          _CloseButton(padding: topPadding),
          if (mockEnabled)
            Positioned(
              top: topPadding + 18,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.deepOrange,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('MOCK', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          // Debug-only mock-walk HUD / post-run summary (#29 follow-up). Read-only;
          // never feeds back into the GPS stream. Only built while the mock is on.
          if (mockEnabled && journey.status == JourneyStatus.tracking)
            Positioned(
              top: topPadding + 54,
              right: 16,
              child: const MockWalkOverlay(),
            ),
          // LIVE indicator — always visible on map (right of close button)
          Positioned(
            top: topPadding + 18,
            left: 68,
            child: _LiveIndicator(
              claimedCount: journey.status == JourneyStatus.tracking ? journey.claimedCount : 0,
              showCount: journey.status == JourneyStatus.tracking,
            ),
          ),
          if (journey.status == JourneyStatus.tracking && _controlsVisible)
            Positioned(
              top: topPadding + 64,
              left: 0,
              child: _StatsBar(journey: journey, loopCount: journey.loopCount),
            ),
          if (_controlsVisible)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: _BottomControls(
                journey: journey,
                isSubmitting: _isSubmitting,
                onStartJourney: controller.startJourney,
                onStopCapture: _onStopCapture,
              ),
            ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Close Button
// ──────────────────────────────────────────────────────────────────────────────

class _CloseButton extends StatelessWidget {
  final double padding;
  const _CloseButton({required this.padding});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: padding + 12,
      left: 16,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: AppColors.white,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: const Icon(Icons.close, color: AppColors.dark, size: 22),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Map
// ──────────────────────────────────────────────────────────────────────────────

class _JourneyMap extends ConsumerStatefulWidget {
  final JourneyState journey;
  final VoidCallback? onMapTapEmpty;
  const _JourneyMap({super.key, required this.journey, this.onMapTapEmpty});

  @override
  ConsumerState<_JourneyMap> createState() => _JourneyMapState();
}

class _JourneyMapState extends ConsumerState<_JourneyMap> {
  final MapController _mapController = MapController();
  Position? _initialPosition;
  LatLng? _fallbackCenter;
  Timer? _locationTimer;
  Timer? _hexRefreshTimer;
  bool _mapReady = false;
  bool _followUser = true;
  bool _locationError = false;
  double _currentZoom = 17.0;
  bool _useSatellite = true;
  bool _solidHexes = false;
  List<List<List<double>>> _capturedHexBoundaries = [];
  late HexTerritoryManager _hexManager;
  StreamSubscription<List<HexChangeEvent>>? _realtimeSub;

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiServiceProvider);
    final profile = ref.read(userProfileProvider);
    _hexManager = HexTerritoryManager(api: api, userId: profile.userId);
    _acquireLocation();
    _hexRefreshTimer = Timer.periodic(
      const Duration(seconds: AppConstants.hexRefreshIntervalSeconds),
      (_) => _refreshViewportHexes(),
    );
    _connectRealtime();
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    _hexRefreshTimer?.cancel();
    _realtimeSub?.cancel();
    ref.read(territoryRealtimeProvider).disconnect();
    _mapController.dispose();
    super.dispose();
  }

  void _connectRealtime() {
    final realtimeService = ref.read(territoryRealtimeProvider);
    realtimeService.connect();
    _realtimeSub = realtimeService.onHexChanges.listen((events) {
      final changed = _hexManager.applyRealtimeChanges(events);
      if (changed && mounted) setState(() {});

      // Detect thefts from the current user → add in-app notifications
      final userId = ref.read(userProfileProvider).userId;
      if (userId != null) {
        final stolenByThief = <String, List<HexChangeEvent>>{};
        for (final e in events) {
          if (e.previousOwnerId == userId && e.newOwnerId != userId) {
            stolenByThief.putIfAbsent(e.newOwnerDisplayName, () => []).add(e);
          }
        }
        for (final entry in stolenByThief.entries) {
          ref.read(notificationProvider.notifier).addTheftAlert(
            thiefName: entry.key,
            thiefColor: entry.value.first.newOwnerColor,
            hexCount: entry.value.length,
          );
        }
      }
    });
  }

  void _updateRealtimeRegions() {
    final realtimeService = ref.read(territoryRealtimeProvider);
    if (!realtimeService.isConnected) return;
    final regionIds = _hexManager.getActiveRegionIds();
    if (regionIds.isNotEmpty) {
      realtimeService.updateRegions(regionIds);
    }
  }

  Future<void> _acquireLocation() async {
    try {
      final locationService = ref.read(locationServiceProvider);
      await locationService.requestPermission();
      final pos = await locationService.getCurrentPosition();
      if (mounted && pos.latitude.isFinite && pos.longitude.isFinite) {
        setState(() { _initialPosition = pos; _locationError = false; });
        if (_mapReady && _followUser) {
          _mapController.move(LatLng(pos.latitude, pos.longitude), 17);
        }
        await _hexManager.loadUserOwnHexes();
        await _hexManager.loadWideArea(pos.latitude, pos.longitude);
        _updateRealtimeRegions();
        if (mounted) setState(() {});
      } else if (mounted) {
        setState(() => _locationError = true);
      }
    } catch (_) {
      if (mounted) setState(() => _locationError = true);
    }
  }

  Future<void> _refreshViewportHexes() async {
    if (!_mapReady) return;
    // LOD: Only load other players' individual hexes at zoom 14+
    // At lower zoom, only the user's own hexes (preloaded) are visible
    if (_currentZoom < 14.0) return;
    final bounds = _mapController.camera.visibleBounds;
    await _hexManager.loadViewport(
      minLat: bounds.south, minLng: bounds.west,
      maxLat: bounds.north, maxLng: bounds.east,
    );
    _updateRealtimeRegions();
    if (mounted) setState(() {});
  }

  Future<void> _refreshPosition() async {
    final journey = ref.read(journeyControllerProvider);
    if (journey.status == JourneyStatus.tracking) return;
    try {
      final locationService = ref.read(locationServiceProvider);
      final pos = await locationService.getCurrentPosition();
      if (mounted && pos.latitude.isFinite && pos.longitude.isFinite) {
        setState(() => _initialPosition = pos);
        if (_mapReady && _followUser) {
          _mapController.move(LatLng(pos.latitude, pos.longitude), _mapController.camera.zoom);
        }
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant _JourneyMap old) {
    super.didUpdateWidget(old);
    _manageLocationPolling();
    _followCurrentPosition();
    _integrateNewStepClaims(old.journey, widget.journey);
  }

  /// When new step claims arrive, integrate them into the hex territory manager
  /// so stolen hexes disappear from the "other players" layer immediately.
  void _integrateNewStepClaims(JourneyState prev, JourneyState next) {
    if (next.claimedMeta.length <= prev.claimedMeta.length) return;
    // Process only the new claims since last update
    final newClaims = next.claimedMeta.sublist(prev.claimedMeta.length);
    bool hadStolen = false;
    for (final meta in newClaims) {
      _hexManager.integrateStepClaim(meta.boundary, meta.cellId, meta.wasStolen);
      if (meta.wasStolen) hadStolen = true;
    }
    // If a stolen hex was removed from others, trigger map repaint
    if (hadStolen && mounted) setState(() {});
  }

  void _manageLocationPolling() {
    if (widget.journey.status == JourneyStatus.tracking && _locationTimer == null) {
      _locationTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshPosition());
    } else if (widget.journey.status != JourneyStatus.tracking && _locationTimer != null) {
      _locationTimer?.cancel();
      _locationTimer = null;
    }
  }

  void _followCurrentPosition() {
    final pos = widget.journey.currentPosition;
    if (pos != null && _mapReady && _followUser && pos.latitude.isFinite && pos.longitude.isFinite) {
      _mapController.move(LatLng(pos.latitude, pos.longitude), _mapController.camera.zoom);
    }
  }

  void showCapturedHexes(List<List<List<double>>> boundaries) {
    setState(() {
      _capturedHexBoundaries = boundaries;
      _hexManager.addCapturedHexes(boundaries);
    });
  }

  void forceReloadHexes() {
    _hexManager.loadUserOwnHexes().then((_) {
      if (mounted) setState(() {});
    });
    if (_mapReady) {
      _refreshViewportHexes();
    } else if (_initialPosition != null) {
      _hexManager.loadWideArea(_initialPosition!.latitude, _initialPosition!.longitude).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _onMapTap(LatLng latLng) {
    final tappedCell = _findTappedCell(latLng.latitude, latLng.longitude);
    if (tappedCell != null) {
      _showHexOwnerSheet(tappedCell);
    } else {
      widget.onMapTapEmpty?.call();
    }
  }

  TerritoryCell? _findTappedCell(double lat, double lng) {
    for (final cell in _hexManager.allCells) {
      if (_pointInPolygon(lat, lng, cell.boundary)) return cell;
    }
    return null;
  }

  static bool _pointInPolygon(double lat, double lng, List<List<double>> polygon) {
    var inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final yi = polygon[i][0], xi = polygon[i][1];
      final yj = polygon[j][0], xj = polygon[j][1];
      if (((yi > lat) != (yj > lat)) && (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }

  void _showHexOwnerSheet(TerritoryCell cell) {
    final profile = ref.read(userProfileProvider);
    final isOwn = cell.ownerId == profile.userId;
    // Show owner's actual color only for own hexes; black for others
    final ownerColor = isOwn
        ? Color(int.parse(cell.ownerColor.replaceFirst('#', ''), radix: 16) | 0xFF000000)
        : const Color(0xFF1A1A1A);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _HexOwnerSheet(
        cell: cell,
        isOwn: isOwn,
        ownerColor: ownerColor,
        onViewProfile: () {
          Navigator.pop(ctx);
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => UserProfileScreen(
              userId: cell.ownerId,
              name: cell.ownerName,
              avatarId: 0,
              color: cell.ownerColor,
              rank: 0,
            ),
          ));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final journey = widget.journey;
    final profile = ref.watch(userProfileProvider);
    final userColor = Color(int.parse(profile.color.replaceFirst('#', ''), radix: 16) | 0xFF000000);

    if (_initialPosition == null && _fallbackCenter == null && journey.currentPosition == null) {
      return _buildLoadingState();
    }

    final center = _resolveCenter(journey);

    return Stack(
      children: [
        _buildMap(center, journey, profile, userColor),
        if (!_followUser) _buildRecenterButton(),
        _buildTopRightControls(context, profile, userColor),
      ],
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_locationError) ...[
            const Icon(Icons.location_off, size: 48, color: AppColors.grey),
            const SizedBox(height: 12),
            const Text('Could not get your location', style: TextStyle(color: AppColors.grey)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () { setState(() => _locationError = false); _acquireLocation(); },
              child: const Text('Retry'),
            ),
          ] else ...[
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 16),
            const Text('Getting your location...', style: TextStyle(color: AppColors.grey)),
          ],
        ],
      ),
    );
  }

  LatLng _resolveCenter(JourneyState journey) {
    if (journey.currentPosition != null) {
      return LatLng(journey.currentPosition!.latitude, journey.currentPosition!.longitude);
    }
    if (_initialPosition != null) {
      return LatLng(_initialPosition!.latitude, _initialPosition!.longitude);
    }
    return _fallbackCenter!;
  }

  Widget _buildMap(LatLng center, JourneyState journey, dynamic profile, Color userColor) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: 17,
        minZoom: 3.0,
        maxZoom: 20.0,
        cameraConstraint: CameraConstraint.contain(
          bounds: LatLngBounds(LatLng(-85, -180), LatLng(85, 180)),
        ),
        onMapReady: () {
          _mapReady = true;
          final target = _initialPosition != null
              ? LatLng(_initialPosition!.latitude, _initialPosition!.longitude)
              : _fallbackCenter;
          if (target != null) _mapController.move(target, 17);
        },
        onPositionChanged: (pos, hasGesture) {
          if (pos.zoom != _currentZoom) setState(() => _currentZoom = pos.zoom);
          if (hasGesture && _followUser) setState(() => _followUser = false);
        },
        onTap: (tapPos, latLng) => _onMapTap(latLng),
      ),
      children: [
        _buildTileLayer(),
        if (_useSatellite) _buildLabelsLayer(),
        ..._buildOtherPlayerHexes(),
        if (_hexManager.userOwnHexBoundaries.isNotEmpty)
          AnimatedHexOverlay(
            hexBoundaries: _hexManager.userOwnHexBoundaries,
            userColor: userColor,
            currentZoom: _currentZoom,
            solidMode: _solidHexes,
            decayValues: _hexManager.userOwnDecayValues,
          ),
        // Walk-through claimed hexes — appear instantly as user walks
        if (journey.claimedHexBoundaries.isNotEmpty)
          AnimatedHexOverlay(
            hexBoundaries: journey.claimedHexBoundaries,
            userColor: userColor,
            currentZoom: _currentZoom,
            isNewCapture: true,
            solidMode: _solidHexes,
          ),
        if (journey.previewBoundaries.isNotEmpty)
          AnimatedHexOverlay(
            hexBoundaries: journey.previewBoundaries,
            userColor: userColor.withAlpha(140),
            currentZoom: _currentZoom,
            isNewCapture: true,
            solidMode: false,
          ),
        if (_capturedHexBoundaries.isNotEmpty)
          AnimatedHexOverlay(
            hexBoundaries: _capturedHexBoundaries,
            userColor: userColor,
            currentZoom: _currentZoom,
            isNewCapture: true,
            solidMode: _solidHexes,
          ),
        if (journey.path.length > 1) _buildPathPolyline(journey),
        if (_currentZoom >= 15) _buildCooldownMarkers(),
        _buildPositionMarker(journey, profile, userColor),
      ],
    );
  }

  MarkerLayer _buildCooldownMarkers() {
    final frozenCells = _hexManager.allCells
        .where((c) => c.isOnCooldown)
        .toList();

    return MarkerLayer(
      markers: frozenCells.map((cell) {
        final center = _cellCenter(cell.boundary);
        final remaining = cell.cooldownRemaining;
        final label = remaining.inMinutes >= 60
            ? '${remaining.inHours}h${remaining.inMinutes % 60}m'
            : '${remaining.inMinutes}m';

        return Marker(
          point: LatLng(center[0], center[1]),
          width: 52,
          height: 22,
          child: _CooldownTimerChip(label: label),
        );
      }).toList(),
    );
  }

  List<double> _cellCenter(List<List<double>> boundary) {
    if (boundary.isEmpty) return [0, 0];
    double lat = 0, lng = 0;
    for (final p in boundary) {
      lat += p[0];
      lng += p[1];
    }
    return [lat / boundary.length, lng / boundary.length];
  }

  TileLayer _buildTileLayer() {
    return TileLayer(
      urlTemplate: _useSatellite
          ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
          : 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
      subdomains: _useSatellite ? const [] : const ['a', 'b', 'c', 'd'],
      userAgentPackageName: 'com.myloop.app',
      keepBuffer: 4,
      panBuffer: 2,
      maxNativeZoom: 19,
    );
  }

  TileLayer _buildLabelsLayer() {
    return TileLayer(
      urlTemplate: 'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
      userAgentPackageName: 'com.myloop.app',
    );
  }

  List<Widget> _buildOtherPlayerHexes() {
    // LOD: Only render other players' hexes at zoom 14+
    if (_currentZoom < 14.0) return [];
    // Show all other players' hexes in dark black regardless of their profile color
    final allOtherBoundaries = _hexManager.otherHexesByColor.values
        .expand((list) => list)
        .toList();
    if (allOtherBoundaries.isEmpty) return [];
    return [AnimatedHexOverlay(
      hexBoundaries: allOtherBoundaries,
      userColor: const Color(0xFF1A1A1A),
      currentZoom: _currentZoom,
      isNewCapture: false,
      solidMode: _solidHexes,
    )];
  }

  PolylineLayer _buildPathPolyline(JourneyState journey) {
    return PolylineLayer(
      polylines: [
        Polyline(
          points: journey.path.map((p) => LatLng(p[0], p[1])).toList(),
          color: AppColors.primary,
          strokeWidth: 4,
        ),
      ],
    );
  }

  MarkerLayer _buildPositionMarker(JourneyState journey, dynamic profile, Color userColor) {
    final point = journey.currentPosition != null
        ? LatLng(journey.currentPosition!.latitude, journey.currentPosition!.longitude)
        : _initialPosition != null
            ? LatLng(_initialPosition!.latitude, _initialPosition!.longitude)
            : _fallbackCenter!;

    return MarkerLayer(
      markers: [
        Marker(
          point: point, width: 44, height: 44,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.white, width: 3),
              boxShadow: [BoxShadow(color: userColor.withValues(alpha: 0.4), blurRadius: 10, spreadRadius: 3)],
            ),
            child: ClipOval(child: AvatarWidget(avatarId: profile.avatarId, color: profile.color, size: 38)),
          ),
        ),
      ],
    );
  }

  Widget _buildRecenterButton() {
    return Positioned(
      bottom: 140, right: 16,
      child: GestureDetector(
        onTap: () {
          setState(() => _followUser = true);
          final pos = widget.journey.currentPosition ?? _initialPosition;
          if (pos != null && _mapReady) {
            _mapController.move(LatLng(pos.latitude, pos.longitude), _mapController.camera.zoom);
          }
        },
        child: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: AppColors.white, shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: const Icon(Icons.my_location, color: AppColors.primary, size: 24),
        ),
      ),
    );
  }

  Widget _buildTopRightControls(BuildContext context, dynamic profile, Color userColor) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      right: 16,
      child: Column(
        children: [
          _CircleButton(
            icon: _useSatellite ? Icons.dark_mode : Icons.satellite_alt,
            onTap: () => setState(() => _useSatellite = !_useSatellite),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(0, 2))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.hexagon, color: userColor, size: 18),
                const SizedBox(width: 4),
                Text('${profile.hexCount}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.dark)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _CircleButton(
            icon: _solidHexes ? Icons.visibility_off : Icons.visibility,
            color: _solidHexes ? userColor : AppColors.white,
            iconColor: _solidHexes ? AppColors.white : AppColors.dark,
            onTap: () => setState(() => _solidHexes = !_solidHexes),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Small reusable widgets
// ──────────────────────────────────────────────────────────────────────────────

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  final Color iconColor;

  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.color = AppColors.white,
    this.iconColor = AppColors.dark,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: color, shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
    );
  }
}

class _HexOwnerSheet extends StatelessWidget {
  final TerritoryCell cell;
  final bool isOwn;
  final Color ownerColor;
  final VoidCallback onViewProfile;

  const _HexOwnerSheet({
    required this.cell,
    required this.isOwn,
    required this.ownerColor,
    required this.onViewProfile,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.greyLight, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),
          Row(
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: ownerColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ownerColor, width: 2),
                ),
                child: const Icon(Icons.hexagon, size: 28, color: Colors.white70),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOwn ? 'Your Hex' : '${cell.ownerName}\'s Hex',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                    ),
                    Text(
                      isOwn ? 'You own this territory' : 'Owned by ${cell.ownerName}',
                      style: TextStyle(color: AppColors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (cell.isOnCooldown) ...[
            const SizedBox(height: 16),
            _CooldownBanner(cell: cell),
          ],
          if (!isOwn) ...[
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onViewProfile,
                icon: const Icon(Icons.person, size: 18),
                label: Text('View ${cell.ownerName}\'s Profile'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CooldownBanner extends StatelessWidget {
  final TerritoryCell cell;
  const _CooldownBanner({required this.cell});

  @override
  Widget build(BuildContext context) {
    final remaining = cell.cooldownRemaining;
    final text = remaining.inMinutes >= 60
        ? '${remaining.inHours}h ${remaining.inMinutes % 60}m'
        : '${remaining.inMinutes}m';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2196F3).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2196F3).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield, color: Color(0xFF2196F3), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Protected — $text remaining',
              style: const TextStyle(
                color: Color(0xFF2196F3),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Stats & Controls
// ──────────────────────────────────────────────────────────────────────────────

class _StatsBar extends StatelessWidget {
  final JourneyState journey;
  final int loopCount;
  const _StatsBar({required this.journey, this.loopCount = 0});

  @override
  Widget build(BuildContext context) {
    final minutes = journey.elapsed.inMinutes;
    final seconds = journey.elapsed.inSeconds % 60;
    final distanceKm = journey.distanceMeters / 1000;

    return Container(
      margin: const EdgeInsets.only(left: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Table(
        columnWidths: const { 0: FixedColumnWidth(24), 1: IntrinsicColumnWidth() },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          _statRow(Icons.schedule_rounded, const Color(0xFF00D4AA),
            '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'),
          _spacerRow(),
          _statRow(Icons.route_rounded, const Color(0xFF6C5CE7),
            distanceKm >= 1 ? '${distanceKm.toStringAsFixed(2)} km' : '${journey.distanceMeters.toInt()} m'),
          _spacerRow(),
          _statRow(Icons.loop_rounded, const Color(0xFFF59E0B),
            loopCount > 0 ? '$loopCount loop${loopCount > 1 ? 's' : ''}' : 'No loop'),
          if (journey.xpGainedThisWalk > 0) ...[
            _spacerRow(),
            _statRow(Icons.star_rounded, const Color(0xFFFFD700),
              '+${journey.xpGainedThisWalk} XP'),
          ],
        ],
      ),
    );
  }

  TableRow _statRow(IconData icon, Color color, String value) {
    return TableRow(children: [
      Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Center(child: Icon(icon, size: 18, color: color))),
      Padding(
        padding: const EdgeInsets.only(left: 10, top: 6, bottom: 6),
        child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
      ),
    ]);
  }

  TableRow _spacerRow() {
    return TableRow(children: [
      const SizedBox(height: 1),
      Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
    ]);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// LIVE indicator — pulsing dot + text + claimed count
// ──────────────────────────────────────────────────────────────────────────────

class _LiveIndicator extends StatefulWidget {
  final int claimedCount;
  final bool showCount;
  const _LiveIndicator({required this.claimedCount, this.showCount = true});

  @override
  State<_LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<_LiveIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent.withValues(alpha: 0.5 + _pulse.value * 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.redAccent.withValues(alpha: _pulse.value * 0.6),
                    blurRadius: 4 + _pulse.value * 4,
                    spreadRadius: _pulse.value * 2,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          if (widget.showCount && widget.claimedCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '+${widget.claimedCount}',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BottomControls extends StatefulWidget {
  final JourneyState journey;
  final bool isSubmitting;
  final Future<void> Function() onStartJourney;
  final VoidCallback onStopCapture;

  const _BottomControls({
    required this.journey,
    required this.isSubmitting,
    required this.onStartJourney,
    required this.onStopCapture,
  });

  @override
  State<_BottomControls> createState() => _BottomControlsState();
}

class _BottomControlsState extends State<_BottomControls> {
  bool _starting = false;

  Future<void> _handleStart() async {
    if (_starting) return;
    setState(() => _starting = true);
    // Await the full start sequence: it now probes server reachability first
    // (issue #35), which can take up to the reachability timeout when offline.
    // Keep the button disabled until it resolves to prevent double-starts.
    try {
      await widget.onStartJourney();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -2))],
        ),
        child: widget.journey.status == JourneyStatus.tracking
            ? _buildTrackingControls()
            : _buildIdleControls(),
      ),
    );
  }

  Widget _buildIdleControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('🚶 Ready to capture territory?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Walk a loop to claim hexagons!', style: TextStyle(fontSize: 13, color: AppColors.grey)),
        const SizedBox(height: 16),
        BigButton(label: 'START JOURNEY', icon: Icons.play_arrow, onPressed: _starting ? null : _handleStart),
      ],
    );
  }

  Widget _buildTrackingControls() {
    final hasLoop = widget.journey.loopCount > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          hasLoop ? '✅ ${widget.journey.loopCount} loop${widget.journey.loopCount > 1 ? 's' : ''} detected!' : '🔴 Recording your path...',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          hasLoop ? 'Ready to capture! Or keep walking for more loops.' : 'Walk back near your path to close a loop.',
          style: TextStyle(fontSize: 13, color: AppColors.grey),
        ),
        const SizedBox(height: 16),
        BigButton(
          label: widget.isSubmitting ? 'SUBMITTING...' : 'STOP & CAPTURE',
          icon: widget.isSubmitting ? Icons.hourglass_empty : Icons.stop,
          color: hasLoop ? AppColors.primary : Colors.orange,
          onPressed: widget.isSubmitting ? null : widget.onStopCapture,
        ),
      ],
    );
  }
}

/// Cooldown timer chip with a pulsing glow — no box, just floating text with a soft animated aura.
class _CooldownTimerChip extends StatefulWidget {
  final String label;
  const _CooldownTimerChip({required this.label});

  @override
  State<_CooldownTimerChip> createState() => _CooldownTimerChipState();
}

class _CooldownTimerChipState extends State<_CooldownTimerChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _glow = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) {
        return Text(
          widget.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color.lerp(
              const Color(0xFF64B5F6),
              const Color(0xFFE0F7FA),
              _glow.value,
            ),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            shadows: [
              Shadow(
                color: const Color(0xFF64B5F6).withValues(alpha: _glow.value * 0.8),
                blurRadius: 8 + (_glow.value * 6),
              ),
              Shadow(
                color: const Color(0xFF00BCD4).withValues(alpha: _glow.value * 0.4),
                blurRadius: 14 + (_glow.value * 4),
              ),
            ],
          ),
        );
      },
    );
  }
}
