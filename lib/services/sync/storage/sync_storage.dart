import 'dart:io';

typedef SyncStorageProvider = Future<SyncStorage?> Function();

/// A validated, provider-neutral object key relative to a sync space root.
final class SyncPath implements Comparable<SyncPath> {
  SyncPath._(this.value);

  factory SyncPath(String value) {
    final normalized = value.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized.endsWith('/') ||
        normalized.contains('://') ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      throw ArgumentError.value(value, 'value', 'Invalid sync object path.');
    }
    return SyncPath._(normalized);
  }

  final String value;

  SyncPath child(String segment) => SyncPath('$value/$segment');

  @override
  int compareTo(SyncPath other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is SyncPath && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class SyncObjectVersion {
  const SyncObjectVersion(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is SyncObjectVersion && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class SyncStorageCapabilities {
  const SyncStorageCapabilities({required this.strongVersions});

  final bool strongVersions;
}

final class SyncObjectInfo {
  const SyncObjectInfo({
    required this.path,
    required this.version,
    required this.length,
    this.contentType,
  });

  final SyncPath path;
  final SyncObjectVersion version;
  final int length;
  final String? contentType;
}

final class SyncTextRead {
  const SyncTextRead({required this.text, required this.info});

  final String text;
  final SyncObjectInfo info;
}

final class SyncDownload {
  const SyncDownload({required this.info});

  final SyncObjectInfo info;
}

final class SyncWrite {
  const SyncWrite({required this.info});

  final SyncObjectInfo info;
}

final class SyncListing {
  const SyncListing({required this.objects, required this.prefixes});

  final List<SyncObjectInfo> objects;
  final List<SyncPath> prefixes;
}

enum SyncStorageErrorCode {
  authentication,
  permissionDenied,
  notFound,
  versionConflict,
  rateLimited,
  storageFull,
  timeout,
  network,
  tls,
  unsupported,
  invalidData,
  serverError,
}

final class SyncStorageException implements Exception {
  const SyncStorageException(this.code, this.message, {this.cause});

  final SyncStorageErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'SyncStorageException($code): $message';
}

abstract interface class SyncStorage {
  SyncStorageCapabilities get capabilities;

  /// Stable identity for isolating local cursors and pending jobs by space.
  String get spaceKey;

  /// Server time observed from the latest response, when exposed by provider.
  DateTime? get serverDate;

  /// Lists immediate objects and common prefixes below [prefix]. Adapters
  /// exhaust provider pagination internally.
  Future<SyncListing> list(SyncPath prefix);

  Future<SyncObjectInfo?> stat(SyncPath path);

  Future<SyncTextRead> readText(
    SyncPath path, {
    SyncObjectVersion? expectedVersion,
  });

  Future<SyncDownload> download(
    SyncPath path,
    IOSink destination, {
    SyncObjectVersion? expectedVersion,
  });

  Future<SyncWrite> create(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
  });

  Future<SyncWrite> compareAndSwap(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
    required SyncObjectVersion expectedVersion,
  });

  Future<void> delete(
    SyncPath path, {
    required SyncObjectVersion expectedVersion,
  });
}
