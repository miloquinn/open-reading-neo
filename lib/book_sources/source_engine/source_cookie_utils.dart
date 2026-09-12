import 'dart:io';

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

/// Parses a response cookie while tolerating non-standard `Expires` values.
///
/// Some reading sites emit dates that `dart:io` correctly rejects (for
/// example an `UTC` suffix or a weekday that does not match the calendar
/// date). Preserve a valid calendar value by parsing its fields independently
/// instead of failing the whole source request.
Cookie parseSourceSetCookie(String value) {
  try {
    return Cookie.fromSetCookieValue(value);
  } on HttpException catch (error) {
    final expiresMatch = RegExp(
      r';\s*expires\s*=\s*([^;]*)',
      caseSensitive: false,
    ).firstMatch(value);
    if (expiresMatch == null) rethrow;
    final expires = _parseCompatibleCookieDate(expiresMatch.group(1)!.trim());
    if (expires == null) throw error;
    final cookie = Cookie.fromSetCookieValue(
      value.replaceRange(expiresMatch.start, expiresMatch.end, ''),
    );
    cookie.expires = expires;
    return cookie;
  }
}

DateTime? _parseCompatibleCookieDate(String value) {
  final match = RegExp(
    r'^(?:[a-z]{3},\s*)?(\d{1,2})\s+([a-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+(?:gmt|utc)$',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  const months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  final day = int.parse(match.group(1)!);
  final month = months[match.group(2)!.toLowerCase()];
  final year = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  if (month == null || hour > 23 || minute > 59 || second > 59) return null;
  final date = DateTime.utc(year, month, day, hour, minute, second);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}
