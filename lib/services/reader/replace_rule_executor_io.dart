import 'dart:async';
import 'dart:isolate';

import 'replace_rule_execution.dart';
import 'replace_rule_semantics.dart';

/// Long-lived, killable replacement worker for native Dart runtimes.
///
/// A watchdog owns the isolate handle. If a regular expression stops making
/// progress, the complete isolate is terminated immediately, the last-started
/// rule is quarantined for the current rules signature, and the batch is
/// replayed atomically on a fresh worker. No partial transformation is exposed.
class ReplaceRuleExecutor {
  ReplaceRuleExecutor({Duration? timeout, this.maximumTimeoutRetries = 2})
    : timeout = timeout ?? const Duration(milliseconds: 1500);

  final Duration timeout;
  final int maximumTimeoutRetries;
  final StreamController<ReplaceRuleDiagnostic> _diagnostics =
      StreamController<ReplaceRuleDiagnostic>.broadcast(sync: true);
  final Map<String, Set<String>> _quarantined = <String, Set<String>>{};
  final Set<String> _knownWorkerSignatures = <String>{};

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  ReceivePort? _errors;
  ReceivePort? _exits;
  Completer<void>? _starting;
  _ActiveReplaceJob? _active;
  Future<void> _serial = Future<void>.value();
  int _nextJobId = 0;
  int _generation = 0;
  bool _disposed = false;

  Stream<ReplaceRuleDiagnostic> get diagnostics => _diagnostics.stream;

  Future<ReplaceRuleExecutionResult> applyBatch(
    ReplaceRuleExecutionBatch batch,
  ) {
    if (_disposed) {
      return Future<ReplaceRuleExecutionResult>.value(
        ReplaceRuleExecutionResult(values: batch.values, degraded: true),
      );
    }
    final completer = Completer<ReplaceRuleExecutionResult>();
    _serial = _serial.then((_) async {
      if (_disposed) {
        completer.complete(
          ReplaceRuleExecutionResult(values: batch.values, degraded: true),
        );
        return;
      }
      try {
        completer.complete(await _executeWithRecovery(batch));
      } catch (error) {
        if (!completer.isCompleted) {
          completer.complete(_degradedForCrash(batch, '$error'));
        }
      }
    });
    return completer.future;
  }

  Future<ReplaceRuleExecutionResult> _executeWithRecovery(
    ReplaceRuleExecutionBatch batch,
  ) async {
    final diagnostics = <ReplaceRuleDiagnostic>[];
    for (var attempt = 0; attempt <= maximumTimeoutRetries; attempt++) {
      final outcome = await _executeOnce(batch);
      if (outcome.result != null) {
        final result = outcome.result!;
        return ReplaceRuleExecutionResult(
          values: result.values,
          diagnostics: <ReplaceRuleDiagnostic>[
            ...diagnostics,
            ...result.diagnostics,
          ],
          skippedRuleIds: result.skippedRuleIds,
          degraded: diagnostics.isNotEmpty || result.degraded,
        );
      }
      final diagnostic = outcome.diagnostic!;
      diagnostics.add(diagnostic);
      _publishDiagnostic(diagnostic);
      final fingerprint = diagnostic.ruleFingerprint;
      if (fingerprint == null || fingerprint.isEmpty) break;
      _quarantined
          .putIfAbsent(batch.rulesSignature, () => <String>{})
          .add(fingerprint);
    }
    final fallback = _applyLiteralFallback(batch);
    return ReplaceRuleExecutionResult(
      values: fallback.values,
      diagnostics: diagnostics,
      skippedRuleIds: <String>{
        ..._quarantinedIds(batch),
        ...fallback.skippedRuleIds,
      }.toList(growable: false),
      degraded: true,
    );
  }

