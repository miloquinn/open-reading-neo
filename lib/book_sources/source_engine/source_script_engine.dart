import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';

import '../protocol/book_source_protocol.dart';
import 'source_script_bootstrap.dart';
import 'source_script_contract.dart';
import 'source_script_host_api.dart';
import 'source_script_state.dart';

export 'source_script_contract.dart';

class QuickJsSourceScriptEvaluator implements SourceScriptEvaluator {
  QuickJsSourceScriptEvaluator({JavascriptRuntime? runtime})
    : _runtime = runtime ?? getJavascriptRuntime(xhr: false),
      _host = SourceScriptHostApi() {
    _runtime.onMessage(sourceScriptHostChannel, _host.handle);
  }

  final JavascriptRuntime _runtime;
  final SourceScriptHostApi _host;
  Future<void> _evaluationTail = Future<void>.value();

  @override
  Object? evaluate(String script, SourceScriptContext context) {
    return _evaluateAttempt(script, context, const {});
  }

  @override
  Future<Object?> evaluateAsync(String script, SourceScriptContext context) {
    final previous = _evaluationTail;
    final operation = () async {
      try {
        await previous;
      } on Object {
        // A failed script must not poison the queue for later sources.
      }
      return _evaluateAsyncLocked(script, context);
    }();
    _evaluationTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<Object?> _evaluateAsyncLocked(
    String script,
    SourceScriptContext context,
  ) async {
    final networkResponses = <String, SourceScriptNetworkResult>{};
    final interactionResponses = <String, SourceScriptInteractionResult>{};
    var networkCount = 0;
    var interactionCount = 0;
    for (var replayCount = 0; replayCount < 24; replayCount++) {
      try {
        return _evaluateAttempt(
          script,
          context,
          networkResponses,
          interactionResponses,
        );
      } on _SourceNetworkNeeded catch (pending) {
        if (++networkCount > 12) {
          throw const BookSourceProtocolException(
            'Source script exceeded the network request limit.',
          );
        }
        final handler = context.networkHandler;
        if (handler == null) {
          throw const BookSourceProtocolException(
            'This source script requested network access outside a source operation.',
          );
        }
        networkResponses[pending.request.signature] = await handler(
          pending.request,
        );
      } on _SourceInteractionNeeded catch (pending) {
        if (++interactionCount > 4) {
          throw const BookSourceProtocolException(
            'Source script exceeded the user interaction limit.',
          );
        }
        final handler = context.interactionHandler;
        if (handler == null) {
          throw const BookSourceProtocolException(
            'This source requires an interactive verification screen.',
          );
        }
        final result = await handler(pending.request);
        if (result.cancelled) {
          throw const BookSourceProtocolException(
            'Reading source verification was cancelled.',
          );
        }
        if (result.error?.isNotEmpty == true) {
          throw BookSourceProtocolException(result.error!);
        }
        interactionResponses[pending.request.signature] = result;
      }
    }
    throw const BookSourceProtocolException(
      'Source script exceeded the replay limit.',
    );
  }

  Object? _evaluateAttempt(
    String script,
    SourceScriptContext context,
    Map<String, SourceScriptNetworkResult> networkResponses, [
    Map<String, SourceScriptInteractionResult> interactionResponses = const {},
  ]) {
    final state = _host.beginInvocation(
      context,
      networkResponses,
      interactionResponses,
    );
    try {
      final payload = SourceScriptBootstrap.payload(script, context, state);
      final evaluated = _runtime.evaluate(SourceScriptBootstrap.build(payload));
      if (evaluated.isError) {
        final pending = sourceScriptNetworkRequestFromError(
          evaluated.stringResult,
        );
        if (pending != null) throw _SourceNetworkNeeded(pending);
        final interaction = sourceScriptInteractionRequestFromError(
          evaluated.stringResult,
        );
        if (interaction != null) throw _SourceInteractionNeeded(interaction);
        throw BookSourceProtocolException(
          'Reading source JavaScript failed: ${evaluated.stringResult}',
        );
      }
      return _decodeEnvelope(evaluated.stringResult, context, state);
    } finally {
      _host.endInvocation();
    }
  }

  Object? _decodeEnvelope(
    String result,
    SourceScriptContext context,
    SourceScriptState state,
  ) {
    try {
      final envelope = jsonDecode(result);
      if (envelope is! Map) {
        throw const FormatException('Script result envelope is not an object.');
      }
      state.variable = '${envelope['sourceVariable'] ?? ''}';
      if (envelope['sourceValues'] case final Map sourceValues) {
        state.values = sourceValues.map(
          (key, value) => MapEntry('$key', '${value ?? ''}'),
        );
      }
      if (envelope['loginInfo'] case final Map loginInfo) {
        final normalized = loginInfo.map(
          (key, value) => MapEntry('$key', '${value ?? ''}'),
        );
        if (context.loginInfoWriter != null) {
          context.loginInfoWriter!(normalized);
        } else {
          state.loginInfo = normalized;
        }
      }
      if (envelope['loginHeaders'] case final Map loginHeaders) {
        final normalized = loginHeaders.map(
          (key, value) => MapEntry('$key', '${value ?? ''}'),
        );
        if (context.loginHeaderWriter != null) {
          context.loginHeaderWriter!(normalized);
        } else {
          state.loginHeaders = normalized;
        }
      }
      if (envelope['state'] case final Map javaState) {
        state.javaState = javaState.map(
          (key, value) => MapEntry('$key', value),
        );
      }
      if (envelope['book'] case final Map book) {
        context.bookWriter?.call(
          book.map((key, value) => MapEntry('$key', value)),
        );
      }
      if (envelope['chapter'] case final Map chapter) {
        context.chapterWriter?.call(
          chapter.map((key, value) => MapEntry('$key', value)),
        );
      }
      return envelope['value'];
    } on FormatException catch (error) {
      throw BookSourceProtocolException(
        'Reading source JavaScript returned invalid data: ${error.message}',
      );
    }
  }

  @override
  void dispose() => _runtime.dispose();
}

class _SourceNetworkNeeded implements Exception {
  const _SourceNetworkNeeded(this.request);

  final SourceScriptNetworkRequest request;
}

class _SourceInteractionNeeded implements Exception {
  const _SourceInteractionNeeded(this.request);

  final SourceScriptInteractionRequest request;
}
