import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../services/books/enhanced_txt_import_service.dart';
import '../../utils/fast_gbk_decoder.dart';
import 'reader_text_characters.dart';
import 'txt_chapter_parser.dart';

const int streamingTxtIndexVersion = 1;
const int streamingTxtDefaultPartChars = 32 * 1024;

/// Builds a bounded-memory UTF-8 cache and chapter byte index.
///
/// This top-level synchronous entry point is intended for `compute`. The
/// returned chapter `start` and `end` offsets address [dataPath] directly.
Map<String, dynamic> buildStreamingTxtIndexWorker(
  Map<String, dynamic> arguments,
) {
  final sourcePath = arguments['sourcePath'] as String;
  final dataPath = arguments['dataPath'] as String;
  final fallbackTitle = arguments['title'] as String;
  final prefaceTitle = arguments['prefaceTitle'] as String;
  final maxChars =
      arguments['maxCharsPerSection'] as int? ?? streamingTxtDefaultPartChars;
  if (maxChars <= 0) throw ArgumentError.value(maxChars, 'maxCharsPerSection');

  final normalized = _normalizeToUtf8Cache(
    sourcePath: sourcePath,
    dataPath: dataPath,
    encodingHint: arguments['encoding'] as String?,
  );
  final scan = _scanSourceSections(
    File(dataPath),
    fallbackTitle: fallbackTitle,
    prefaceTitle: prefaceTitle,
  );
  final chapters = <Map<String, dynamic>>[];
  for (final source in scan.sections) {
    final ranges = _splitSourceRange(
      File(dataPath),
      source.start,
      source.end,
      maxChars,
    );
    for (var index = 0; index < ranges.length; index++) {
      final range = ranges[index];
      chapters.add(<String, dynamic>{
        'id': index == 0 ? source.id : '${source.id}-part-$index',
        'title': index == 0
            ? source.title
            : '${source.title} · ${index + 1}/${ranges.length}',
        'depth': 0,
        'isNeedSplitTitle': index == 0 && source.isNeedSplitTitle,
        'start': range.start,
        'end': range.end,
        'sourceChapterId': ranges.length > 1 ? source.id : null,
        'sourceBodyStart': range.sourceBodyStart,
      });
    }
  }
  return <String, dynamic>{
    'version': streamingTxtIndexVersion,
    'dataPath': dataPath,
    'contentHash': normalized.contentHash,
    'textEncoding': normalized.encoding,
    'requiresUtf8Conversion': normalized.encoding != 'utf8',
    'hasUtf8Bom': normalized.hasUtf8Bom,
    'predominantNewline': scan.crlfCount > scan.lfCount ? '\r\n' : '\n',
    'chapters': chapters,
  };
}

class _NormalizedSource {
  const _NormalizedSource({
    required this.contentHash,
    required this.encoding,
    required this.hasUtf8Bom,
  });

  final String contentHash;
  final String encoding;
  final bool hasUtf8Bom;
}

