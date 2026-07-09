/// The app's shared basemap tile layers (#160).
///
/// Every FlutterMap in the app builds its base layers from here so the journey
/// map and the debug mock-walk designer can never drift onto different
/// basemaps. Two looks are supported, matching the journey screen's toggle:
/// ArcGIS satellite imagery (plus a place-labels reference layer) and the
/// CartoDB dark street map.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

class AppMapTiles {
  AppMapTiles._();

  static const _userAgentPackageName = 'com.myloop.app';
  static const _satelliteUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  static const _darkUrl = 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
  static const _labelsUrl =
      'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}';

  /// The base layers for a map, in paint order. Spread these first into a
  /// [FlutterMap.children] list.
  static List<Widget> layers({required bool satellite}) => [
        TileLayer(
          urlTemplate: satellite ? _satelliteUrl : _darkUrl,
          subdomains: satellite ? const [] : const ['a', 'b', 'c', 'd'],
          userAgentPackageName: _userAgentPackageName,
          keepBuffer: 4,
          panBuffer: 2,
          maxNativeZoom: 19,
        ),
        if (satellite)
          TileLayer(
            urlTemplate: _labelsUrl,
            userAgentPackageName: _userAgentPackageName,
          ),
      ];
}
