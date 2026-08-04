import 'dart:convert';

class SourceLoginField {
  const SourceLoginField({
    required this.name,
    required this.type,
    this.viewName,
    this.defaultValue,
    this.chars = const [],
    this.action,
  });

  final String name;
  final String type;
  final String? viewName;
  final String? defaultValue;
  final List<String> chars;
  final String? action;

  bool get isInput => type == 'text' || type == 'password';
  bool get isButton => type == 'button';

  factory SourceLoginField.fromJson(Object? value) {
    final map = value is Map ? value : const {};
    final chars = map['chars'];
    return SourceLoginField(
      name: '${map['name'] ?? ''}'.trim(),
      type: '${map['type'] ?? 'text'}'.trim().toLowerCase(),
      viewName: _optionalText(map['viewName']),
      defaultValue: _optionalText(map['default']),
      chars: chars is List
          ? [for (final item in chars) '${item ?? ''}']
          : const [],
      action: _optionalText(map['action']),
    );
  }
}

List<SourceLoginField> parseSourceLoginFields(Object? value) {
  Object? decoded = value;
  if (value is String) {
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return const [];
    }
  }
  if (decoded is! List) return const [];
  return [
    for (final item in decoded)
      if (item is Map && '${item['name'] ?? ''}'.trim().isNotEmpty)
        SourceLoginField.fromJson(item),
  ];
}

String? _optionalText(Object? value) {
  final text = '$value'.trim();
  return value == null || text.isEmpty ? null : text;
}
