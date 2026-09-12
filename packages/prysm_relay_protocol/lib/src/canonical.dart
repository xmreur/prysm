import 'dart:convert';

/// Canonical JSON: keys sorted lexicographically at every depth, no
/// whitespace. Signatures are taken over this form, so two implementations
/// that disagree on map ordering still agree on the bytes they sign.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _write(value, buffer);
  return buffer.toString();
}

void _write(Object? value, StringBuffer out) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    out.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) out.write(',');
      out.write(jsonEncode(keys[i]));
      out.write(':');
      _write(value[keys[i]], out);
    }
    out.write('}');
    return;
  }
  if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _write(value[i], out);
    }
    out.write(']');
    return;
  }
  out.write(jsonEncode(value));
}

/// A copy of [json] without the `sig` key, for building the bytes a signature
/// covers.
Map<String, dynamic> withoutSignature(Map<String, dynamic> json) {
  final copy = Map<String, dynamic>.of(json);
  copy.remove('sig');
  return copy;
}
