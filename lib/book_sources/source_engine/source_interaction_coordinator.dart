import 'dart:async';

import 'source_script_contract.dart';

abstract interface class SourceInteractionCoordinatorPort {
  Future<SourceScriptInteractionResult> request({
    required String sourceId,
    required String sourceName,
    required SourceScriptInteractionRequest interaction,
    Duration timeout = const Duration(minutes: 5),
  });
}

class SourceInteractionTicket {
  const SourceInteractionTicket({
    required this.requestId,
    required this.sourceId,
    required this.sourceName,
    required this.request,
  });

  final String requestId;
  final String sourceId;
  final String sourceName;
  final SourceScriptInteractionRequest request;
}

class SourceInteractionCoordinator implements SourceInteractionCoordinatorPort {
  SourceInteractionCoordinator._();

  SourceInteractionCoordinator.forTesting();

  static final SourceInteractionCoordinator instance =
      SourceInteractionCoordinator._();

  final StreamController<SourceInteractionTicket> _requests =
      StreamController<SourceInteractionTicket>.broadcast(sync: true);
  final Map<String, Completer<SourceScriptInteractionResult>> _pending = {};
  int _serial = 0;

  Stream<SourceInteractionTicket> get requests => _requests.stream;

  @override
  Future<SourceScriptInteractionResult> request({
    required String sourceId,
    required String sourceName,
    required SourceScriptInteractionRequest interaction,
    Duration timeout = const Duration(minutes: 5),
  }) {
    if (!_requests.hasListener) {
      return Future.value(
        const SourceScriptInteractionResult(
          error: 'The reading source verification screen is not ready.',
        ),
      );
    }
    final requestId =
        '$sourceId:${DateTime.now().microsecondsSinceEpoch}:${_serial++}';
    final completer = Completer<SourceScriptInteractionResult>();
    _pending[requestId] = completer;
    _requests.add(
      SourceInteractionTicket(
        requestId: requestId,
        sourceId: sourceId,
        sourceName: sourceName,
        request: interaction,
      ),
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(requestId);
        return const SourceScriptInteractionResult(
          error: 'Reading source verification timed out.',
        );
      },
    );
  }

  int get pendingCount => _pending.length;

  void complete(String requestId, SourceScriptInteractionResult result) {
    final completer = _pending.remove(requestId);
    if (completer != null && !completer.isCompleted) completer.complete(result);
  }

  void cancelAll() {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(
          const SourceScriptInteractionResult(cancelled: true),
        );
      }
    }
  }
}
