import 'dart:convert';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/source_engine/source_config.dart';
import 'source_edit_fields.dart';

/// Applies only edited fields to a detached configuration. Unknown fields and
/// JSON-encoded rule groups survive opening and saving the form unchanged.
class SourceEditDraft {
  SourceEditDraft(this.source)
    : _original =
          jsonDecode(jsonEncode(source.sourceConfig!)) as Map<String, dynamic>;

  final RegisteredBookSource source;
  final Map<String, dynamic> _original;

  Object? value(SourceEditField field) {
    if (field.group == null) {
      if (field.key == 'bookSourceGroup') return source.groups.join(', ');
      return _original[field.key];
    }
    return _group(field.group!)[field.key];
  }

  String text(SourceEditField field) {
    final raw = value(field);
    return raw is Map || raw is List
        ? const JsonEncoder.withIndent('  ').convert(raw)
        : raw?.toString() ?? '';
  }

  Map<String, dynamic> _group(String name) {
    final raw = _original[name];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw FormatException('Expected a rule object: $name');
    }
    if (raw != null) {
      throw FormatException('Expected a rule object: $name');
    }
    return {};
  }

  Map<String, dynamic> build({
    required Map<String, String> values,
    required bool enabled,
    required bool enabledExplore,
    required bool enabledCookieJar,
    required int type,
  }) {
    final config = jsonDecode(jsonEncode(_original)) as Map<String, dynamic>;
    for (final section in sourceEditSections) {
      for (final field in section.fields) {
        final edited = values[field.id];
        if (edited == null || edited == text(field)) continue;
        final old = value(field);
        Object? next = edited;
        if ((old is Map || old is List) && edited.trim().isNotEmpty) {
          next = jsonDecode(edited);
          if ((old is Map && next is! Map) || (old is List && next is! List)) {
            throw FormatException('Invalid JSON shape: ${field.id}');
          }
        }
        if (field.group == null) {
          config[field.key] = next;
        } else {
          // Several fields may edit the same original JSON string group.
          final current = config[field.group];
          final group = current is Map
              ? Map<String, dynamic>.from(current)
              : _group(field.group!);
          group[field.key] = next;
          config[field.group!] = group;
        }
      }
    }
    config['bookSourceName'] = '${config['bookSourceName'] ?? ''}'.trim();
    config['bookSourceUrl'] = '${config['bookSourceUrl'] ?? ''}'.trim();
    config['bookSourceGroup'] =
        values['bookSourceGroup'] ?? source.groups.join(', ');
    config['enabled'] = enabled;
    if (enabledExplore != (_original['enabledExplore'] != false)) {
      config['enabledExplore'] = enabledExplore;
    }
    if (enabledCookieJar != (_original['enabledCookieJar'] == true)) {
      config['enabledCookieJar'] = enabledCookieJar;
    }
    if (type != ReadingSourceConfig.fromJson(_original).type) {
      config['bookSourceType'] = type;
    }
    ReadingSourceConfig.fromJson(config);
    return config;
  }
}
