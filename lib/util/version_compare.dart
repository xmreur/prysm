import 'package:pub_semver/pub_semver.dart';

/// Returns true when [latest] is a newer semver than [current].
///
/// Tags may use a leading `v` (e.g. `v0.5.1-beta`). Pre-releases sort below
/// the corresponding GA release (`0.5.1` > `0.5.1-beta`).
bool isNewerVersion(String current, String latest) {
  final currentVersion = _parseVersionTag(current);
  final latestVersion = _parseVersionTag(latest);
  if (currentVersion == null || latestVersion == null) return false;
  return latestVersion > currentVersion;
}

Version? _parseVersionTag(String tag) {
  final normalized = tag.startsWith('v') ? tag.substring(1) : tag;
  try {
    return Version.parse(normalized);
  } catch (_) {
    return null;
  }
}
