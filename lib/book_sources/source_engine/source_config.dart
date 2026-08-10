import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';
import 'source_explore.dart';

enum SourceCompatibilityLevel { supported, partial, unsupported }

enum SourceCompatibilityIssue {
  audio,
  video,
  image,
  file,
  javascript,
  webView,
  login,
  cookies,
  customDns,
  customProxy,
  missingSearch,
  missingReadingRules,
  xpath,
  complexJsonPath,
}

class ReadingSourceConfig {
  const ReadingSourceConfig._(this.raw);

  factory ReadingSourceConfig.fromJson(Map<String, dynamic> json) {
    final raw = Map<String, dynamic>.unmodifiable(json);
    if (_string(raw['bookSourceUrl']).isEmpty ||
        _string(raw['bookSourceName']).isEmpty) {
      throw const FormatException(
        'Reading source requires bookSourceUrl and bookSourceName.',
      );
    }
    if (_sourceBaseUri(raw) == null) {
      throw const FormatException(
        'Reading source must expose an absolute HTTP(S) request target.',
      );
    }
    return ReadingSourceConfig._(raw);
  }

  final Map<String, dynamic> raw;

  String get url => _string(raw['bookSourceUrl']);
  String get name => _string(raw['bookSourceName']);
  String get group => _string(raw['bookSourceGroup']);
  String get comment => _string(raw['bookSourceComment']);
  String get jsLib => _string(raw['jsLib']);
  int get type => _integer(raw['bookSourceType']);
  String get searchUrl => _string(raw['searchUrl']);
  String get exploreUrl => _string(raw['exploreUrl']);
  String get loginCheckJs => _string(raw['loginCheckJs']);
  bool get enabledExplore => raw['enabledExplore'] != false;
  bool get enabled => raw['enabled'] != false;
  bool get enabledCookieJar => raw['enabledCookieJar'] == true;
  int get lastUpdateTime => _integer(raw['lastUpdateTime']);
  int get respondTime => _integer(raw['respondTime']);
  String get concurrentRate => _string(raw['concurrentRate']);

  Uri get baseUri => _sourceBaseUri(raw)!;

  SourceExploreCatalog get exploreCatalog => parseSourceExploreCatalog(raw);

  String get stableId =>
      'source.${sha256.convert(utf8.encode(url)).toString().substring(0, 24)}';

