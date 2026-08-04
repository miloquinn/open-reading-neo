import 'dart:typed_data';

import 'source_config.dart';

class SourceScriptContext {
  const SourceScriptContext({
    required this.source,
    this.result,
    this.baseUrl,
    this.variables = const {},
    this.book = const {},
    this.chapter = const {},
    this.bookWriter,
    this.chapterWriter,
    this.networkHandler,
    this.cookieReader,
    this.cookieWriter,
    this.cookieRemover,
    this.loginInfo = const {},
    this.loginHeaders = const {},
    this.loginInfoWriter,
    this.loginHeaderWriter,
    this.interactionHandler,
  });

  final ReadingSourceConfig source;
  final Object? result;
  final Uri? baseUrl;
  final Map<String, String> variables;
  final Map<String, Object?> book;
  final Map<String, Object?> chapter;
  final void Function(Map<String, Object?> value)? bookWriter;
  final void Function(Map<String, Object?> value)? chapterWriter;
  final Future<SourceScriptNetworkResult> Function(
    SourceScriptNetworkRequest request,
  )?
  networkHandler;
  final String Function(Uri uri)? cookieReader;
  final void Function(Uri uri, String cookie)? cookieWriter;
  final void Function(Uri uri)? cookieRemover;
  final Map<String, String> loginInfo;
  final Map<String, String> loginHeaders;
  final void Function(Map<String, String> value)? loginInfoWriter;
  final void Function(Map<String, String> value)? loginHeaderWriter;
  final Future<SourceScriptInteractionResult> Function(
    SourceScriptInteractionRequest request,
  )?
  interactionHandler;

  SourceScriptContext copyWith({
    Object? result,
    Uri? baseUrl,
    Map<String, String>? variables,
    Map<String, Object?>? book,
    Map<String, Object?>? chapter,
    void Function(Map<String, Object?> value)? bookWriter,
    void Function(Map<String, Object?> value)? chapterWriter,
  }) => SourceScriptContext(
    source: source,
    result: result ?? this.result,
    baseUrl: baseUrl ?? this.baseUrl,
    variables: variables ?? this.variables,
    book: book ?? this.book,
    chapter: chapter ?? this.chapter,
    bookWriter: bookWriter ?? this.bookWriter,
    chapterWriter: chapterWriter ?? this.chapterWriter,
    networkHandler: networkHandler,
    cookieReader: cookieReader,
    cookieWriter: cookieWriter,
    cookieRemover: cookieRemover,
    loginInfo: loginInfo,
    loginHeaders: loginHeaders,
    loginInfoWriter: loginInfoWriter,
    loginHeaderWriter: loginHeaderWriter,
    interactionHandler: interactionHandler,
  );
}

enum SourceScriptInteractionKind { browser, browserAwait, verificationCode }

class SourceScriptInteractionRequest {
  const SourceScriptInteractionRequest({
    required this.signature,
    required this.kind,
    required this.url,
    this.title = '',
    this.html,
    this.refetchAfterSuccess = false,
    this.headers = const {},
    this.imageBytes,
  });

  final String signature;
  final SourceScriptInteractionKind kind;
  final String url;
  final String title;
  final String? html;
  final bool refetchAfterSuccess;
  final Map<String, String> headers;
  final Uint8List? imageBytes;

  SourceScriptInteractionRequest copyWith({
    Map<String, String>? headers,
    Uint8List? imageBytes,
  }) => SourceScriptInteractionRequest(
    signature: signature,
    kind: kind,
    url: url,
    title: title,
    html: html,
    refetchAfterSuccess: refetchAfterSuccess,
    headers: headers ?? this.headers,
    imageBytes: imageBytes ?? this.imageBytes,
  );
}

class SourceScriptInteractionResult {
  const SourceScriptInteractionResult({
    this.value = '',
    this.body = '',
    this.finalUrl = '',
    this.cookieHeader,
    this.cancelled = false,
    this.error,
  });

  final String value;
  final String body;
  final String finalUrl;
  final String? cookieHeader;
  final bool cancelled;
  final String? error;

  Map<String, Object?> toJson() => {
    'value': value,
    'body': body,
    'finalUrl': finalUrl,
    'cookieHeader': cookieHeader,
    'cancelled': cancelled,
    'error': error,
  };
}

class SourceScriptNetworkResult {
  const SourceScriptNetworkResult({
    required this.body,
    required this.finalUrl,
    this.statusCode = 200,
    this.headers = const {},
    this.cookies = const {},
  });

  final String body;
  final String finalUrl;
  final int statusCode;
  final Map<String, String> headers;
  final Map<String, String> cookies;

  Map<String, Object?> toJson() => {
    'body': body,
    'finalUrl': finalUrl,
    'statusCode': statusCode,
    'headers': headers,
    'cookies': cookies,
  };
}

class SourceScriptNetworkRequest {
  const SourceScriptNetworkRequest({
    required this.signature,
    required this.method,
    required this.url,
    this.body,
    this.headers = const {},
    this.webJs,
  });

  final String signature;
  final String method;
  final String url;
  final String? body;
  final Map<String, String> headers;
  final String? webJs;
}

abstract class SourceScriptEvaluator {
  Object? evaluate(String script, SourceScriptContext context);

  Future<Object?> evaluateAsync(
    String script,
    SourceScriptContext context,
  ) async => evaluate(script, context);

  void dispose();
}