  Future<_ReplaceAttempt> _executeOnce(ReplaceRuleExecutionBatch batch) async {
    await _ensureWorker();
    final jobId = ++_nextJobId;
    final completer = Completer<_ReplaceAttempt>();
    final active = _ActiveReplaceJob(
      id: jobId,
      generation: _generation,
      completer: completer,
      batch: batch,
    );
    _active = active;
    active.timer = Timer(timeout, () {
      if (!identical(_active, active) || completer.isCompleted) return;
      final started = active.lastStartedRule;
      final diagnostic = ReplaceRuleDiagnostic(
        kind: ReplaceRuleDiagnosticKind.timeout,
        rulesSignature: batch.rulesSignature,
        ruleId: started?['id'] as String?,
        ruleName: started?['name'] as String?,
        ruleFingerprint: started?['fingerprint'] as String?,
        detail: 'Replacement worker exceeded ${timeout.inMilliseconds} ms.',
      );
      _destroyWorker();
      if (!completer.isCompleted) {
        completer.complete(_ReplaceAttempt.failure(diagnostic));
      }
    });
    final sendRules = _knownWorkerSignatures.add(batch.rulesSignature);
    _commands!.send(<String, Object?>{
      'type': 'apply',
      'jobId': jobId,
      'generation': _generation,
      'rulesSignature': batch.rulesSignature,
      'rules': sendRules
          ? batch.rules.map((rule) => rule.toMessage()).toList(growable: false)
          : null,
      'values': batch.values,
      'bookTitle': batch.bookTitle,
      'sourceName': batch.sourceName,
      'target': batch.target.name,
      'quarantined': _quarantined[batch.rulesSignature]?.toList() ?? const [],
    });
    return completer.future.whenComplete(() {
      active.timer?.cancel();
      if (identical(_active, active)) _active = null;
    });
  }

  Future<void> _ensureWorker() async {
    if (_commands != null && _isolate != null) return;
    final pending = _starting;
    if (pending != null) return pending.future;
    final completer = Completer<void>();
    _starting = completer;
    final generation = ++_generation;
    final events = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    _events = events;
    _errors = errors;
    _exits = exits;
    events.listen((message) => _handleWorkerEvent(generation, message));
    errors.listen((message) => _handleWorkerFailure(generation, '$message'));
    exits.listen((_) => _handleWorkerExit(generation));
    try {
      _isolate = await Isolate.spawn<SendPort>(
        _replaceRuleWorkerMain,
        events.sendPort,
        debugName: 'replacement-rule-worker',
        errorsAreFatal: true,
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );
      await completer.future;
    } catch (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
      _destroyWorker();
      rethrow;
    } finally {
      if (identical(_starting, completer)) _starting = null;
    }
  }

  void _handleWorkerEvent(int generation, Object? message) {
    if (generation != _generation || message is! Map) return;
    final type = message['type'];
    if (type == 'ready') {
      _commands = message['port'] as SendPort;
      _knownWorkerSignatures.clear();
      final starting = _starting;
      if (starting != null && !starting.isCompleted) starting.complete();
      return;
    }
    final active = _active;
    if (active == null ||
        active.generation != generation ||
        message['jobId'] != active.id) {
      return;
    }
    if (type == 'ruleStarted') {
      active.lastStartedRule = Map<Object?, Object?>.from(message);
      return;
    }
    if (type == 'result' && !active.completer.isCompleted) {
      final rawDiagnostics = (message['diagnostics'] as List? ?? const []);
      final diagnostics = rawDiagnostics
          .whereType<Map>()
          .map(
            (value) => ReplaceRuleDiagnostic(
              kind: ReplaceRuleDiagnosticKind.values.byName('${value['kind']}'),
              rulesSignature: active.batch.rulesSignature,
              ruleId: value['ruleId'] as String?,
              ruleName: value['ruleName'] as String?,
              ruleFingerprint: value['ruleFingerprint'] as String?,
              detail: '${value['detail'] ?? ''}',
            ),
          )
          .toList(growable: false);
      for (final diagnostic in diagnostics) {
        _publishDiagnostic(diagnostic);
      }
      active.completer.complete(
        _ReplaceAttempt.success(
          ReplaceRuleExecutionResult(
            values: List<String>.from(message['values'] as List),
            diagnostics: diagnostics,
            skippedRuleIds: List<String>.from(
              message['skippedRuleIds'] as List? ?? const [],
            ),
            degraded: message['degraded'] == true,
          ),
        ),
      );
    }
  }

