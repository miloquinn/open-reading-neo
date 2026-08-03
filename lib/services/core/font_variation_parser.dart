// 文件说明：只读解析 OpenType/TrueType 变量字体的 fvar/wght 轴范围。
// 技术要点：大端 SFNT 表目录、16.16 Fixed 数值、严格边界检查；不修改字体字节。

import 'dart:typed_data';

typedef FontWeightAxisRange = ({int min, int max});

FontWeightAxisRange? parseVariableFontWeightRange(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final data = ByteData.sublistView(bytes);

  try {
    final tableCount = data.getUint16(4, Endian.big);
    const tableDirectoryOffset = 12;
    const tableRecordSize = 16;
    if (tableCount <= 0 || tableCount > 4096) return null;
    if (tableDirectoryOffset + tableCount * tableRecordSize > bytes.length) {
      return null;
    }

    int? fvarOffset;
    int? fvarLength;
    for (var index = 0; index < tableCount; index++) {
      final recordOffset = tableDirectoryOffset + index * tableRecordSize;
      final tag = String.fromCharCodes(
        bytes.sublist(recordOffset, recordOffset + 4),
      );
      if (tag != 'fvar') continue;
      fvarOffset = data.getUint32(recordOffset + 8, Endian.big);
      fvarLength = data.getUint32(recordOffset + 12, Endian.big);
      break;
    }
    if (fvarOffset == null || fvarLength == null || fvarLength < 16) {
      return null;
    }
    final fvarEnd = fvarOffset + fvarLength;
    if (fvarOffset < 0 || fvarEnd > bytes.length) return null;

    final axesOffset = data.getUint16(fvarOffset + 4, Endian.big);
    final axisCount = data.getUint16(fvarOffset + 8, Endian.big);
    final axisSize = data.getUint16(fvarOffset + 10, Endian.big);
    if (axisCount <= 0 || axisCount > 256 || axisSize < 20) return null;

    final axesStart = fvarOffset + axesOffset;
    if (axesStart < fvarOffset || axesStart + axisCount * axisSize > fvarEnd) {
      return null;
    }
    for (var index = 0; index < axisCount; index++) {
      final axisOffset = axesStart + index * axisSize;
      final tag = String.fromCharCodes(
        bytes.sublist(axisOffset, axisOffset + 4),
      );
      if (tag != 'wght') continue;
      final min = _fixed16Dot16(data.getInt32(axisOffset + 4, Endian.big));
      final max = _fixed16Dot16(data.getInt32(axisOffset + 12, Endian.big));
      if (!min.isFinite || !max.isFinite || min > max) return null;
      return (min: min.round(), max: max.round());
    }
  } on RangeError {
    return null;
  }
  return null;
}

double _fixed16Dot16(int raw) => raw / 65536.0;