  Map<String, dynamic> rule(String name) {
    final value = raw[name];
    if (value is Map) {
      return value.map((key, value) => MapEntry('$key', value));
    }
    if (value is String && value.trim().startsWith('{')) {
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

  bool get hasMalformedRuleJson {
    for (final name in const [
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
    ]) {
      final value = raw[name];
      if (value is! String || !value.trim().startsWith('{')) continue;
      try {
        if (jsonDecode(value) is! Map) return true;
      } on FormatException {
        return true;
      }
    }
    return false;
  }

  RegisteredBookSource toRegisteredSource({
    String? id,
    bool? enabled,
    bool readingChainVerified = false,
    SourceCompatibilityReport? compatibilityReport,
    DateTime? addedAt,
  }) {
    final report =
        compatibilityReport ?? const SourceCompatibilityScanner().scan(this);
    final shouldEnable = enabled ?? this.enabled;
    final capabilities = <String>{
      if (searchUrl.isNotEmpty && rule('ruleSearch').isNotEmpty) 'search',
      if (rule('ruleBookInfo').isNotEmpty) 'detail',
      if (rule('ruleToc').isNotEmpty) 'catalog',
      if (rule('ruleContent').isNotEmpty) 'content',
      if (exploreUrl.isNotEmpty || exploreCatalog.canBrowse) ...{
        'categories',
        'browse',
      },
    };
    return RegisteredBookSource(
      id: id ?? stableId,
      name: name,
      description: comment,
      manifestUrl: baseUri,
      apiBaseUrl: baseUri,
      websiteUrl: baseUri,
      protocolVersion: 'reading-source-1',
      languages: const [],
      // Import is deliberately optimistic: available rule groups decide which
      // actions may be attempted. Unsupported syntax is reported only when the
      // user invokes that action, so one advanced rule does not disable an
      // otherwise usable source at import time.
      capabilities: capabilities,
      enabled: shouldEnable && capabilities.isNotEmpty,
      addedAt: addedAt ?? DateTime.now(),
      sourceProtocol: BookSourceProtocolKind.readingSource,
      sourceConfig: {
        ...raw,
        '_openReadingCompatibilityLevel': report.level.name,
        '_openReadingCompatibilityIssues':
            report.issues.map((issue) => issue.name).toList()..sort(),
        if (readingChainVerified)
          '_openReadingReadingChainVerifiedAt':
              raw['_openReadingReadingChainVerifiedAt'] is String
              ? raw['_openReadingReadingChainVerifiedAt']
              : DateTime.now().toUtc().toIso8601String(),
      },
    );
  }
}

bool isReadingChainVerifiedSource(RegisteredBookSource source) {
  return source.sourceProtocol == BookSourceProtocolKind.readingSource &&
      source.sourceConfig?['_openReadingReadingChainVerifiedAt'] is String;
}

class SourceCompatibilityReport {
  const SourceCompatibilityReport({required this.level, required this.issues});

  final SourceCompatibilityLevel level;
  final Set<SourceCompatibilityIssue> issues;

  bool get canRun => level != SourceCompatibilityLevel.unsupported;
}

class SourceCompatibilityScanner {
  const SourceCompatibilityScanner();

  SourceCompatibilityReport scan(ReadingSourceConfig source) {
    final issues = <SourceCompatibilityIssue>{};
    final typeIssue = switch (source.type) {
      1 => SourceCompatibilityIssue.audio,
      2 => SourceCompatibilityIssue.image,
      3 => SourceCompatibilityIssue.file,
      4 => SourceCompatibilityIssue.video,
      _ => null,
    };
    if (typeIssue != null) issues.add(typeIssue);
    if (source.searchUrl.isEmpty) {
      issues.add(SourceCompatibilityIssue.missingSearch);
    }
    if (source.hasMalformedRuleJson) {
      issues.add(SourceCompatibilityIssue.missingReadingRules);
    }
    if (source.rule('ruleToc').isEmpty || source.rule('ruleContent').isEmpty) {
      issues.add(SourceCompatibilityIssue.missingReadingRules);
    }
    final coreConfiguration = Map<String, dynamic>.from(source.raw)
      ..remove('enabledExplore')
      ..remove('exploreUrl')
      ..remove('exploreScreen')
      ..remove('ruleExplore')
      // Login support is optional. Its mere presence must not make
      // otherwise public search and reading rules unusable.
      ..remove('loginUrl')
      ..remove('loginUi')
      ..remove('loginCheckJs');
    _walk(coreConfiguration, (key, value) {
      if (value is! String || value.trim().isEmpty) return;
      final field = key.toLowerCase();
      final text = value.toLowerCase();
      if (field == 'loginurl' ||
          field == 'loginui' ||
          field == 'logincheckjs') {
        issues.add(SourceCompatibilityIssue.login);
      }
      if (field.contains('webview') ||
          field == 'webjs' ||
          text.contains('webview') ||
          text.contains('webjs')) {
        issues.add(SourceCompatibilityIssue.webView);
      }
      if (text.contains('"dnsip"')) {
        issues.add(SourceCompatibilityIssue.customDns);
      }
      if (text.contains('"proxy"')) {
        issues.add(SourceCompatibilityIssue.customProxy);
      }
    });

    const blocked = {
      SourceCompatibilityIssue.audio,
      SourceCompatibilityIssue.video,
      SourceCompatibilityIssue.file,
      SourceCompatibilityIssue.missingSearch,
      SourceCompatibilityIssue.missingReadingRules,
    };
    final hasBlockedIssue = issues.any(blocked.contains);
    final level = hasBlockedIssue
        ? SourceCompatibilityLevel.unsupported
        : issues.isEmpty
        ? SourceCompatibilityLevel.supported
        : SourceCompatibilityLevel.partial;
    return SourceCompatibilityReport(
      level: level,
      issues: Set.unmodifiable(issues),
    );
  }
}

class SourceImportResult {
  const SourceImportResult({
    required this.sources,
    required this.sourceUrls,
    required this.errors,
    required this.duplicates,
  });

  final List<ReadingSourceConfig> sources;
  final List<Uri> sourceUrls;
  final List<String> errors;
  final int duplicates;
}

SourceImportResult parseReadingSources(
  String input, {
  int maxSources = 10000,
  int maxNestedUrls = 50,
}) {
  final text = input.replaceFirst('\ufeff', '').trim();
  if (text.isEmpty) throw const FormatException('Source JSON is empty.');
  return parseReadingSourcePayload(
    jsonDecode(text),
    maxSources: maxSources,
    maxNestedUrls: maxNestedUrls,
  );
}

SourceImportResult parseReadingSourcePayload(
  Object? decoded, {
  int maxSources = 10000,
  int maxNestedUrls = 50,
}) {
  final sourceUrls = <Uri>[];
  final candidates = <Object?>[];
  if (decoded is List) {
    candidates.addAll(decoded);
  } else if (decoded is Map) {
    final nested = decoded['sourceUrls'];
    if (nested is List) {
      if (nested.length > maxNestedUrls) {
        throw FormatException(
          'Too many nested source URLs (max $maxNestedUrls).',
        );
      }
      for (final value in nested) {
        final uri = Uri.tryParse('$value');
        if (uri == null ||
            !uri.hasAuthority ||
            (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw const FormatException('Nested source URL must use HTTP(S).');
        }
        sourceUrls.add(uri);
      }
    } else if (decoded.containsKey('bookSourceUrl')) {
      candidates.add(decoded);
    } else {
      for (final key in const ['bookSourceList', 'sources', 'data']) {
        final value = decoded[key];
        if (value is List) {
          candidates.addAll(value);
          break;
        }
      }
    }
  } else {
    throw const FormatException('Expected a source object or array.');
  }
  if (candidates.length > maxSources) {
    throw FormatException('Too many sources (max $maxSources).');
  }
  final byUrl = <String, ReadingSourceConfig>{};
  final errors = <String>[];
  var duplicates = 0;
  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    if (candidate is! Map) {
      errors.add('Item ${index + 1} is not an object.');
      continue;
    }
    try {
      final source = ReadingSourceConfig.fromJson(
        candidate.map((key, value) => MapEntry('$key', value)),
      );
      if (byUrl.containsKey(source.url)) duplicates++;
      byUrl[source.url] = source;
    } on FormatException catch (error) {
      errors.add('Item ${index + 1}: ${error.message}');
    }
  }
  return SourceImportResult(
    sources: List.unmodifiable(byUrl.values),
    sourceUrls: List.unmodifiable(sourceUrls),
    errors: List.unmodifiable(errors),
    duplicates: duplicates,
  );
}

void _walk(Object? value, void Function(String key, Object? value) visitor) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = '${entry.key}';
      visitor(key, entry.value);
      _walk(entry.value, visitor);
    }
  } else if (value is List) {
    for (final item in value) {
      _walk(item, visitor);
    }
  }
}

String _string(Object? value) => value is String ? value.trim() : '';

int _integer(Object? value) => switch (value) {
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

Uri? _sourceBaseUri(Map<String, dynamic> raw) {
  final declared = Uri.tryParse(_string(raw['bookSourceUrl']).split('#').first);
  if (declared != null &&
      declared.hasAuthority &&
      (declared.scheme == 'http' || declared.scheme == 'https')) {
    return declared;
  }
  final serialized = <String>[
    for (final key in const [
      'searchUrl',
      'exploreUrl',
      'jsLib',
      'header',
      'loginUrl',
      'loginUi',
      'loginCheckJs',
      'ruleSearch',
      'ruleExplore',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
    ])
      if (raw[key] != null) '${raw[key]}',
  ].join('\n');
  final match = RegExp(r'''https?://[^\s"'<>`\\]+''').firstMatch(serialized);
  if (match == null) return null;
  final candidate = Uri.tryParse(match.group(0)!);
  if (candidate == null || !candidate.hasAuthority) return null;
  return Uri(
    scheme: candidate.scheme,
    host: candidate.host,
    port: candidate.hasPort ? candidate.port : null,
  );
}
