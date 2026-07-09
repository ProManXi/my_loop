/// MyLoop — Mock Walk Simulation: route designer (#29, redesigned in #160)
///
/// Debug-only screen letting a tester design and launch a simulated walk from
/// their desk: pick a route shape, tap a start point / waypoints on the shared
/// app basemap, tune speed / radius / bearing, save and reload named routes,
/// then start. Styled with the app design system ([AppColors] / theme text) so
/// it reads as part of the product, not a foreign tool.
///
/// Opening the screen resolves the start point gracefully, never with a prompt
/// or a crash: last-used route location first, then a silent real-GPS fix if
/// permission is already granted, else the config default. The explicit
/// "Use my location" button runs the full (real) permission flow and surfaces
/// failures as a snackbar.
///
/// Reachable only via the debug-only route `/dev/mock-walk` (registered under
/// `kDebugMode`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import 'package:myloop/app/theme.dart';
import 'package:myloop/features/journey/loop_detector.dart';
import 'package:myloop/shared/constants/app_constants.dart';
import 'package:myloop/shared/services/location_service.dart';
import 'package:myloop/shared/services/mock/mock_route_store.dart';
import 'package:myloop/shared/services/mock/mock_walk_config.dart';
import 'package:myloop/shared/services/mock/mock_walk_engine.dart';
import 'package:myloop/shared/widgets/app_map_tiles.dart';

/// User-facing copy + presentation values for the designer, kept out of the
/// widget tree (CLAUDE.md: "No hardcoded strings — use constants").
class _Strings {
  _Strings._();
  static const title = 'Mock Walk';
  static const debugBadge = 'DEBUG';
  static const quickLaunch = 'Quick launch';
  static const quickLaunchHint = 'One tap — starts at the map centre.';
  static const start = 'Start mock walk';
  static const routeShape = 'Route';
  static const routeLoop = 'Loop';
  static const routeStraight = 'Straight';
  static const routeWaypoints = 'Waypoints';
  static const jitterTitle = 'GPS jitter';
  static const jitterSubtitle = 'Required to pass server anti-cheat.';
  static const jitterWarning =
      'With jitter off, straight/loop routes are rejected by the server '
      'smoothness check (bearing std-dev < 2°).';
  static const autoCloseTitle = 'Auto-close loop';
  static const autoCloseSubtitle = 'Walk back to the first waypoint at the end.';
  static const openPathWarning =
      'Path does not close — the walk will step-claim hexes but never '
      'capture a territory loop.';
  static const needTwoWaypoints = 'Tap the map to add at least 2 waypoints.';
  static const undoWaypoint = 'Undo';
  static const clearWaypoints = 'Clear';
  static const useMyLocation = 'Use my location';
  static const locationFailed = 'Could not get your location — tap the map to set a start point.';
  static const savedRoutes = 'Saved routes';
  static const noSavedRoutes = 'No saved routes yet. Design one and save it for reuse.';
  static const saveRoute = 'Save route';
  static const saveDialogTitle = 'Save route as…';
  static const saveDialogHint = 'e.g. Office block loop';
  static const saveDialogCancel = 'Cancel';
  static const saveDialogSave = 'Save';
  static const deleteRouteTooltip = 'Delete route';
  static String tapHintWaypoints(int count) =>
      'Tap the map to add waypoints in order — $count set.';
  static const tapHintStart = 'Tap the map to move the start point.';
  static String speed(double v) => 'Speed ${v.toStringAsFixed(1)} m/s';
  static String loopRadius(double v) => 'Loop radius ${v.toStringAsFixed(0)} m';
  static String length(double v) => 'Length ${v.toStringAsFixed(0)} m';
  static String bearing(double v) => 'Bearing ${v.toStringAsFixed(0)}°';
  static String routeStats(double meters, Duration eta) =>
      '${meters.toStringAsFixed(0)} m · ~${eta.inMinutes}m ${eta.inSeconds % 60}s at this speed';
  static String tooShort(double neededMeters) =>
      'Too short to claim — add roughly ${neededMeters.toStringAsFixed(0)} m of route.';
  static String savedAgo(DateTime at) {
    final d = DateTime.now().difference(at);
    // A future savedAt (clock skew, hand-edited store file — the codec
    // deliberately tolerates it) must not render "-4m ago".
    if (d.isNegative) return 'just now';
    if (d.inDays > 0) return '${d.inDays}d ago';
    if (d.inHours > 0) return '${d.inHours}h ago';
    return '${d.inMinutes}m ago';
  }
}

class MockWalkScreen extends ConsumerStatefulWidget {
  const MockWalkScreen({super.key});

