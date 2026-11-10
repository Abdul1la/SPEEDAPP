import 'package:flutter/material.dart';

import '../models/app_settings.dart';

/// Our own map looks. Edit the colors here to customize the map.
/// (Same JSON format as https://mapstyle.withgoogle.com)
///
/// [brightness] is the phone's current appearance, used by "Automatic".
String? mapStyleFor(MapLook look, Brightness brightness) => switch (look) {
  MapLook.auto => brightness == Brightness.dark ? _dark : _light,
  MapLook.dark => _dark,
  MapLook.light => _light,
  MapLook.standard => null,
};

/// App appearance for a map look (light UI on light map, etc.).
ThemeMode themeModeFor(MapLook look) => switch (look) {
  MapLook.light => ThemeMode.light,
  MapLook.dark => ThemeMode.dark,
  MapLook.auto || MapLook.standard => ThemeMode.system,
};

// Clean day map: soft grey land, white roads, warm highways, no shop icons.
const _light = '''
[
  {"elementType":"geometry","stylers":[{"color":"#f3f4f6"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#6b7280"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#ffffff"},{"weight":3}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#374151"}]},
  {"featureType":"landscape.man_made","elementType":"geometry","stylers":[{"color":"#eceef1"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"visibility":"on"},{"color":"#dcefd9"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#e2e5ea"}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#ffe7a8"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#f2c66b"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#4b5563"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#b9daf3"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#5b7a99"}]}
]
''';

// Calm night map: neutral dark grey, readable roads, nothing distracting.
const _dark = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1b1d21"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#8b919b"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#1b1d21"},{"weight":3}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#c9cdd3"}]},
  {"featureType":"landscape.man_made","elementType":"geometry","stylers":[{"color":"#202227"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"visibility":"on"},{"color":"#1d2a22"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2b2e34"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#1b1d21"}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#33373e"}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#454a53"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#2b2e34"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#d1d5db"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0f1720"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#4b5563"}]}
]
''';