_NormalizedSource _normalizeToUtf8Cache({
  required String sourcePath,
  required String dataPath,
  required String? encodingHint,
}) {
  final source = File(sourcePath);
  final input = source.openSync();
  final sample = input.readSync(256 * 1024 + 4);
  input.setPositionSync(0);
  final hasUtf8Bom =
      sample.length >= 3 &&
      sample[0] == 0xef &&
      sample[1] == 0xbb &&
      sample[2] == 0xbf;
  final hasUtf16LeBom =
      sample.length >= 2 && sample[0] == 0xff && sample[1] == 0xfe;
  final hasUtf16BeBom =
      sample.length >= 2 && sample[0] == 0xfe && sample[1] == 0xff;
  final importer = EnhancedTxtImportService();
  final hint = EnhancedTxtImportService.normalizeEncoding(encodingHint);
  final encoding = hasUtf8Bom
      ? 'utf8'
      : hasUtf16LeBom
      ? 'utf16le'
      : hasUtf16BeBom
      ? 'utf16be'
      : hint == 'auto' || hint == 'gbk'
      ? importer
            .decodeWithResult(
              sample,
              encodingOverride: hint,
              verifyEncodingOverride: true,
            )
            .encoding
      : hint;
  if (!const {'utf8', 'utf16le', 'utf16be', 'gbk'}.contains(encoding)) {
    input.closeSync();
    throw const FormatException('Unsupported TXT encoding');
  }

  final target = File(dataPath);
  target.parent.createSync(recursive: true);
  final temporary = File('$dataPath.tmp');
  if (temporary.existsSync()) temporary.deleteSync();
  final output = temporary.openSync(mode: FileMode.write);
  late Digest digest;
  final digestOutput = ChunkedConversionSink<Digest>.withCallback(
    (values) => digest = values.single,
  );
  final digestInput = sha256.startChunkedConversion(digestOutput);
  var skipped = 0;
  final bomBytes = hasUtf8Bom ? 3 : (hasUtf16LeBom || hasUtf16BeBom ? 2 : 0);
  final utf16Decoder = encoding.startsWith('utf16')
      ? _Utf16StreamDecoder(littleEndian: encoding == 'utf16le')
      : null;
  final gbkDecoder = encoding == 'gbk' ? _GbkStreamDecoder() : null;
  Object? conversionError;
  StackTrace? conversionStack;
  try {
    while (true) {
      final chunk = input.readSync(64 * 1024);
      if (chunk.isEmpty) break;
      digestInput.add(chunk);
      var payload = chunk;
      if (skipped < bomBytes) {
        final count = (bomBytes - skipped).clamp(0, payload.length);
        payload = Uint8List.sublistView(payload, count);
        skipped += count;
      }
      if (payload.isEmpty) continue;
      if (encoding == 'utf8') {
        output.writeFromSync(payload);
      } else {
        final decoded = utf16Decoder?.add(payload) ?? gbkDecoder!.add(payload);
        if (decoded.isNotEmpty) output.writeFromSync(utf8.encode(decoded));
      }
    }
    digestInput.close();
    final trailing = utf16Decoder?.close() ?? gbkDecoder?.close() ?? '';
    if (trailing.isNotEmpty) output.writeFromSync(utf8.encode(trailing));
    output.flushSync();
  } catch (error, stackTrace) {
    conversionError = error;
    conversionStack = stackTrace;
  } finally {
    input.closeSync();
    output.closeSync();
  }
  if (conversionError != null) {
    if (temporary.existsSync()) temporary.deleteSync();
    Error.throwWithStackTrace(conversionError, conversionStack!);
  }
  // Strict validation is performed by the scanner for UTF-8 and by the
  // streaming decoders for legacy encodings.
  try {
    _validateUtf8File(temporary);
    if (target.existsSync()) target.deleteSync();
    temporary.renameSync(target.path);
  } catch (_) {
    if (temporary.existsSync()) temporary.deleteSync();
    rethrow;
  }
  return _NormalizedSource(
    contentHash: digest.toString(),
    encoding: encoding,
    hasUtf8Bom: hasUtf8Bom,
  );
}

class _Utf16StreamDecoder {
  _Utf16StreamDecoder({required this.littleEndian});

  final bool littleEndian;
  int? _pendingByte;
  int? _pendingHighSurrogate;

  String add(Uint8List bytes) {
    final output = StringBuffer();
    var index = 0;
    if (_pendingByte case final first?) {
      if (bytes.isEmpty) return '';
      _addUnit(_unit(first, bytes[0]), output);
      _pendingByte = null;
      index = 1;
    }
    while (index + 1 < bytes.length) {
      _addUnit(_unit(bytes[index], bytes[index + 1]), output);
      index += 2;
    }
    if (index < bytes.length) _pendingByte = bytes[index];
    return output.toString();
  }

  String close() {
    if (_pendingByte != null || _pendingHighSurrogate != null) {
      throw const FormatException('Incomplete UTF-16 sequence');
    }
    return '';
  }

  int _unit(int first, int second) =>
      littleEndian ? first | (second << 8) : (first << 8) | second;

