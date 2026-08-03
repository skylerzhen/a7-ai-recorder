/// Tiny hex → bytes helper for tests (ignores whitespace). Test-only.
List<int> hx(String s) {
  final clean = s.replaceAll(RegExp(r'\s+'), '');
  return [
    for (int i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ];
}
