import 'package:pub_semver/pub_semver.dart';

/// Returns true when [latest] is a newer release than [current].
///
/// Tags may use a leading `v` (e.g. `v0.5.1-beta`). Standard pre-releases sort
/// below the corresponding GA release (`0.5.1` > `0.5.1-beta`). Hotfix-style
/// suffixes (`0.6.1-fix`) sort above the GA they patch (`0.6.1-fix` > `0.6.1`).
bool isNewerVersion(String current, String latest) {
  final currentTag = _parseReleaseTag(current);
  final latestTag = _parseReleaseTag(latest);
  if (currentTag == null || latestTag == null) return false;
  return _compareReleaseTags(currentTag, latestTag) < 0;
}

class _ParsedReleaseTag {
  const _ParsedReleaseTag({
    required this.core,
    required this.suffix,
    required this.suffixKind,
  });

  final Version core;
  final String? suffix;
  final _SuffixKind suffixKind;
}

enum _SuffixKind { none, prerelease, hotfix }

_SuffixKind _suffixKind(String? suffix) {
  if (suffix == null) return _SuffixKind.none;
  if (_isHotfixSuffix(suffix)) return _SuffixKind.hotfix;
  return _SuffixKind.prerelease;
}

bool _isHotfixSuffix(String suffix) {
  final lower = suffix.toLowerCase();
  if (lower == 'fix' || lower == 'hotfix' || lower == 'patch') return true;
  if (RegExp(r'^fix[.\w\d-]*$').hasMatch(lower)) return true;
  if (RegExp(r'^r\d+$').hasMatch(lower)) return true;
  if (RegExp(r'^\d+$').hasMatch(lower)) return true;
  return false;
}

_ParsedReleaseTag? _parseReleaseTag(String tag) {
  final normalized = tag.startsWith('v') ? tag.substring(1) : tag;
  final match =
      RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$').firstMatch(normalized);
  if (match != null) {
    final suffix = match.group(4);
    return _ParsedReleaseTag(
      core: Version(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      ),
      suffix: suffix,
      suffixKind: _suffixKind(suffix),
    );
  }

  try {
    final version = Version.parse(normalized);
    return _ParsedReleaseTag(
      core: Version(version.major, version.minor, version.patch),
      suffix: version.isPreRelease ? version.preRelease.join('.') : null,
      suffixKind: version.isPreRelease
          ? _suffixKind(version.preRelease.join('.'))
          : _SuffixKind.none,
    );
  } catch (_) {
    return null;
  }
}

int _compareReleaseTags(_ParsedReleaseTag current, _ParsedReleaseTag latest) {
  final coreCmp = current.core.compareTo(latest.core);
  if (coreCmp != 0) return coreCmp;

  final currentSuffix = current.suffix;
  final latestSuffix = latest.suffix;
  if (currentSuffix == null && latestSuffix == null) return 0;
  if (currentSuffix == null && latestSuffix != null) {
    return switch (latest.suffixKind) {
      _SuffixKind.hotfix => -1,
      _SuffixKind.prerelease => 1,
      _SuffixKind.none => 0,
    };
  }
  if (currentSuffix != null && latestSuffix == null) {
    return switch (current.suffixKind) {
      _SuffixKind.hotfix => 1,
      _SuffixKind.prerelease => -1,
      _SuffixKind.none => 0,
    };
  }

  if (current.suffixKind == latest.suffixKind) {
    return _compareSuffixLabels(currentSuffix!, latestSuffix!);
  }

  return current.suffixKind.index.compareTo(latest.suffixKind.index);
}

int _compareSuffixLabels(String current, String latest) {
  try {
    final currentVersion = Version.parse('0.0.0-$current');
    final latestVersion = Version.parse('0.0.0-$latest');
    return currentVersion.compareTo(latestVersion);
  } catch (_) {
    return current.toLowerCase().compareTo(latest.toLowerCase());
  }
}
