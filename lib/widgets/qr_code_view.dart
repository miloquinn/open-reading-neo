import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../utils/localization_extension.dart';

/// Renders a QR code locally so TOTP secrets never leave the device.
///
/// The encoder is a compact byte-mode adaptation of the BSD-licensed `qr`
/// package by Kevin Moore and contributors. It supports QR byte mode with
/// medium error correction through version 20, which covers account-service
/// `otpauth://` values without sending the secret to a remote QR service.
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, this.size = 224});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = _QrImage(_QrCode.fromData(data));
    return Semantics(
      image: true,
      label: context.l10n.accountMfaQrCodeLabel,
      child: Container(
        width: size,
        height: size,
        color: Colors.white,
        child: CustomPaint(
          painter: _QrPainter(image),
          isComplex: true,
          willChange: false,
        ),
      ),
    );
  }
}

@visibleForTesting
List<List<bool>> encodeQrModules(String data) {
  final image = _QrImage(_QrCode.fromData(data));
  return List.generate(
    image.moduleCount,
    (row) => List.generate(
      image.moduleCount,
      (column) => image.isDark(row, column),
      growable: false,
    ),
    growable: false,
  );
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.image);

  final _QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    const quietZoneModules = 4;
    final fullModuleCount = image.moduleCount + quietZoneModules * 2;
    final moduleSize = math.min(size.width, size.height) / fullModuleCount;
    final offsetX =
        (size.width - moduleSize * fullModuleCount) / 2 +
        quietZoneModules * moduleSize;
    final offsetY =
        (size.height - moduleSize * fullModuleCount) / 2 +
        quietZoneModules * moduleSize;
    final paint = Paint()..color = Colors.black;
    for (var row = 0; row < image.moduleCount; row++) {
      for (var column = 0; column < image.moduleCount; column++) {
        if (!image.isDark(row, column)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            offsetX + column * moduleSize,
            offsetY + row * moduleSize,
            moduleSize + 0.15,
            moduleSize + 0.15,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.image.data != image.data;
}

class _QrCode {
  _QrCode(this.version) : moduleCount = version * 4 + 17, data = Uint8List(0);

  factory _QrCode.fromData(String value) {
    final bytes = Uint8List.fromList(utf8.encode(value));
    for (var version = 1; version <= _rsBlocksM.length; version++) {
      final dataCapacity = _rsBlocks(
        version,
      ).fold<int>(0, (sum, block) => sum + block.dataCount);
      final lengthBits = version < 10 ? 8 : 16;
      if (4 + lengthBits + bytes.length * 8 <= dataCapacity * 8) {
        final code = _QrCode(version);
        code.data = _createData(version, bytes);
        return code;
      }
    }
    throw ArgumentError.value(value, 'data', 'TOTP URI is too long');
  }

  final int version;
  final int moduleCount;
  late Uint8List data;
}

class _QrImage {
  _QrImage(_QrCode code)
    : data = code.data,
      moduleCount = code.moduleCount,
      version = code.version {
    final bestMask = _bestMask(code);
    _make(code, bestMask, test: false);
  }

  final Uint8List data;
  final int moduleCount;
  final int version;
  List<List<bool?>> _modules = [];

  bool isDark(int row, int column) => _modules[row][column]!;

  int _bestMask(_QrCode code) {
    var bestMask = 0;
    var bestScore = double.infinity;
    for (var mask = 0; mask < 8; mask++) {
      _make(code, mask, test: true);
      final score = _lostPoint();
      if (score < bestScore) {
        bestScore = score;
        bestMask = mask;
      }
    }
    return bestMask;
  }

  void _make(_QrCode code, int mask, {required bool test}) {
    _modules = List.generate(
      moduleCount,
      (_) => List<bool?>.filled(moduleCount, null),
    );
    _setupPositionProbe(0, 0);
    _setupPositionProbe(moduleCount - 7, 0);
    _setupPositionProbe(0, moduleCount - 7);
    _setupPositionAdjust();
    _setupTiming();
    _setupTypeInfo(mask, test);
    if (version >= 7) _setupTypeNumber(test);
    _mapData(code.data, mask);
  }

  void _setupPositionProbe(int row, int column) {
    for (var r = -1; r <= 7; r++) {
      if (row + r < 0 || row + r >= moduleCount) continue;
      for (var c = -1; c <= 7; c++) {
        if (column + c < 0 || column + c >= moduleCount) continue;
        _modules[row + r][column + c] =
            (r >= 0 && r <= 6 && (c == 0 || c == 6)) ||
            (c >= 0 && c <= 6 && (r == 0 || r == 6)) ||
            (r >= 2 && r <= 4 && c >= 2 && c <= 4);
      }
    }
  }

  void _setupPositionAdjust() {
    final positions = _patternPositions[version - 1];
    for (final row in positions) {
      for (final column in positions) {
        if (_modules[row][column] != null) continue;
        for (var r = -2; r <= 2; r++) {
          for (var c = -2; c <= 2; c++) {
            _modules[row + r][column + c] =
                r.abs() == 2 || c.abs() == 2 || (r == 0 && c == 0);
          }
        }
      }
    }
  }

  void _setupTiming() {
    for (var index = 8; index < moduleCount - 8; index++) {
      _modules[index][6] ??= index.isEven;
      _modules[6][index] ??= index.isEven;
    }
  }

  void _setupTypeInfo(int mask, bool test) {
    final bits = _bchTypeInfo(mask);
    for (var index = 0; index < 15; index++) {
      final dark = !test && ((bits >> index) & 1) == 1;
      if (index < 6) {
        _modules[index][8] = dark;
      } else if (index < 8) {
        _modules[index + 1][8] = dark;
      } else {
        _modules[moduleCount - 15 + index][8] = dark;
      }
      if (index < 8) {
        _modules[8][moduleCount - index - 1] = dark;
      } else if (index < 9) {
        _modules[8][15 - index] = dark;
      } else {
        _modules[8][14 - index] = dark;
      }
    }
    _modules[moduleCount - 8][8] = !test;
  }

  void _setupTypeNumber(bool test) {
    final bits = _bchTypeNumber(version);
    for (var index = 0; index < 18; index++) {
      final dark = !test && ((bits >> index) & 1) == 1;
      _modules[index ~/ 3][index % 3 + moduleCount - 11] = dark;
      _modules[index % 3 + moduleCount - 11][index ~/ 3] = dark;
    }
  }

  void _mapData(Uint8List bytes, int mask) {
    var direction = -1;
    var row = moduleCount - 1;
    var bitIndex = 7;
    var byteIndex = 0;
    for (var column = moduleCount - 1; column > 0; column -= 2) {
      if (column == 6) column--;
      for (;;) {
        for (var offset = 0; offset < 2; offset++) {
          final targetColumn = column - offset;
          if (_modules[row][targetColumn] != null) continue;
          var dark =
              byteIndex < bytes.length &&
              ((bytes[byteIndex] >> bitIndex) & 1) == 1;
          if (_mask(mask, row, targetColumn)) dark = !dark;
          _modules[row][targetColumn] = dark;
          bitIndex--;
          if (bitIndex < 0) {
            byteIndex++;
            bitIndex = 7;
          }
        }
        row += direction;
        if (row < 0 || row >= moduleCount) {
          row -= direction;
          direction = -direction;
          break;
        }
      }
    }
  }

  double _lostPoint() {
    var score = 0.0;
    for (var row = 0; row < moduleCount; row++) {
      for (var column = 0; column < moduleCount; column++) {
        var same = 0;
        final dark = isDark(row, column);
        for (var r = -1; r <= 1; r++) {
          for (var c = -1; c <= 1; c++) {
            if ((r == 0 && c == 0) ||
                row + r < 0 ||
                row + r >= moduleCount ||
                column + c < 0 ||
                column + c >= moduleCount) {
              continue;
            }
            if (dark == isDark(row + r, column + c)) same++;
          }
        }
        if (same > 5) score += 3 + same - 5;
      }
    }
    for (var row = 0; row < moduleCount - 1; row++) {
      for (var column = 0; column < moduleCount - 1; column++) {
        final count = [
          isDark(row, column),
          isDark(row + 1, column),
          isDark(row, column + 1),
          isDark(row + 1, column + 1),
        ].where((value) => value).length;
        if (count == 0 || count == 4) score += 3;
      }
    }
    for (var row = 0; row < moduleCount; row++) {
      for (var column = 0; column < moduleCount - 6; column++) {
        if (_finderLikeRow(row, column)) score += 40;
      }
    }
    for (var column = 0; column < moduleCount; column++) {
      for (var row = 0; row < moduleCount - 6; row++) {
        if (_finderLikeColumn(row, column)) score += 40;
      }
    }
    var darkCount = 0;
    for (var row = 0; row < moduleCount; row++) {
      for (var column = 0; column < moduleCount; column++) {
        if (isDark(row, column)) darkCount++;
      }
    }
    final ratio = (100 * darkCount / moduleCount / moduleCount - 50).abs() / 5;
    return score + ratio * 10;
  }

  bool _finderLikeRow(int row, int column) =>
      isDark(row, column) &&
      !isDark(row, column + 1) &&
      isDark(row, column + 2) &&
      isDark(row, column + 3) &&
      isDark(row, column + 4) &&
      !isDark(row, column + 5) &&
      isDark(row, column + 6);

  bool _finderLikeColumn(int row, int column) =>
      isDark(row, column) &&
      !isDark(row + 1, column) &&
      isDark(row + 2, column) &&
      isDark(row + 3, column) &&
      isDark(row + 4, column) &&
      !isDark(row + 5, column) &&
      isDark(row + 6, column);
}

class _BitBuffer extends Object with ListMixin<bool> {
  final List<int> _bytes = [];
  int _bitLength = 0;

  @override
  bool operator [](int index) =>
      ((_bytes[index ~/ 8] >> (7 - index % 8)) & 1) == 1;

  @override
  void operator []=(int index, bool value) =>
      throw UnsupportedError('QR buffers are append-only');

  @override
  int get length => _bitLength;

  @override
  set length(int value) => throw UnsupportedError('QR buffers are append-only');

  int byteAt(int index) => _bytes[index];

  void put(int number, int bitCount) {
    for (var index = 0; index < bitCount; index++) {
      putBit(((number >> (bitCount - index - 1)) & 1) == 1);
    }
  }

  void putBit(bool value) {
    final byteIndex = _bitLength ~/ 8;
    if (_bytes.length <= byteIndex) _bytes.add(0);
    if (value) _bytes[byteIndex] |= 0x80 >> (_bitLength % 8);
    _bitLength++;
  }
}

class _RsBlock {
  const _RsBlock(this.totalCount, this.dataCount);

  final int totalCount;
  final int dataCount;
}

Uint8List _createData(int version, Uint8List input) {
  final blocks = _rsBlocks(version);
  final buffer = _BitBuffer()
    ..put(4, 4)
    ..put(input.length, version < 10 ? 8 : 16);
  for (final byte in input) {
    buffer.put(byte, 8);
  }
  final totalDataCount = blocks.fold<int>(
    0,
    (sum, block) => sum + block.dataCount,
  );
  final totalBits = totalDataCount * 8;
  if (buffer.length + 4 <= totalBits) buffer.put(0, 4);
  while (buffer.length % 8 != 0) {
    buffer.putBit(false);
  }
  var padIndex = 0;
  while (buffer.length < totalBits) {
    buffer.put(padIndex.isEven ? 0xec : 0x11, 8);
    padIndex++;
  }
  return _createBytes(buffer, blocks);
}

Uint8List _createBytes(_BitBuffer buffer, List<_RsBlock> blocks) {
  var offset = 0;
  var maxDataCount = 0;
  var maxErrorCount = 0;
  final data = <Uint8List>[];
  final errors = <Uint8List>[];
  for (final block in blocks) {
    final errorCount = block.totalCount - block.dataCount;
    maxDataCount = math.max(maxDataCount, block.dataCount);
    maxErrorCount = math.max(maxErrorCount, errorCount);
    final dataBlock = Uint8List(block.dataCount);
    for (var index = 0; index < block.dataCount; index++) {
      dataBlock[index] = buffer.byteAt(offset + index) & 0xff;
    }
    offset += block.dataCount;
    data.add(dataBlock);
    final generator = _errorPolynomial(errorCount);
    final remainder = _Polynomial(
      dataBlock,
      generator.length - 1,
    ).mod(generator);
    final errorBlock = Uint8List(errorCount);
    for (var index = 0; index < errorCount; index++) {
      final remainderIndex = index + remainder.length - errorCount;
      errorBlock[index] = remainderIndex >= 0 ? remainder[remainderIndex] : 0;
    }
    errors.add(errorBlock);
  }
  final output = BytesBuilder(copy: false);
  for (var index = 0; index < maxDataCount; index++) {
    for (final block in data) {
      if (index < block.length) output.addByte(block[index]);
    }
  }
  for (var index = 0; index < maxErrorCount; index++) {
    for (final block in errors) {
      if (index < block.length) output.addByte(block[index]);
    }
  }
  return output.takeBytes();
}

class _Polynomial {
  _Polynomial(List<int> source, int shift) {
    var offset = 0;
    while (offset < source.length && source[offset] == 0) {
      offset++;
    }
    values = Uint8List(source.length - offset + shift);
    for (var index = 0; index < source.length - offset; index++) {
      values[index] = source[index + offset];
    }
  }

  late final Uint8List values;
  int get length => values.length;
  int operator [](int index) => values[index];

  _Polynomial multiply(_Polynomial other) {
    final result = Uint8List(length + other.length - 1);
    for (var left = 0; left < length; left++) {
      for (var right = 0; right < other.length; right++) {
        result[left + right] ^= _gexp(_glog(this[left]) + _glog(other[right]));
      }
    }
    return _Polynomial(result, 0);
  }

  _Polynomial mod(_Polynomial divisor) {
    if (length < divisor.length) return this;
    final ratio = _glog(this[0]) - _glog(divisor[0]);
    final result = Uint8List.fromList(values);
    for (var index = 0; index < divisor.length; index++) {
      result[index] ^= _gexp(_glog(divisor[index]) + ratio);
    }
    return _Polynomial(result, 0).mod(divisor);
  }
}

_Polynomial _errorPolynomial(int length) {
  var result = _Polynomial([1], 0);
  for (var index = 0; index < length; index++) {
    result = result.multiply(_Polynomial([1, _gexp(index)], 0));
  }
  return result;
}

final Uint8List _expTable = _createExpTable();
final Uint8List _logTable = _createLogTable();

int _glog(int value) =>
    value >= 1 ? _logTable[value] : throw ArgumentError('glog($value)');
int _gexp(int value) => _expTable[value % 255];

Uint8List _createExpTable() {
  final table = Uint8List(256);
  for (var index = 0; index < 8; index++) {
    table[index] = 1 << index;
  }
  for (var index = 8; index < 256; index++) {
    table[index] =
        table[index - 4] ^
        table[index - 5] ^
        table[index - 6] ^
        table[index - 8];
  }
  return table;
}

Uint8List _createLogTable() {
  final table = Uint8List(256);
  for (var index = 0; index < 255; index++) {
    table[_expTable[index]] = index;
  }
  return table;
}

List<_RsBlock> _rsBlocks(int version) {
  final row = _rsBlocksM[version - 1];
  final blocks = <_RsBlock>[];
  for (var index = 0; index < row.length; index += 3) {
    for (var count = 0; count < row[index]; count++) {
      blocks.add(_RsBlock(row[index + 1], row[index + 2]));
    }
  }
  return blocks;
}

bool _mask(int pattern, int row, int column) => switch (pattern) {
  0 => (row + column).isEven,
  1 => row.isEven,
  2 => column % 3 == 0,
  3 => (row + column) % 3 == 0,
  4 => ((row ~/ 2) + (column ~/ 3)).isEven,
  5 => (row * column) % 2 + (row * column) % 3 == 0,
  6 => ((row * column) % 2 + (row * column) % 3).isEven,
  7 => ((row * column) % 3 + (row + column) % 2).isEven,
  _ => throw ArgumentError.value(pattern, 'pattern'),
};

int _bchTypeInfo(int mask) {
  const generator =
      (1 << 10) | (1 << 8) | (1 << 5) | (1 << 4) | (1 << 2) | (1 << 1) | 1;
  const maskBits = (1 << 14) | (1 << 12) | (1 << 10) | (1 << 4) | (1 << 1);
  var value = mask << 10;
  while (_bchDigit(value) - _bchDigit(generator) >= 0) {
    value ^= generator << (_bchDigit(value) - _bchDigit(generator));
  }
  return ((mask << 10) | value) ^ maskBits;
}

int _bchTypeNumber(int version) {
  const generator =
      (1 << 12) |
      (1 << 11) |
      (1 << 10) |
      (1 << 9) |
      (1 << 8) |
      (1 << 5) |
      (1 << 2) |
      1;
  var value = version << 12;
  while (_bchDigit(value) - _bchDigit(generator) >= 0) {
    value ^= generator << (_bchDigit(value) - _bchDigit(generator));
  }
  return (version << 12) | value;
}

int _bchDigit(int value) {
  var result = 0;
  while (value != 0) {
    result++;
    value >>= 1;
  }
  return result;
}

const _patternPositions = <List<int>>[
  [],
  [6, 18],
  [6, 22],
  [6, 26],
  [6, 30],
  [6, 34],
  [6, 22, 38],
  [6, 24, 42],
  [6, 26, 46],
  [6, 28, 50],
  [6, 30, 54],
  [6, 32, 58],
  [6, 34, 62],
  [6, 26, 46, 66],
  [6, 26, 48, 70],
  [6, 26, 50, 74],
  [6, 30, 54, 78],
  [6, 30, 56, 82],
  [6, 30, 58, 86],
  [6, 34, 62, 90],
];

const _rsBlocksM = <List<int>>[
  [1, 26, 16],
  [1, 44, 28],
  [1, 70, 44],
  [2, 50, 32],
  [2, 67, 43],
  [4, 43, 27],
  [4, 49, 31],
  [2, 60, 38, 2, 61, 39],
  [3, 58, 36, 2, 59, 37],
  [4, 69, 43, 1, 70, 44],
  [1, 80, 50, 4, 81, 51],
  [6, 58, 36, 2, 59, 37],
  [8, 59, 37, 1, 60, 38],
  [4, 64, 40, 5, 65, 41],
  [5, 65, 41, 5, 66, 42],
  [7, 73, 45, 3, 74, 46],
  [10, 74, 46, 1, 75, 47],
  [9, 69, 43, 4, 70, 44],
  [3, 70, 44, 11, 71, 45],
  [3, 67, 41, 13, 68, 42],
];
