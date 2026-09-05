import 'dart:convert';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart';
import '../../../utils/fast_gbk_decoder.dart';

/// Encoding overloads shared by java.* helpers and named Java class bridges.
class SourceScriptEncodingApi {
  const SourceScriptEncodingApi();

  static const operations = {
    'strToBytes',
    'bytesToStr',
    'formEncode',
    'formDecode',
    'base64Encode',
    'base64Decode',
    'base64EncodeBytes',
    'base64DecodeBytes',
    'hexEncodeToString',
    'hexDecodeToBytes',
  };

  Object handle(String operation, List arguments) {
    final value = arguments.isEmpty ? null : arguments.first;
    final option = arguments.length > 1 ? arguments[1] : null;
    return switch (operation) {
      'strToBytes' => _encode('${value ?? ''}', '$option'),
      'bytesToStr' => _decode(_bytes(value), '$option'),
      'formEncode' => _formEncode('${value ?? ''}', '$option'),
      'formDecode' => _formDecode('${value ?? ''}', '$option'),
      'base64Encode' => _base64Encode(utf8.encode('${value ?? ''}'), option),
      'base64EncodeBytes' => _base64Encode(_bytes(value), option),
      'base64Decode' => _decode(
        _base64Decode('${value ?? ''}'),
        option is String ? option : 'UTF-8',
      ),
      'base64DecodeBytes' => _base64Decode('${value ?? ''}'),
      'hexEncodeToString' =>
        utf8
            .encode('${value ?? ''}')
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
      'hexDecodeToBytes' => _hexDecode('${value ?? ''}'),
      _ => throw ArgumentError.value(operation, 'operation'),
    };
  }
}

List<int> _bytes(Object? value) => value is Iterable
    ? value.map((byte) => (byte as num).toInt() & 0xff).toList(growable: false)
    : utf8.encode('${value ?? ''}');

String _charset(String value) {
  final name = value.trim().toLowerCase().replaceAll(RegExp('[-_]'), '');
  return switch (name) {
    '' || 'null' || 'utf8' => 'utf8',
    'gbk' || 'gb2312' || 'cp936' || 'windows936' => 'gbk',
    'latin1' || 'iso88591' => 'latin1',
    'ascii' || 'usascii' => 'ascii',
    'utf16' || 'utf16le' || 'utf16be' => name,
    _ => throw FormatException('Unsupported source script charset: $value'),
  };
}

List<int> _encode(String text, String charset) {
  final name = _charset(charset);
  if (name == 'utf8') return utf8.encode(text);
  if (name == 'gbk') return gbk_bytes.encode(text);
  if (name == 'latin1' || name == 'ascii') {
    final max = name == 'ascii' ? 127 : 255;
    return text.runes.map((rune) => rune <= max ? rune : 63).toList();
  }
  final little = name == 'utf16le';
  return [
    if (name == 'utf16') ...[0xfe, 0xff],
    for (final unit in text.codeUnits)
      ...little ? [unit & 255, unit >> 8] : [unit >> 8, unit & 255],
  ];
}

String _decode(List<int> bytes, String charset) {
  final name = _charset(charset);
  if (name == 'utf8') return utf8.decode(bytes, allowMalformed: true);
  if (name == 'gbk') {
    return decodeGbkFast(Uint8List.fromList(bytes), lenient: true);
  }
  if (name == 'latin1') return latin1.decode(bytes);
  if (name == 'ascii') return ascii.decode(bytes, allowInvalid: true);
  var little = name == 'utf16le';
  var start = 0;
  if (name == 'utf16' && bytes.length >= 2) {
    if (bytes[0] == 0xff && bytes[1] == 0xfe) {
      little = true;
      start = 2;
    } else if (bytes[0] == 0xfe && bytes[1] == 0xff) {
      start = 2;
    }
  }
  return String.fromCharCodes([
    for (var i = start; i + 1 < bytes.length; i += 2)
      little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
    if ((bytes.length - start).isOdd) 0xfffd,
  ]);
}

bool _formSafe(int unit) =>
    (unit >= 65 && unit <= 90) ||
    (unit >= 97 && unit <= 122) ||
    (unit >= 48 && unit <= 57) ||
    unit == 45 ||
    unit == 95 ||
    unit == 46 ||
    unit == 42;

String _formEncode(String value, String charset) {
  final output = StringBuffer();
  var index = 0;
  while (index < value.length) {
    final unit = value.codeUnitAt(index);
    if (_formSafe(unit) || unit == 32) {
      output.writeCharCode(unit == 32 ? 43 : unit);
      index++;
      continue;
    }
    final start = index++;
    while (index < value.length &&
        !_formSafe(value.codeUnitAt(index)) &&
        value.codeUnitAt(index) != 32) {
      index++;
    }
    for (final byte in _encode(value.substring(start, index), charset)) {
      output.write('%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    }
  }
  return output.toString();
}

String _formDecode(String value, String charset) {
  final output = StringBuffer();
  for (var i = 0; i < value.length;) {
    if (value[i] != '%') {
      output.write(value[i] == '+' ? ' ' : value[i]);
      i++;
      continue;
    }
    final bytes = <int>[];
    while (i < value.length && value[i] == '%') {
      if (i + 2 >= value.length) {
        throw const FormatException('Incomplete URL escape');
      }
      bytes.add(int.parse(value.substring(i + 1, i + 3), radix: 16));
      i += 3;
    }
    output.write(_decode(bytes, charset));
  }
  return output.toString();
}

String _base64Encode(List<int> bytes, Object? option) {
  final flags = option is num ? option.toInt() : 2;
  var value = (flags & 8) != 0 ? base64UrlEncode(bytes) : base64Encode(bytes);
  if ((flags & 1) != 0) value = value.replaceAll('=', '');
  if ((flags & 2) != 0 || value.isEmpty) return value;
  final newline = (flags & 4) != 0 ? '\r\n' : '\n';
  return [
        for (var i = 0; i < value.length; i += 76)
          value.substring(i, i + 76 < value.length ? i + 76 : value.length),
      ].join(newline) +
      newline;
}

List<int> _base64Decode(String value) =>
    base64Decode(base64.normalize(value.replaceAll(RegExp(r'\s+'), '')));

List<int> _hexDecode(String value) {
  final text = value.replaceAll(RegExp(r'\s+'), '');
  if (text.length.isOdd) throw const FormatException('Odd hexadecimal length');
  return [
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ];
}