  void _handleWorkerFailure(int generation, String detail) {
    if (generation != _generation) return;
    final active = _active;
    final diagnostic = ReplaceRuleDiagnostic(
      kind: ReplaceRuleDiagnosticKind.workerCrash,
      rulesSignature: active?.batch.rulesSignature ?? '',
      ruleId: active?.lastStartedRule?['id'] as String?,
      ruleName: active?.lastStartedRule?['name'] as String?,
      ruleFingerprint: active?.lastStartedRule?['fingerprint'] as String?,
      detail: detail,
    );
    _publishDiagnostic(diagnostic);
    _destroyWorker();
    if (active != null && !active.completer.isCompleted) {
      active.completer.complete(_ReplaceAttempt.failure(diagnostic));
    }
    final starting = _starting;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(StateError(detail));
    }
  }

  void _handleWorkerExit(int generation) {
    if (generation != _generation || _isolate == null) return;
    _handleWorkerFailure(generation, 'Replacement worker exited unexpectedly.');
  }

  ReplaceRuleExecutionResult _degradedForCrash(
    ReplaceRuleExecutionBatch batch,
    String detail,
  ) {
    final diagnostic = ReplaceRuleDiagnostic(
      kind: ReplaceRuleDiagnosticKind.workerCrash,
      rulesSignature: batch.rulesSignature,
      detail: detail,
    );
    _publishDiagnostic(diagnostic);
    final literals = _applyLiteralFallback(batch);
    return ReplaceRuleExecutionResult(
      values: literals.values,
      diagnostics: <ReplaceRuleDiagnostic>[diagnostic],
      skippedRuleIds: <String>{
        ..._quarantinedIds(batch),
        ...literals.skippedRuleIds,
      }.toList(growable: false),
      degraded: true,
    );
  }

  ReplaceRuleExecutionResult _applyLiteralFallback(
    ReplaceRuleExecutionBatch batch,
  ) {
    final values = List<String>.from(batch.values);
    final skipped = <String>[];
    final applicable = batch.rules.where(
      (rule) =>
          rule.enabled &&
          (batch.target == ReplaceRuleTarget.title
              ? rule.scopeTitle
              : rule.scopeContent) &&
          replaceRuleMatchesScope(rule, batch.bookTitle, batch.sourceName),
    );
    for (final rule in applicable) {
      if (rule.isRegex) {
        skipped.add(rule.id);
        continue;
      }
      for (var index = 0; index < values.length; index++) {
        values[index] = values[index].replaceAll(
          rule.pattern,
          rule.replacement,
        );
      }
    }
    return ReplaceRuleExecutionResult(
      values: values,
      skippedRuleIds: skipped,
      degraded: true,
    );
  }

  List<String> _quarantinedIds(ReplaceRuleExecutionBatch batch) {
    final fingerprints = _quarantined[batch.rulesSignature] ?? const <String>{};
    return batch.rules
        .where((rule) => fingerprints.contains(rule.fingerprint))
        .map((rule) => rule.id)
        .toList(growable: false);
  }

  void _publishDiagnostic(ReplaceRuleDiagnostic diagnostic) {
    if (!_diagnostics.isClosed) _diagnostics.add(diagnostic);
  }

  void _destroyWorker() {
    final starting = _starting;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(
        StateError('Replacement worker stopped before becoming ready.'),
      );
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    _knownWorkerSignatures.clear();
    _events?.close();
    _errors?.close();
    _exits?.close();
    _events = null;
    _errors = null;
    _exits = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final active = _active;
    if (active != null && !active.completer.isCompleted) {
      active.completer.complete(
        _ReplaceAttempt.success(
          ReplaceRuleExecutionResult(
            values: active.batch.values,
            degraded: true,
          ),
        ),
      );
    }
    _destroyWorker();
    await _diagnostics.close();
  }
}

class _ActiveReplaceJob {
  _ActiveReplaceJob({
    required this.id,
    required this.generation,
    required this.completer,
    required this.batch,
  });

  final int id;
  final int generation;
  final Completer<_ReplaceAttempt> completer;
  final ReplaceRuleExecutionBatch batch;
  Timer? timer;
  Map<Object?, Object?>? lastStartedRule;
}

class _ReplaceAttempt {
  const _ReplaceAttempt.success(this.result) : diagnostic = null;
  const _ReplaceAttempt.failure(this.diagnostic) : result = null;

