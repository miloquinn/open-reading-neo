import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';
import 'legado_explore.dart';

enum LegadoCompatibilityLevel { supported, partial, unsupported }

enum LegadoCompatibilityIssue {
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

class LegadoBookSource {
  const LegadoBookSource._(this.raw);

  factory LegadoBookSource.fromJson(Map<String, dynamic> json) {
    final raw = Map<String, dynamic>.unmodifiable(json);
    if (_string(raw['bookSourceUrl']).isEmpty ||
        _string(raw['bookSourceName']).isEmpty) {
      throw const FormatException(
        'Legado source requires bookSourceUrl and bookSourceName.',
      );
    }
    final uri = Uri.tryParse(_string(raw['bookSourceUrl']).split('#').first);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException(
        'Legado bookSourceUrl must be an absolute HTTP(S) URL.',
      );
    }
    return LegadoBookSource._(raw);
  }

  final Map<String, dynamic> raw;

  String get url => _string(raw['bookSourceUrl']);
  String get name => _string(raw['bookSourceName']);
  String get group => _string(raw['bookSourceGroup']);
  String get comment => _string(raw['bookSourceComment']);
  int get type => _integer(raw['bookSourceType']);
  String get searchUrl => _string(raw['searchUrl']);
  String get exploreUrl => _string(raw['exploreUrl']);
  bool get enabledExplore => raw['enabledExplore'] != false;
  bool get enabled => raw['enabled'] != false;
  bool get enabledCookieJar => raw['enabledCookieJar'] == true;
  int get lastUpdateTime => _integer(raw['lastUpdateTime']);
  int get respondTime => _integer(raw['respondTime']);

  Uri get baseUri => Uri.parse(url.split('#').first);

  LegadoExploreCatalog get exploreCatalog => parseLegadoExploreCatalog(raw);

  String get stableId =>
      'legado.${sha256.convert(utf8.encode(url)).toString().substring(0, 24)}';

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
    bool? enabled,
    bool readingChainVerified = false,
    LegadoCompatibilityReport? compatibilityReport,
    DateTime? addedAt,
  }) {
    final report =
        compatibilityReport ?? const LegadoCompatibilityScanner().scan(this);
    final shouldEnable = enabled ?? this.enabled;
    final capabilities = <String>{
      if (searchUrl.isNotEmpty && rule('ruleSearch').isNotEmpty) 'search',
      if (rule('ruleBookInfo').isNotEmpty) 'detail',
      if (rule('ruleToc').isNotEmpty) 'catalog',
      if (rule('ruleContent').isNotEmpty) 'content',
      if (exploreCatalog.canBrowse) ...{'categories', 'browse'},
    };
    return RegisteredBookSource(
      id: stableId,
      name: name,
      description: comment,
      manifestUrl: baseUri,
      apiBaseUrl: baseUri,
      websiteUrl: baseUri,
      protocolVersion: 'legado-3',
      languages: const [],
      // Import is deliberately optimistic: available rule groups decide which
      // actions may be attempted. Unsupported syntax is reported only when the
      // user invokes that action, so one advanced rule does not disable an
      // otherwise usable source at import time.
      capabilities: capabilities,
      enabled: shouldEnable && capabilities.isNotEmpty,
      addedAt: addedAt ?? DateTime.now(),
      sourceProtocol: BookSourceProtocolKind.legado,
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

bool isReadingChainVerifiedLegadoSource(RegisteredBookSource source) {
  return source.sourceProtocol == BookSourceProtocolKind.legado &&
      source.sourceConfig?['_openReadingReadingChainVerifiedAt'] is String;
}

class LegadoCompatibilityReport {
  const LegadoCompatibilityReport({required this.level, required this.issues});

  final LegadoCompatibilityLevel level;
  final Set<LegadoCompatibilityIssue> issues;

  bool get canRun => level == LegadoCompatibilityLevel.supported;
}

class LegadoCompatibilityScanner {
  const LegadoCompatibilityScanner();

  LegadoCompatibilityReport scan(LegadoBookSource source) {
    final issues = <LegadoCompatibilityIssue>{};
    final typeIssue = switch (source.type) {
      1 => LegadoCompatibilityIssue.audio,
      2 => LegadoCompatibilityIssue.image,
      3 => LegadoCompatibilityIssue.file,
      4 => LegadoCompatibilityIssue.video,
      _ => null,
    };
    if (typeIssue != null) issues.add(typeIssue);
    if (source.searchUrl.isEmpty) {
      issues.add(LegadoCompatibilityIssue.missingSearch);
    }
    if (source.hasMalformedRuleJson) {
      issues.add(LegadoCompatibilityIssue.missingReadingRules);
    }
    if (source.rule('ruleToc').isEmpty || source.rule('ruleContent').isEmpty) {
      issues.add(LegadoCompatibilityIssue.missingReadingRules);
    }
    final coreConfiguration = Map<String, dynamic>.from(source.raw)
      ..remove('enabledExplore')
      ..remove('exploreUrl')
      ..remove('exploreScreen')
      ..remove('ruleExplore')
      // Login support is optional in Legado. Its mere presence must not make
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
        issues.add(LegadoCompatibilityIssue.login);
      }
      if (field == 'jslib' ||
          field == 'mainjs' ||
          field.endsWith('js') ||
          text.contains('<js>') ||
          text.contains('@js:') ||
          text.contains('java.') ||
          text.contains('source.')) {
        issues.add(LegadoCompatibilityIssue.javascript);
      }
      if (field == 'header' && !_isStaticJsonObject(value)) {
        issues.add(LegadoCompatibilityIssue.javascript);
      }
      if (field.contains('webview') ||
          field == 'webjs' ||
          text.contains('webview') ||
          text.contains('webjs')) {
        issues.add(LegadoCompatibilityIssue.webView);
      }
      if (text.contains('"dnsip"')) {
        issues.add(LegadoCompatibilityIssue.customDns);
      }
      if (text.contains('"proxy"')) {
        issues.add(LegadoCompatibilityIssue.customProxy);
      }
      if (_isRuleField(field) &&
          (text.startsWith('@xpath:') || text.trimLeft().startsWith('//'))) {
        issues.add(LegadoCompatibilityIssue.xpath);
      }
      if (_isRuleField(field) &&
          (text.startsWith('@json:') || text.startsWith(r'$.')) &&
          (text.contains('?(') || text.contains('..'))) {
        issues.add(LegadoCompatibilityIssue.complexJsonPath);
      }
    });

    const blocked = {
      LegadoCompatibilityIssue.audio,
      LegadoCompatibilityIssue.video,
      LegadoCompatibilityIssue.image,
      LegadoCompatibilityIssue.file,
      LegadoCompatibilityIssue.javascript,
      LegadoCompatibilityIssue.webView,
      LegadoCompatibilityIssue.login,
      LegadoCompatibilityIssue.cookies,
      LegadoCompatibilityIssue.customDns,
      LegadoCompatibilityIssue.customProxy,
      LegadoCompatibilityIssue.missingSearch,
      LegadoCompatibilityIssue.missingReadingRules,
      LegadoCompatibilityIssue.xpath,
      LegadoCompatibilityIssue.complexJsonPath,
    };
    final hasBlockedIssue = issues.any(blocked.contains);
    final level = hasBlockedIssue
        ? LegadoCompatibilityLevel.unsupported
        : issues.isEmpty
        ? LegadoCompatibilityLevel.supported
        : LegadoCompatibilityLevel.partial;
    return LegadoCompatibilityReport(
      level: level,
      issues: Set.unmodifiable(issues),
    );
  }
}

