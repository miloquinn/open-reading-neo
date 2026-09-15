enum WebDavSyncStatus {
  unconfigured,
  idle,
  testing,
  syncing,
  success,
  partialFailure,
  failed,
}

enum WebDavSyncPhase {
  none,
  connecting,
  scanningLocal,
  readingRemote,
  applyingRemote,
  uploadingLocal,
  finishing,
}

enum WebDavSyncErrorCode {
  invalidConfiguration,
  insecureConnection,
  authentication,
  permissionDenied,
  notFound,
  conflict,
  serverIncompatible,
  serverError,
  storageFull,
  rateLimited,
  timeout,
  tls,
  network,
  corruptRemoteData,
  localDataCorrupt,
  clockSkew,
  secureStorage,
  unknown,
}

enum WebDavNewBookUploadPolicy {
  askEveryTime('ask'),
  automatic('automatic'),
  manual('manual');

  const WebDavNewBookUploadPolicy(this.storageValue);

  final String storageValue;

  static WebDavNewBookUploadPolicy fromStorage(String? value) {
    for (final policy in values) {
      if (policy.storageValue == value) return policy;
    }
    return askEveryTime;
  }
}

class WebDavSyncFailure implements Exception {
  const WebDavSyncFailure(
    this.code,
    this.message, {
    this.statusCode,
    this.requestMethod,
    this.resourcePath,
  });

  final WebDavSyncErrorCode code;
  final String message;
  final int? statusCode;
  final String? requestMethod;

  /// Only the URI path, never its user info, query, headers or response body.
  final String? resourcePath;

  WebDavSyncFailure withRequest(String method, Uri uri) => WebDavSyncFailure(
    code,
    message,
    statusCode: statusCode,
    requestMethod: requestMethod ?? method,
    resourcePath: resourcePath ?? uri.path,
  );

  @override
  String toString() => [
    'WebDavSyncFailure(${code.name}): $message',
    if (statusCode != null) 'HTTP $statusCode',
    if (requestMethod != null) 'method=$requestMethod',
    if (resourcePath != null) 'path=$resourcePath',
  ].join('; ');
}

class WebDavSyncConfigDraft {
  const WebDavSyncConfigDraft({
    required this.serverUrl,
    required this.username,
    required this.password,
    this.rootPath = 'OpenReading',
    this.allowInsecurePrivateHttp = false,
  });

  final String serverUrl;
  final String username;
  final String password;
  final String rootPath;
  final bool allowInsecurePrivateHttp;

  WebDavSyncConfiguration withoutPassword({
    bool autoSync = true,
    WebDavSyncFrequency? frequency,
  }) => WebDavSyncConfiguration(
    serverUrl: serverUrl,
    username: username,
    rootPath: rootPath,
    allowInsecurePrivateHttp: allowInsecurePrivateHttp,
    autoSync: autoSync,
    frequency: frequency,
  );
}

enum WebDavSyncFrequency {
  off,
  onChange,
  every15Minutes,
  hourly,
  daily;

  Duration? get interval => switch (this) {
    every15Minutes => const Duration(minutes: 15),
    hourly => const Duration(hours: 1),
    daily => const Duration(days: 1),
    _ => null,
  };

  static WebDavSyncFrequency fromJson(
    Object? value, {
    required bool legacyEnabled,
  }) =>
      values.where((item) => item.name == value).firstOrNull ??
      (legacyEnabled ? onChange : off);
}

class WebDavSyncConfiguration {
  const WebDavSyncConfiguration({
    required this.serverUrl,
    required this.username,
    this.rootPath = 'OpenReading',
    this.allowInsecurePrivateHttp = false,
    bool autoSync = true,
    WebDavSyncFrequency? frequency,
  }) : frequency =
           frequency ??
           (autoSync ? WebDavSyncFrequency.onChange : WebDavSyncFrequency.off);

  final String serverUrl;
  final String username;
  final String rootPath;
  final bool allowInsecurePrivateHttp;
  final WebDavSyncFrequency frequency;
  bool get autoSync => frequency != WebDavSyncFrequency.off;

  Map<String, Object?> toJson() => {
    'server_url': serverUrl,
    'username': username,
    'root_path': rootPath,
    'allow_insecure_private_http': allowInsecurePrivateHttp,
    'auto_sync': autoSync,
    'sync_frequency': frequency.name,
  };

  factory WebDavSyncConfiguration.fromJson(Map<String, dynamic> json) =>
      WebDavSyncConfiguration(
        serverUrl: json['server_url'] as String,
        username: json['username'] as String,
        rootPath: json['root_path'] as String? ?? 'OpenReading',
        allowInsecurePrivateHttp:
            json['allow_insecure_private_http'] as bool? ?? false,
        frequency: WebDavSyncFrequency.fromJson(
          json['sync_frequency'],
          legacyEnabled: json['auto_sync'] as bool? ?? true,
        ),
      );