  final ReplaceRuleExecutionResult? result;
  final ReplaceRuleDiagnostic? diagnostic;
}

void _replaceRuleWorkerMain(SendPort events) {
  final commands = ReceivePort();
  final ruleSets = <String, List<ReplaceRuleExecutionRule>>{};
  final prepared = <String, PreparedReplaceRule>{};
  events.send(<String, Object?>{'type': 'ready', 'port': commands.sendPort});
  commands.listen((raw) {
    if (raw is! Map || raw['type'] != 'apply') return;
    final message = Map<Object?, Object?>.from(raw);
    final jobId = message['jobId'] as int;
    final signature = '${message['rulesSignature']}';
    final incomingRules = message['rules'] as List?;
    if (incomingRules != null) {
      ruleSets[signature] = incomingRules
          .whereType<Map>()
          .map(
            (rule) => ReplaceRuleExecutionRule.fromMessage(
              Map<Object?, Object?>.from(rule),
            ),
          )
          .toList(growable: false);
      if (ruleSets.length > 4) {
        final staleSignature = ruleSets.keys.first;
        final staleRules = ruleSets.remove(staleSignature);
        if (staleRules != null) {
          for (final staleRule in staleRules) {
            prepared.remove(staleRule.fingerprint);
          }
        }
      }
    }
    final rules = ruleSets[signature] ?? const <ReplaceRuleExecutionRule>[];
    final originals = List<String>.from(message['values'] as List);
    final outputs = List<String>.from(originals);
    final target = ReplaceRuleTarget.values.byName('${message['target']}');
    final title = '${message['bookTitle'] ?? ''}';
    final sourceName = message['sourceName'] as String?;
    final quarantined = Set<String>.from(
      message['quarantined'] as List? ?? const [],
    );
    final diagnostics = <Map<String, Object?>>[];
    final skippedIds = <String>[];
    final outputLimit = replaceRuleOutputCharacterLimit(originals);
    var degraded = false;

    for (final rule in rules) {
      if (!rule.enabled ||
          (target == ReplaceRuleTarget.title
              ? !rule.scopeTitle
              : !rule.scopeContent) ||
          !replaceRuleMatchesScope(rule, title, sourceName)) {
        continue;
      }
      if (quarantined.contains(rule.fingerprint)) {
        skippedIds.add(rule.id);
        degraded = true;
        continue;
      }
      events.send(<String, Object?>{
        'type': 'ruleStarted',
        'jobId': jobId,
        'id': rule.id,
        'name': rule.name,
        'fingerprint': rule.fingerprint,
      });
      PreparedReplaceRule compiled;
      try {
        compiled = prepared.putIfAbsent(
          rule.fingerprint,
          () => PreparedReplaceRule(rule),
        );
        if (prepared.length > 2048) prepared.remove(prepared.keys.first);
      } on FormatException catch (error) {
        diagnostics.add(<String, Object?>{
          'kind': ReplaceRuleDiagnosticKind.invalidRegex.name,
          'ruleId': rule.id,
          'ruleName': rule.name,
          'ruleFingerprint': rule.fingerprint,
          'detail': error.message,
        });
        skippedIds.add(rule.id);
        degraded = true;
        continue;
      }
      for (var index = 0; index < outputs.length; index++) {
        outputs[index] = compiled.apply(outputs[index]);
      }
      final outputCharacters = outputs.fold<int>(
        0,
        (sum, value) => sum + value.length,
      );
      if (outputCharacters > outputLimit) {
        diagnostics.add(<String, Object?>{
          'kind': ReplaceRuleDiagnosticKind.outputLimit.name,
          'ruleId': rule.id,
          'ruleName': rule.name,
          'ruleFingerprint': rule.fingerprint,
          'detail': 'Replacement output exceeded the safety limit.',
        });
        outputs
          ..clear()
          ..addAll(originals);
        degraded = true;
        break;
      }
    }
    events.send(<String, Object?>{
      'type': 'result',
      'jobId': jobId,
      'values': outputs,
      'diagnostics': diagnostics,
      'skippedRuleIds': skippedIds,
      'degraded': degraded,
    });
  });
}