  @override
  ConsumerState<MockWalkScreen> createState() => _MockWalkScreenState();
}

class _MockWalkScreenState extends ConsumerState<MockWalkScreen> {
  final MapController _mapController = MapController();

  /// Set once the tester interacts (tap / load / locate), so the async on-open
  /// start-point resolution can never clobber an explicit choice.
  bool _userChoseStart = false;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    // Post-frame so ref/context are safe and the map controller is attached.
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveInitialStart());
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(mockWalkConfigProvider);
    final anchors = _previewAnchors(config);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text(_Strings.title),
            const SizedBox(width: 8),
            _Badge(label: _Strings.debugBadge, color: AppColors.orange),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(flex: 5, child: _buildMap(config, anchors)),
          Expanded(flex: 6, child: _buildPanel(config)),
        ],
      ),
    );
  }

  // ── Map ─────────────────────────────────────────────────────────────────────

  Widget _buildMap(MockWalkConfig config, List<LatLng> anchors) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: config.startPoint,
        initialZoom: 16,
        onTap: (_, latLng) => _onMapTap(config, latLng),
      ),
      children: [
        ...AppMapTiles.layers(satellite: true),
        if (anchors.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(points: anchors, strokeWidth: 3, color: AppColors.primary),
            ],
          ),
        MarkerLayer(markers: _markers(config)),
      ],
    );
  }

  List<Marker> _markers(MockWalkConfig config) {
    return [
      Marker(
        point: config.startPoint,
        width: 28,
        height: 28,
        child: const Icon(Icons.my_location, color: AppColors.primary, size: 28),
      ),
      for (var i = 0; i < config.waypoints.length; i++)
        Marker(
          point: config.waypoints[i],
          width: 24,
          height: 24,
          child: _WaypointDot(index: i + 1),
        ),
    ];
  }

  void _onMapTap(MockWalkConfig config, LatLng latLng) {
    _userChoseStart = true;
    if (config.routeType == MockRouteType.multiWaypoint) {
      _set(config.copyWith(waypoints: [...config.waypoints, latLng]));
    } else {
      _set(config.copyWith(startPoint: latLng));
    }
  }

  // ── Panel ───────────────────────────────────────────────────────────────────

  Widget _buildPanel(MockWalkConfig config) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _quickLaunchSection(),
        const SizedBox(height: 12),
        _routeSection(config),
        const SizedBox(height: 12),
        _savedRoutesSection(config),
        const SizedBox(height: 16),
        _startButton(config),
      ],
    );
  }

  Widget _quickLaunchSection() {
    return _Section(
      title: _Strings.quickLaunch,
      subtitle: _Strings.quickLaunchHint,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final scenario in MockWalkScenarios.all)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.bolt, size: 18),
              label: Text(scenario.label),
              onPressed: () => _launchScenario(scenario),
            ),
        ],
      ),
    );
  }

  Widget _routeSection(MockWalkConfig config) {
    return _Section(
      title: _Strings.routeShape,
      subtitle: _tapHint(config),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<MockRouteType>(
            segments: const [
              ButtonSegment(value: MockRouteType.loop, label: Text(_Strings.routeLoop)),
              ButtonSegment(value: MockRouteType.straight, label: Text(_Strings.routeStraight)),
              ButtonSegment(value: MockRouteType.multiWaypoint, label: Text(_Strings.routeWaypoints)),
            ],
            selected: {config.routeType},
            onSelectionChanged: (s) => _set(config.copyWith(routeType: s.first)),
          ),
          const SizedBox(height: 8),
          _shapeControls(config),
          _slider(
            label: _Strings.speed(config.speedMps),
            value: config.speedMps,
            min: MockWalkConstants.minSpeedMps,
            max: MockWalkConstants.maxSpeedMps,
            onChanged: (v) => _set(config.copyWith(speedMps: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(_Strings.jitterTitle),
            subtitle: const Text(_Strings.jitterSubtitle),
            value: config.jitterEnabled,
            onChanged: (v) => _set(config.copyWith(jitterEnabled: v)),
          ),
          if (!config.jitterEnabled) const _WarningText(_Strings.jitterWarning),
          _routeStats(config),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: _locating
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.gps_fixed, size: 18),
              label: const Text(_Strings.useMyLocation),
              onPressed: _locating ? null : _useMyLocation,
            ),
          ),
        ],
      ),
    );
  }

  Widget _shapeControls(MockWalkConfig config) {
    switch (config.routeType) {
      case MockRouteType.loop:
        return _slider(
          label: _Strings.loopRadius(config.loopRadiusMeters),
          value: config.loopRadiusMeters,
          min: MockWalkConstants.minLoopRadiusMeters,
          max: MockWalkConstants.maxLoopRadiusMeters,
          onChanged: (v) => _set(config.copyWith(loopRadiusMeters: v)),
        );
      case MockRouteType.straight:
        return Column(
          children: [
            _slider(
              label: _Strings.length(config.straightLengthMeters),
              value: config.straightLengthMeters,
              min: MockWalkConstants.minStraightLengthMeters,
              max: MockWalkConstants.maxStraightLengthMeters,
              onChanged: (v) => _set(config.copyWith(straightLengthMeters: v)),
            ),
            _slider(
              label: _Strings.bearing(config.straightBearingDegrees),
              value: config.straightBearingDegrees.clamp(0.0, 360.0),
              min: 0,
              max: 360,
              onChanged: (v) => _set(config.copyWith(straightBearingDegrees: v)),
            ),
          ],
        );
      case MockRouteType.multiWaypoint:
        return _waypointControls(config);
    }
  }

  Widget _waypointControls(MockWalkConfig config) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.undo, size: 18),
              label: const Text(_Strings.undoWaypoint),
              onPressed: config.waypoints.isEmpty
                  ? null
                  : () => _set(config.copyWith(
                      waypoints: config.waypoints.sublist(0, config.waypoints.length - 1))),
            ),
            TextButton.icon(
              icon: const Icon(Icons.layers_clear, size: 18),
              label: const Text(_Strings.clearWaypoints),
              onPressed: config.waypoints.isEmpty
                  ? null
                  : () => _set(config.copyWith(waypoints: const [])),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(_Strings.autoCloseTitle),
          subtitle: const Text(_Strings.autoCloseSubtitle),
          value: config.autoCloseLoop,
          onChanged: (v) => _set(config.copyWith(autoCloseLoop: v)),
        ),
        if (!config.autoCloseLoop && config.waypoints.length >= 2)
          const _WarningText(_Strings.openPathWarning),
      ],
    );
  }

  /// Live length/ETA readout plus a claimability warning, computed from the
  /// same engine geometry the walk will use (no jitter, pure anchors).
  Widget _routeStats(MockWalkConfig config) {
    final engine = MockWalkEngine(config.copyWith(jitterEnabled: false));
    final total = engine.totalLengthMeters;
    final eta = config.speedMps > 0
        ? Duration(seconds: (total / config.speedMps).ceil())
        : Duration.zero;

    // Mirror the journey's retained-point estimate: ~one kept fix per noise
    // floor. Loops (incl. auto-closed waypoint routes) need minLoopPoints;
    // anything else needs the per-claim floor.
    final noiseFloor = MockWalkConstants.reportedAccuracyMeters
        .clamp(AppConstants.movingNoiseFloorMin, AppConstants.movingNoiseFloorMax);
    final closes = config.routeType == MockRouteType.loop ||
        (config.routeType == MockRouteType.multiWaypoint && config.autoCloseLoop);
    final floor = closes ? LoopDetector.minLoopPoints : AppConstants.minGpsPointsPerClaim;
    final retainedEstimate = total / noiseFloor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_Strings.routeStats(total, eta), style: Theme.of(context).textTheme.bodyMedium),
        if (retainedEstimate < floor)
          _WarningText(_Strings.tooShort(floor * noiseFloor - total)),
      ],
    );
  }

  Widget _savedRoutesSection(MockWalkConfig config) {
    final library = ref.watch(mockRouteLibraryProvider);
    final routes = library.value?.routes ?? const <SavedMockRoute>[];

    return _Section(
      title: _Strings.savedRoutes,
      trailing: TextButton.icon(
        icon: const Icon(Icons.bookmark_add_outlined, size: 18),
        label: const Text(_Strings.saveRoute),
        onPressed: () => _promptSaveRoute(config),
      ),
      child: routes.isEmpty
          ? Text(_Strings.noSavedRoutes, style: Theme.of(context).textTheme.bodyMedium)
          : Column(
              children: [for (final route in routes) _savedRouteTile(route)],
            ),
    );
  }

  Widget _savedRouteTile(SavedMockRoute route) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.route, color: AppColors.primary),
      title: Text(route.name),
      subtitle: Text(_Strings.savedAgo(route.savedAt)),
      trailing: IconButton(
        tooltip: _Strings.deleteRouteTooltip,
        icon: const Icon(Icons.delete_outline, color: AppColors.grey),
        onPressed: () => ref.read(mockRouteLibraryProvider.notifier).deleteRoute(route.name),
      ),
      onTap: () => _loadSavedRoute(route),
    );
  }

  Widget _startButton(MockWalkConfig config) {
    final needsWaypoints =
        config.routeType == MockRouteType.multiWaypoint && config.waypoints.length < 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (needsWaypoints)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: _WarningText(_Strings.needTwoWaypoints),
          ),
        FilledButton.icon(
          icon: const Icon(Icons.directions_walk),
          label: const Text(_Strings.start),
          onPressed: needsWaypoints ? null : () => _startWalk(config),
        ),
      ],
    );
  }

  String _tapHint(MockWalkConfig config) {
    return config.routeType == MockRouteType.multiWaypoint
        ? _Strings.tapHintWaypoints(config.waypoints.length)
        : _Strings.tapHintStart;
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
      ],
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _set(MockWalkConfig config) => ref.read(mockWalkConfigProvider.notifier).update(config);

  /// Start-point resolution on open, mildest first and never prompting:
  /// last-used saved location, then a silent real fix if permission is already
  /// granted. Any failure just leaves the previous fallback in place.
  Future<void> _resolveInitialStart() async {
    try {
      final library = await ref.read(mockRouteLibraryProvider.future);
      final lastUsed = library.lastUsed;
      if (lastUsed != null) _moveStart(lastUsed.startPoint);
    } catch (_) {
      // Store unavailable — keep the config default.
    }
    try {
      final permission = await Geolocator.checkPermission();
      final granted = permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
      if (!granted) return;
      final pos = await LocationService().getCurrentPosition();
      _moveStart(LatLng(pos.latitude, pos.longitude));
    } catch (_) {
      // No fix (timeout / services off) — the fallback start point stands.
    }
  }

  /// Explicit request — runs the REAL permission flow (the injectable mock
  /// auto-grants, which is exactly what this button must not do).
  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      final service = LocationService();
      await service.requestPermission();
      final pos = await service.getCurrentPosition();
      _userChoseStart = true;
      _moveStart(LatLng(pos.latitude, pos.longitude), force: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(_Strings.locationFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _moveStart(LatLng point, {bool force = false}) {
    if (!mounted || (_userChoseStart && !force)) return;
    // ref.read, not watch — this runs from async chains, not build.
    _set(ref.read(mockWalkConfigProvider).copyWith(startPoint: point));
    _mapController.move(point, 16);
  }

  Future<void> _promptSaveRoute(MockWalkConfig config) async {
    final controller = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(_Strings.saveDialogTitle),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: _Strings.saveDialogHint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(_Strings.saveDialogCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text(_Strings.saveDialogSave),
            ),
          ],
        ),
      );
      if (name != null && name.trim().isNotEmpty && mounted) {
        await ref.read(mockRouteLibraryProvider.notifier).saveRoute(name, config);
      }
    } finally {
      controller.dispose();
    }
  }

  void _loadSavedRoute(SavedMockRoute route) {
    _userChoseStart = true;
    // Saved configs are persisted with `enabled` forced off; keep it off until START.
    _set(route.config);
    _mapController.move(route.config.startPoint, 16);
  }

  /// One-tap path: take a curated scenario, anchor it at the map's current
  /// centre, enable the mock, and go straight to the journey. The scenario's
  /// config is already anti-cheat-valid; only the start point is overridden.
  void _launchScenario(MockWalkScenario scenario) {
    _launch(scenario.config.copyWith(startPoint: _mapController.camera.center));
  }

  void _startWalk(MockWalkConfig config) => _launch(config);

  void _launch(MockWalkConfig config) {
    final live = config.copyWith(enabled: true);
    ref.read(mockWalkConfigProvider.notifier).update(live);
    // Remember for next open; durability is best-effort by design.
    unawaited(ref.read(mockRouteLibraryProvider.notifier).setLastUsed(live));
    context.go('/journey');
  }

  /// Route geometry preview (no jitter) so the tester sees the shape they'll walk.
  List<LatLng> _previewAnchors(MockWalkConfig config) {
    return MockWalkEngine(config.copyWith(jitterEnabled: false)).buildRouteAnchors();
  }
}

// ── Small presentation widgets ────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  const _Section({required this.title, required this.child, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
                if (trailing != null) trailing!,
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.grey)),
              ),
            const SizedBox(height: 4),
            child,
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
      child: Text(label,
          style: const TextStyle(color: AppColors.white, fontWeight: FontWeight.bold, fontSize: 11)),
    );
  }
}

class _WaypointDot extends StatelessWidget {
  final int index;
  const _WaypointDot({required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
      child: Text('$index',
          style: const TextStyle(color: AppColors.white, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}

class _WarningText extends StatelessWidget {
  final String text;
  const _WarningText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: const TextStyle(color: AppColors.orange, fontSize: 12)),
    );
  }
}
