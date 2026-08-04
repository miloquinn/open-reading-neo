Map<String, String> parseSourceCookieHeader(String? header) {
  if (header == null || header.trim().isEmpty) return const {};
  final values = <String, String>{};
  for (final part in header.split(';')) {
    final separator = part.indexOf('=');
    if (separator <= 0) continue;
    final name = part.substring(0, separator).trim();
    if (name.isEmpty) continue;
    values[name] = part.substring(separator + 1).trim();
  }
  return values;
}