  void _addUnit(int unit, StringBuffer output) {
    if (_pendingHighSurrogate case final high?) {
      if (unit < 0xdc00 || unit > 0xdfff) {
        throw const FormatException('Invalid UTF-16 surrogate pair');
      }
      output.writeCharCode(high);
      output.writeCharCode(unit);
      _pendingHighSurrogate = null;
      return;
    }
    if (unit >= 0xd800 && unit <= 0xdbff) {
      _pendingHighSurrogate = unit;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('Unexpected UTF-16 low surrogate');
    } else {
      output.writeCharCode(unit);
    }
  }
}

class _GbkStreamDecoder {
  int? _lead;

  String add(Uint8List bytes) {
    final output = StringBuffer();
    for (final byte in bytes) {
      if (_lead case final lead?) {
        final decoded = decodeGbkFast(
          Uint8List.fromList(<int>[lead, byte]),
          lenient: false,
        );
        if (decoded.contains('\uFFFD')) {
          throw const FormatException('Invalid GBK sequence');
        }
        output.write(decoded);
        _lead = null;
      } else if (byte <= 0x7f) {
        output.writeCharCode(byte);
      } else {
        _lead = byte;
      }
    }
    return output.toString();
  }

  String close() {
    if (_lead != null) throw const FormatException('Incomplete GBK sequence');
    return '';
  }
}

void _validateUtf8File(File file) {
  final reader = _Utf8ScalarReader(file);
  try {
    while (reader.next() != null) {}
  } finally {
    reader.close();
  }
}

class _SourceScan {
  const _SourceScan({
    required this.sections,
    required this.crlfCount,
    required this.lfCount,
  });

  final List<_SourceSection> sections;
  final int crlfCount;
  final int lfCount;
}

class _SourceSection {
  const _SourceSection({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.isNeedSplitTitle,
  });

  final String id;
  final String title;
  final int start;
  final int end;
  final bool isNeedSplitTitle;
}

_SourceScan _scanSourceSections(
  File file, {
  required String fallbackTitle,
  required String prefaceTitle,
}) {
  final reader = _Utf8ScalarReader(file);
  final sections = <_SourceSection>[];
  var headingCount = 0;
  var lineStart = 0;
  var candidate = _BoundedTrimmedLine();
  var lineTrimmedNonEmpty = false;
  int? lineLastVisibleEnd;
  int? currentStart;
  int? currentLastVisibleEnd;
  var currentId = 'txt-preface';
  var currentTitle = prefaceTitle;
  var currentNeedsTitle = false;
  var crlfCount = 0;
  var lfCount = 0;
  _Utf8Scalar? pending;

  void finishBody(int boundary, {required bool isPreface}) {
    if (isPreface && currentStart == null) return;
    final start = currentStart ?? boundary;
    final end = currentLastVisibleEnd ?? boundary;
    if (isPreface && end <= start) return;
    sections.add(
      _SourceSection(
        id: currentId,
        title: currentTitle,
        start: start.clamp(0, end),
        end: end,
        isNeedSplitTitle: currentNeedsTitle,
      ),
    );
  }

  void finishLine(int afterBreak) {
    final heading = candidate.toHeading();
    if (heading != null) {
      finishBody(lineStart, isPreface: headingCount == 0);
      currentId = 'txt-$headingCount';
      currentTitle = heading;
      currentNeedsTitle = true;
      currentStart = null;
      currentLastVisibleEnd = null;
      headingCount++;
    } else {
      if (currentStart == null && lineTrimmedNonEmpty) currentStart = lineStart;
      if (lineLastVisibleEnd != null) {
        currentLastVisibleEnd = lineLastVisibleEnd;
      }
    }
    lineStart = afterBreak;
    candidate = _BoundedTrimmedLine();
    lineTrimmedNonEmpty = false;
    lineLastVisibleEnd = null;
  }

  try {
    while (true) {
      final scalar = pending ?? reader.next();
      pending = null;
      if (scalar == null) break;
      if (scalar.rune == 0x0d) {
        final next = reader.next();
        if (next?.rune == 0x0a) {
          crlfCount++;
          finishLine(next!.end);
        } else {
          finishLine(scalar.end);
          pending = next;
        }
        continue;
      }
      if (isReaderLineBreakCodeUnit(scalar.rune)) {
        if (scalar.rune == 0x0a) lfCount++;
        finishLine(scalar.end);
        continue;
      }
      candidate.add(scalar.rune);
      if (!_isDartTrimRune(scalar.rune)) lineTrimmedNonEmpty = true;
      if (!isReaderIndentCodeUnit(scalar.rune)) {
        lineLastVisibleEnd = scalar.end;
      }
    }
    finishLine(file.lengthSync());
    if (headingCount == 0) {
      return _SourceScan(
        sections: <_SourceSection>[
          _SourceSection(
            id: 'txt-0',
            title: fallbackTitle,
            start: 0,
            end: file.lengthSync(),
            isNeedSplitTitle: false,
          ),
        ],
        crlfCount: crlfCount,
        lfCount: lfCount,
      );
    }
    finishBody(file.lengthSync(), isPreface: false);
    return _SourceScan(
      sections: sections,
      crlfCount: crlfCount,
      lfCount: lfCount,
    );
  } finally {
    reader.close();
  }
}

