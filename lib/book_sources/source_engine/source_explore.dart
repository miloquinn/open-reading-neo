import 'dart:convert';

import '../protocol/book_source_protocol.dart';
import 'source_request_template.dart';

/// A safe, declarative discovery channel extracted from a reading source.
///
/// Some source files also contain script-generated entries and interactive controls.
/// Those stay outside this model until a separately sandboxed runtime exists.
class SourceExploreEntry {
  const SourceExploreEntry({required this.title, required this.url});

  final String title;
  final String url;
}

class SourceExploreCatalog {
  const SourceExploreCatalog({
    required this.entries,
    this.hasUnsupportedEntries = false,
    this.error,
  });

  final List<SourceExploreEntry> entries;
  final bool hasUnsupportedEntries;
  final String? error;

  bool get canBrowse => entries.isNotEmpty && error == null;
}

/// Parses discovery-channel declarations from imported reading sources.
///
/// Supported inputs:
/// - `title::url` entries separated by `&&` or newlines;
/// - JSON arrays whose entries are `type: "url"` (or omit `type`).
///
/// Each returned URL is checked by the bounded request parser before the
/// catalog is advertised to callers.
SourceExploreCatalog parseSourceExploreCatalog(Map<String, dynamic> raw) {
  if (raw['enabledExplore'] == false) {
    return const SourceExploreCatalog(entries: []);
  }
  final exploreUrl = _string(raw['exploreUrl']);
  if (exploreUrl.isEmpty) {
    return const SourceExploreCatalog(entries: []);
  }
  final lowered = exploreUrl.toLowerCase();
  if (lowered.startsWith('@js:') || lowered.startsWith('<js>')) {
    return const SourceExploreCatalog(
      entries: [],
      hasUnsupportedEntries: true,
      error: 'Dynamic discovery scripts are not supported.',
    );
  }

  final parsed = exploreUrl.trimLeft().startsWith('[')
      ? _parseJsonEntries(exploreUrl)
      : _parseLegacyEntries(exploreUrl);
  if (parsed.error != null || parsed.entries.isEmpty) return parsed;

  try {
    final baseUri = Uri.parse(_string(raw['bookSourceUrl']).split('#').first);
    final safeEntries = <SourceExploreEntry>[];
    var hasUnsupportedEntries = parsed.hasUnsupportedEntries;
    for (final entry in parsed.entries) {
      try {
        SourceRequestTemplate.parse(
          entry.url,
          baseUri: baseUri,
          variables: const {'page': '1'},
        );
        safeEntries.add(entry);
      } on BookSourceProtocolException {
        hasUnsupportedEntries = true;
      }
    }
    _ensureExploreRulesPresent(raw);
    return SourceExploreCatalog(
      entries: List.unmodifiable(safeEntries),
      hasUnsupportedEntries: hasUnsupportedEntries,
      error: safeEntries.isEmpty
          ? 'No declarative discovery channels are available.'
          : null,
    );
  } on Object catch (error) {
    return SourceExploreCatalog(
      entries: const [],
      hasUnsupportedEntries: true,
      error: '$error',
    );
  }
}

SourceExploreCatalog _parseJsonEntries(String input) {
  Object? decoded;
  try {
    decoded = jsonDecode(input);
  } on FormatException {
    return const SourceExploreCatalog(
      entries: [],
      error: 'Discovery channels must be valid JSON.',
    );
  }
  if (decoded is! List) {
    return const SourceExploreCatalog(
      entries: [],
      error: 'Discovery channels must be a JSON array.',
    );
  }
  final entries = <SourceExploreEntry>[];
  var hasUnsupportedEntries = false;
  for (final value in decoded) {
    if (value is! Map) {
      hasUnsupportedEntries = true;
      continue;
    }
    final type = _string(value['type']).toLowerCase();
    if (type.isNotEmpty && type != 'url') {
      hasUnsupportedEntries = true;
      continue;
    }
    final title = _string(value['title']);
    final url = _string(value['url']);
    if (title.isEmpty || url.isEmpty) {
      hasUnsupportedEntries = true;
      continue;
    }
    entries.add(SourceExploreEntry(title: title, url: url));
  }
  return SourceExploreCatalog(
    entries: List.unmodifiable(entries),
    hasUnsupportedEntries: hasUnsupportedEntries,
  );
}

SourceExploreCatalog _parseLegacyEntries(String input) {
  final entries = <SourceExploreEntry>[];
  var hasUnsupportedEntries = false;
  for (final item in input.split(RegExp(r'(?:&&|\r?\n)+'))) {
    final value = item.trim();
    if (value.isEmpty) continue;
    final separator = value.indexOf('::');
    if (separator <= 0 || separator >= value.length - 2) {
      hasUnsupportedEntries = true;
      continue;
    }
    final title = value.substring(0, separator).trim();
    final url = value.substring(separator + 2).trim();
    if (title.isEmpty || url.isEmpty) {
      hasUnsupportedEntries = true;
      continue;
    }
    entries.add(SourceExploreEntry(title: title, url: url));
  }
  return SourceExploreCatalog(
    entries: List.unmodifiable(entries),
    hasUnsupportedEntries: hasUnsupportedEntries,
  );
}

void _ensureExploreRulesPresent(Map<String, dynamic> raw) {
  final exploreRules = _ruleMap(raw['ruleExplore']);
  final searchRules = _ruleMap(raw['ruleSearch']);
  final activeRules = _string(exploreRules['bookList']).isEmpty
      ? searchRules
      : exploreRules;
  if (_string(activeRules['bookList']).isEmpty) {
    throw const BookSourceProtocolException(
      'Compatible discovery is missing the bookList rule.',
    );
  }
}

Map<String, dynamic> _ruleMap(Object? value) {
  if (value is Map) {
    return value.map((key, value) => MapEntry('$key', value));
  }
  if (value is String && value.trimLeft().startsWith('{')) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', value));
      }
    } on FormatException {
      return const {};
    }
  }
  return const {};
}

String _string(Object? value) => value is String ? value.trim() : '';