  WebDavSyncConfiguration copyWith({
    String? serverUrl,
    String? username,
    String? rootPath,
    bool? allowInsecurePrivateHttp,
    bool? autoSync,
    WebDavSyncFrequency? frequency,
  }) => WebDavSyncConfiguration(
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    rootPath: rootPath ?? this.rootPath,
    allowInsecurePrivateHttp:
        allowInsecurePrivateHttp ?? this.allowInsecurePrivateHttp,
    frequency:
        frequency ??
        (autoSync == false
            ? WebDavSyncFrequency.off
            : autoSync == true && !this.autoSync
            ? WebDavSyncFrequency.onChange
            : this.frequency),
  );
}

class WebDavSyncScope {
  const WebDavSyncScope({
    this.bookSources = true,
    this.books = true,
    this.progress = true,
    this.bookmarks = true,
    this.notes = false,
    this.readingSessions = true,
    this.readerSettings = true,
    this.replaceRules = false,
    this.bookFiles = false,
  });

  final bool bookSources;
  final bool books;
  final bool progress;
  final bool bookmarks;
  final bool notes;
  final bool readingSessions;
  final bool readerSettings;
  final bool replaceRules;
  final bool bookFiles;

  Map<String, Object?> toJson() => {
    'book_sources': bookSources,
    'books': books,
    'progress': progress,
    'bookmarks': bookmarks,
    'notes': notes,
    'reading_sessions': readingSessions,
    'reader_settings': readerSettings,
    'replace_rules': replaceRules,
    'book_files': bookFiles,
  };

  factory WebDavSyncScope.fromJson(Map<String, dynamic> json) =>
      WebDavSyncScope(
        bookSources: json['book_sources'] as bool? ?? true,
        books: json['books'] as bool? ?? true,
        progress: json['progress'] as bool? ?? true,
        bookmarks: json['bookmarks'] as bool? ?? true,
        notes: json['notes'] as bool? ?? false,
        readingSessions: json['reading_sessions'] as bool? ?? true,
        readerSettings: json['reader_settings'] as bool? ?? true,
        replaceRules: json['replace_rules'] as bool? ?? false,
        bookFiles: json['book_files'] as bool? ?? false,
      );

  WebDavSyncScope copyWith({
    bool? bookSources,
    bool? books,
    bool? progress,
    bool? bookmarks,
    bool? notes,
    bool? readingSessions,
    bool? readerSettings,
    bool? replaceRules,
    bool? bookFiles,
  }) => WebDavSyncScope(
    bookSources: bookSources ?? this.bookSources,
    books: books ?? this.books,
    progress: progress ?? this.progress,
    bookmarks: bookmarks ?? this.bookmarks,
    notes: notes ?? this.notes,
    readingSessions: readingSessions ?? this.readingSessions,
    readerSettings: readerSettings ?? this.readerSettings,
    replaceRules: replaceRules ?? this.replaceRules,
    bookFiles: bookFiles ?? this.bookFiles,
  );
}

class ConnectionTestResult {
  const ConnectionTestResult({
    required this.success,
    this.supportsEtag = false,
    this.supportsMove = false,
    this.serverDate,
    this.errorCode,
    this.message,
    this.failure,
  });

  final bool success;
  final bool supportsEtag;
  final bool supportsMove;
  final DateTime? serverDate;
  final WebDavSyncErrorCode? errorCode;
  final String? message;
  final WebDavSyncFailure? failure;
}

class WebDavSyncRunResult {
  const WebDavSyncRunResult({
    required this.uploaded,
    required this.downloaded,
    required this.skipped,
    required this.conflictsResolved,
    required this.completedAt,
  });

  final int uploaded;
  final int downloaded;
  final int skipped;
  final int conflictsResolved;
  final DateTime completedAt;
}

class SyncFileCapabilities {
  const SyncFileCapabilities({
    this.metadataSyncSupported = true,
    this.uploadSupported = true,
    this.downloadSupported = true,
    this.reason = '',
  });

  final bool metadataSyncSupported;
  final bool uploadSupported;
  final bool downloadSupported;
  final String reason;
}

class RemoteBookDescriptor {
  const RemoteBookDescriptor({
    required this.bookUid,
    required this.title,
    required this.author,
    required this.format,
    this.fileAvailable = false,
    this.sizeBytes,
    this.blobSha256,
    this.remotePath,
    this.fileName,
    this.sourceId,
    this.sourceBookId,
    this.coverAvailable = false,
    this.coverSizeBytes,
    this.coverBlobSha256,
    this.coverRemotePath,
    this.coverFileName,
  });

  final String bookUid;
  final String title;
  final String author;
  final String format;
  final bool fileAvailable;
  final int? sizeBytes;
  final String? blobSha256;
  final String? remotePath;
  final String? fileName;
  final String? sourceId;
  final String? sourceBookId;
  final bool coverAvailable;
  final int? coverSizeBytes;
  final String? coverBlobSha256;
  final String? coverRemotePath;
  final String? coverFileName;
}

class BookFileTransferProgress {
  const BookFileTransferProgress({
    required this.transferredBytes,
    required this.totalBytes,
  });

  final int transferredBytes;
  final int totalBytes;

  double get fraction =>
      totalBytes <= 0 ? 0 : (transferredBytes / totalBytes).clamp(0, 1);
}
