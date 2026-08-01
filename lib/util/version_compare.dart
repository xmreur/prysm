bool isNewerVersion(String current, String latest) {
  List<int> toNums(String v) =>
      v
          .replaceFirst('v', '')
          .split('.')
          .map((s) => int.parse(s.replaceAll(RegExp(r'\D.*'), '')))
          .toList();

  final currNums = toNums(current);
  final latestNums = toNums(latest);
  for (int i = 0; i < currNums.length && i < latestNums.length; i++) {
    if (latestNums[i] > currNums[i]) return true;
    if (latestNums[i] < currNums[i]) return false;
  }
  return latestNums.length > currNums.length;
}
