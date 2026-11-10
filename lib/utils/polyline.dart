/// Decodes a Google "encoded polyline" into (lat, lng) pairs. The backend
/// sends routes with precision 6.
List<({double lat, double lng})> decodePolyline(
  String encoded, {
  int precision = 6,
}) {
  final factor = _pow10(precision);
  final out = <({double lat, double lng})>[];
  var index = 0;
  var lat = 0;
  var lng = 0;
  int next() {
    var result = 0;
    var shift = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < encoded.length);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (index < encoded.length) {
    lat += next();
    if (index >= encoded.length) break;
    lng += next();
    out.add((lat: lat / factor, lng: lng / factor));
  }
  return out;
}

double _pow10(int n) {
  var v = 1.0;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}