class _BoundedTrimmedLine {
  static const int _limit = 128;
  final StringBuffer _content = StringBuffer();
  final StringBuffer _pendingWhitespace = StringBuffer();
  var _length = 0;
  var _pendingWhitespaceOverflow = false;
  var _tooLong = false;

  void add(int rune) {
    if (_tooLong) return;
    if (_isDartTrimRune(rune)) {
      if (_length > 0) {
        if (_length + _pendingWhitespace.length < _limit) {
          _pendingWhitespace.writeCharCode(rune);
        } else {
          _pendingWhitespaceOverflow = true;
        }
      }
      return;
    }
    if (_pendingWhitespaceOverflow) {
      final prefix = _content.toString();
      if (RegExp(r'^#{1,6}$').hasMatch(prefix)) {
        _pendingWhitespace.clear();
        _pendingWhitespaceOverflow = false;
      } else {
        _tooLong = true;
        return;
      }
    }
    final pending = _pendingWhitespace.toString();
    final runeLength = rune > 0xffff ? 2 : 1;
    if (_length + pending.length + runeLength > _limit) {
      _tooLong = true;
      return;
    }
    _content.write(pending);
    _pendingWhitespace.clear();
    _content.writeCharCode(rune);
    _length += pending.length + runeLength;
  }

  String? toHeading() =>
      _tooLong ? null : normalizedTxtChapterHeading(_content.toString());
}

bool _isDartTrimRune(int rune) =>
    (rune >= 0x0009 && rune <= 0x000d) ||
    rune == 0x0020 ||
    rune == 0x0085 ||
    rune == 0x00a0 ||
    rune == 0x1680 ||
    rune == 0x180e ||
    (rune >= 0x2000 && rune <= 0x200a) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202f ||
    rune == 0x205f ||
    rune == 0x3000 ||
    rune == 0xfeff;

class _PartRange {
  const _PartRange({
    required this.start,
    required this.end,
    required this.sourceBodyStart,
  });

  final int start;
  final int end;
  final int sourceBodyStart;
}

List<_PartRange> _splitSourceRange(
  File file,
  int sourceStart,
  int sourceEnd,
  int maxChars,
) {
  if (sourceStart == sourceEnd) {
    return <_PartRange>[
      _PartRange(start: sourceStart, end: sourceEnd, sourceBodyStart: 0),
    ];
  }
  final ranges = <_PartRange>[];
  var start = sourceStart;
  var sourceBodyStart = 0;
  final reader = _Utf8ScalarReader(file, start: sourceStart, end: sourceEnd);
  try {
    while (start < sourceEnd) {
      final split = _findPartEnd(reader, start, maxChars);
      ranges.add(
        _PartRange(
          start: start,
          end: split.end,
          sourceBodyStart: sourceBodyStart,
        ),
      );
      if (split.end <= start) throw const FormatException('Invalid TXT split');
      start = split.end;
      sourceBodyStart += split.utf16Length;
    }
  } finally {
    reader.close();
  }
  return ranges;
}