class LegadoSourceImportResult {
  const LegadoSourceImportResult({
    required this.sources,
    required this.sourceUrls,
    required this.errors,
    required this.duplicates,
  });

  final List<LegadoBookSource> sources;
  final List<Uri> sourceUrls;
  final List<String> errors;
  final int duplicates;
}

LegadoSourceImportResult parseLegadoSources(
  String input, {
  int maxSources = 10000,
  int maxNestedUrls = 50,
}) {
  final text = input.replaceFirst('\ufeff', '').trim();
  if (text.isEmpty) throw const FormatException('Source JSON is empty.');
  return parseLegadoSourcePayload(
    jsonDecode(text),
    maxSources: maxSources,
    maxNestedUrls: maxNestedUrls,
  );
}

LegadoSourceImportResult parseLegadoSourcePayload(
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
  final byUrl = <String, LegadoBookSource>{};
  final errors = <String>[];
  var duplicates = 0;
  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    if (candidate is! Map) {
      errors.add('Item ${index + 1} is not an object.');
      continue;
    }
    try {
      final source = LegadoBookSource.fromJson(
        candidate.map((key, value) => MapEntry('$key', value)),
      );
      if (byUrl.containsKey(source.url)) duplicates++;
      byUrl[source.url] = source;
    } on FormatException catch (error) {
      errors.add('Item ${index + 1}: ${error.message}');
    }
  }
  return LegadoSourceImportResult(
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

bool _isStaticJsonObject(String value) {
  try {
    return jsonDecode(value) is Map;
  } on FormatException {
    return false;
  }
}

bool _isRuleField(String field) => const {
  'booklist',
  'name',
  'author',
  'intro',
  'kind',
  'bookurl',
  'coverurl',
  'lastchapter',
  'wordcount',
  'init',
  'tocurl',
  'chapterlist',
  'chaptername',
  'chapterurl',
  'nexttocurl',
  'content',
  'nextcontenturl',
  'replaceregex',
}.contains(field);
