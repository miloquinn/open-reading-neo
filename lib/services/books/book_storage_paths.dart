// 文件说明：书籍受管存储路径的持久化编解码器。
// 技术要点：数据库保存稳定相对路径，运行时映射到当前 Documents 根目录。

import 'package:path/path.dart' as p;

/// Converts managed book paths between stable database and runtime forms.
///
/// Only files below `books/` and `covers/` are managed. All other values are
/// passed through unchanged so external files and virtual URI schemes retain
/// their original meaning.
class BookStoragePaths {
  BookStoragePaths(String documentsPath)
    : _context = _contextFor(documentsPath),
      _documentsPath = _contextFor(documentsPath).normalize(documentsPath);

  final p.Context _context;
  final String _documentsPath;

  /// Whether decoding this persisted value requires a current Documents root.
  static bool needsResolution(String value) {
    return _isCanonicalManagedRelative(value) ||
        _legacyIosRelativePath(value) != null;
  }

  /// Encodes a managed absolute path as `books/...` or `covers/...`.
  String encode(String path) {
    if (_isCanonicalManagedRelative(path)) return path;

    final currentRelative = _relativeToCurrentDocuments(path);
    if (currentRelative != null) return currentRelative;

    final legacyRelative = _legacyIosRelative(path);
    if (legacyRelative != null) return legacyRelative;

    return path;
  }

  /// Decodes a managed or legacy database path against this Documents root.
  String decode(String path) {
    final encoded = encode(path);
    if (!_isCanonicalManagedRelative(encoded)) return path;
    return _context.joinAll(<String>[_documentsPath, ...encoded.split('/')]);
  }

  /// Encodes only the path-bearing columns of a book database row.
  Map<String, dynamic> encodeBookMap(Map<String, dynamic> row) {
    return _mapBookPaths(row, encode);
  }

  /// Decodes only the path-bearing columns of a book database row.
  Map<String, dynamic> decodeBookMap(Map<String, dynamic> row) {
    return _mapBookPaths(row, decode);
  }

  Map<String, dynamic> _mapBookPaths(
    Map<String, dynamic> row,
    String Function(String) convert,
  ) {
    final mapped = Map<String, dynamic>.from(row);
    for (final key in const <String>['filePath', 'cover_image_path']) {
      final value = mapped[key];
      if (value is String) mapped[key] = convert(value);
    }
    return mapped;
  }

  String? _relativeToCurrentDocuments(String path) {
    if (!_context.isAbsolute(path) || _containsTraversal(path, _context)) {
      return null;
    }

    final normalized = _context.normalize(path);
    if (!_isAtOrWithin(normalized, _documentsPath)) return null;

    final relative = _context.relative(normalized, from: _documentsPath);
    final storagePath = _context.style == p.Style.windows
        ? relative.replaceAll('\\', '/')
        : relative;
    return _isCanonicalManagedRelative(storagePath) ? storagePath : null;
  }

  String? _legacyIosRelative(String path) {
    return _legacyIosRelativePath(path);
  }

  static String? _legacyIosRelativePath(String path) {
    if (!p.posix.isAbsolute(path) || _containsTraversal(path, p.posix)) {
      return null;
    }
    if (path.contains('//')) return null;

    final segments = path.split('/').skip(1).toList(growable: false);
    final deviceOffset = segments.firstOrNull == 'private' ? 1 : 0;
    final isDevicePath =
        segments.length >= deviceOffset + 9 &&
        _matchesAt(segments, deviceOffset, const <String>[
          'var',
          'mobile',
          'Containers',
          'Data',
          'Application',
        ]) &&
        _isUuid(segments[deviceOffset + 5]) &&
        segments[deviceOffset + 6] == 'Documents';
    if (isDevicePath) {
      return _validatedRelative(segments.skip(deviceOffset + 7));
    }

    final isSimulatorPath =
        segments.length >= 15 &&
        segments[0] == 'Users' &&
        segments[1].isNotEmpty &&
        _matchesAt(segments, 2, const <String>[
          'Library',
          'Developer',
          'CoreSimulator',
          'Devices',
        ]) &&
        _isUuid(segments[6]) &&
        _matchesAt(segments, 7, const <String>[
          'data',
          'Containers',
          'Data',
          'Application',
        ]) &&
        _isUuid(segments[11]) &&
        segments[12] == 'Documents';
    if (isSimulatorPath) {
      return _validatedRelative(segments.skip(13));
    }

    return null;
  }

  static String? _validatedRelative(Iterable<String> segments) {
    final relative = segments.join('/');
    return _isCanonicalManagedRelative(relative) ? relative : null;
  }

  static bool _matchesAt(
    List<String> actual,
    int offset,
    List<String> expected,
  ) {
    if (actual.length < offset + expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (actual[offset + i] != expected[i]) return false;
    }
    return true;
  }

  static bool _isUuid(String value) {
    if (value.length != 36) return false;
    for (var i = 0; i < value.length; i++) {
      if (i == 8 || i == 13 || i == 18 || i == 23) {
        if (value.codeUnitAt(i) != 0x2d) return false;
        continue;
      }
      final code = value.codeUnitAt(i);
      final isDigit = code >= 0x30 && code <= 0x39;
      final isLowerHex = code >= 0x61 && code <= 0x66;
      final isUpperHex = code >= 0x41 && code <= 0x46;
      if (!isDigit && !isLowerHex && !isUpperHex) return false;
    }
    return true;
  }

  bool _isAtOrWithin(String path, String parent) {
    if (_context.style != p.Style.windows) {
      return path == parent || _context.isWithin(parent, path);
    }
    final foldedPath = path.toLowerCase();
    final foldedParent = parent.toLowerCase();
    final separator = _context.separator;
    return foldedPath == foldedParent ||
        foldedPath.startsWith('$foldedParent$separator');
  }

  static bool _containsTraversal(String path, p.Context context) {
    return context
        .split(path)
        .any((segment) => segment == '.' || segment == '..');
  }

  static bool _isCanonicalManagedRelative(String path) {
    if (path.isEmpty || path.contains('\\')) return false;
    final segments = path.split('/');
    if (segments.length < 2 ||
        (segments.first != 'books' && segments.first != 'covers')) {
      return false;
    }
    return segments.every(
      (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
    );
  }

  static p.Context _contextFor(String documentsPath) {
    final hasDrivePrefix =
        documentsPath.length >= 3 &&
        _isAsciiLetter(documentsPath.codeUnitAt(0)) &&
        documentsPath.codeUnitAt(1) == 0x3a &&
        (documentsPath.codeUnitAt(2) == 0x5c ||
            documentsPath.codeUnitAt(2) == 0x2f);
    final isWindows = hasDrivePrefix || documentsPath.startsWith(r'\\');
    return p.Context(style: isWindows ? p.Style.windows : p.Style.posix);
  }

  static bool _isAsciiLetter(int code) {
    return (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
  }
}