({int end, int utf16Length}) _findPartEnd(
  _Utf8ScalarReader reader,
  int start,
  int maxChars,
) {
  if (reader.position != start) reader.seek(start);
  var length = 0;
  var safeEnd = start;
  var safeLength = 0;
  int? lastBreakEnd;
  int? lastBreakLength;
  _Utf8Scalar? pending;
  while (true) {
    final scalar = pending ?? reader.next();
    pending = null;
    if (scalar == null) {
      return (end: reader.position, utf16Length: length);
    }
    if (scalar.rune == 0x0d) {
      final next = reader.next();
      if (next?.rune == 0x0a && length + 1 == maxChars) {
        length += 2;
        return (end: next!.end, utf16Length: length);
      }
      pending = next;
    }
    final scalarLength = scalar.rune > 0xffff ? 2 : 1;
    if (length + scalarLength > maxChars) {
      return (
        end: lastBreakEnd ?? safeEnd,
        utf16Length: lastBreakLength ?? safeLength,
      );
    }
    length += scalarLength;
    safeEnd = scalar.end;
    safeLength = length;
    if (isReaderLineBreakCodeUnit(scalar.rune) &&
        length >= maxChars - 16 * 1024) {
      lastBreakEnd = scalar.end;
      lastBreakLength = length;
    }
    if (length == maxChars) {
      return (
        end: lastBreakEnd ?? safeEnd,
        utf16Length: lastBreakLength ?? safeLength,
      );
    }
  }
}

class _Utf8Scalar {
  const _Utf8Scalar({
    required this.rune,
    required this.start,
    required this.end,
  });

  final int rune;
  final int start;
  final int end;
}

class _Utf8ScalarReader {
  _Utf8ScalarReader(File file, {int start = 0, int? end})
    : _input = file.openSync(),
      _position = start,
      _end = end ?? file.lengthSync() {
    _input.setPositionSync(start);
  }

  final RandomAccessFile _input;
  final int _end;
  int _position;
  Uint8List _buffer = Uint8List(0);
  var _index = 0;

  int get position => _position;

  void seek(int position) {
    if (position < 0 || position > _end) {
      throw RangeError.range(position, 0, _end, 'position');
    }
    _input.setPositionSync(position);
    _position = position;
    _buffer = Uint8List(0);
    _index = 0;
  }

  _Utf8Scalar? next() {
    final start = _position;
    final first = _readByte();
    if (first == null) return null;
    if (first <= 0x7f) {
      return _Utf8Scalar(rune: first, start: start, end: _position);
    }
    final count = first >= 0xc2 && first <= 0xdf
        ? 2
        : first >= 0xe0 && first <= 0xef
        ? 3
        : first >= 0xf0 && first <= 0xf4
        ? 4
        : 0;
    if (count == 0) throw const FormatException('Invalid UTF-8 lead byte');
    final values = <int>[first];
    for (var index = 1; index < count; index++) {
      final next = _readByte();
      if (next == null || next < 0x80 || next > 0xbf) {
        throw const FormatException('Invalid UTF-8 continuation byte');
      }
      values.add(next);
    }
    var rune = count == 2
        ? first & 0x1f
        : count == 3
        ? first & 0x0f
        : first & 0x07;
    for (final byte in values.skip(1)) {
      rune = (rune << 6) | (byte & 0x3f);
    }
    if ((count == 2 && rune < 0x80) ||
        (count == 3 && rune < 0x800) ||
        (count == 4 && rune < 0x10000) ||
        (rune >= 0xd800 && rune <= 0xdfff) ||
        rune > 0x10ffff) {
      throw const FormatException('Invalid UTF-8 scalar');
    }
    return _Utf8Scalar(rune: rune, start: start, end: _position);
  }

  int? _readByte() {
    if (_position >= _end) return null;
    if (_index >= _buffer.length) {
      final remaining = _end - _position;
      _buffer = _input.readSync(remaining.clamp(0, 64 * 1024));
      _index = 0;
      if (_buffer.isEmpty) return null;
    }
    _position++;
    return _buffer[_index++];
  }

  void close() => _input.closeSync();
}
