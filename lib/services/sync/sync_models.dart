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

  WebDavSyncConfiguration withoutPassword() => WebDavSyncConfiguration(
    serverUrl: serverUrl,
    username: username,
    rootPath: rootPath,
    allowInsecurePrivateHttp: allowInsecurePrivateHttp,
  );
}

class WebDavSyncConfiguration {
  const WebDavSyncConfiguration({
    required this.serverUrl,
    required this.username,
    this.rootPath = 'OpenReading',
    this.allowInsecurePrivateHttp = false,
  });

  final String serverUrl;
  final String username;
  final String rootPath;
  final bool allowInsecurePrivateHttp;

  Map<String, Object?> toJson() => {
    'server_url': serverUrl,
    'username': username,
    'root_path': rootPath,
    'allow_insecure_private_http': allowInsecurePrivateHttp,
  };

  factory WebDavSyncConfiguration.fromJson(Map<String, dynamic> json) =>
      WebDavSyncConfiguration(
        serverUrl: json['server_url'] as String,
        username: json['username'] as String,
        rootPath: json['root_path'] as String? ?? 'OpenReading',
        allowInsecurePrivateHttp:
            json['allow_insecure_private_http'] as bool? ?? false,
      );

  WebDavSyncConfiguration copyWith({
    String? serverUrl,
    String? username,
    String? rootPath,
    bool? allowInsecurePrivateHttp,
  }) => WebDavSyncConfiguration(
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    rootPath: rootPath ?? this.rootPath,
    allowInsecurePrivateHttp:
        allowInsecurePrivateHttp ?? this.allowInsecurePrivateHttp,
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
