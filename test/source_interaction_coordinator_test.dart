import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/source_engine/source_interaction_coordinator.dart';
import 'package:xxread/book_sources/source_engine/source_script_contract.dart';

void main() {
  test('coordinator keeps concurrent source interactions isolated', () async {
    final coordinator = SourceInteractionCoordinator.forTesting();
    final tickets = <SourceInteractionTicket>[];
    final subscription = coordinator.requests.listen(tickets.add);
    addTearDown(subscription.cancel);

    final first = coordinator.request(
      sourceId: 'first',
      sourceName: 'First',
      interaction: const SourceScriptInteractionRequest(
        signature: 'a',
        kind: SourceScriptInteractionKind.browserAwait,
        url: 'https://first.test',
      ),
    );
    final second = coordinator.request(
      sourceId: 'second',
      sourceName: 'Second',
      interaction: const SourceScriptInteractionRequest(
        signature: 'b',
        kind: SourceScriptInteractionKind.verificationCode,
        url: 'https://second.test/image',
      ),
    );

    expect(tickets, hasLength(2));
    coordinator.complete(
      tickets[1].requestId,
      const SourceScriptInteractionResult(value: '7391'),
    );
    coordinator.complete(
      tickets[0].requestId,
      const SourceScriptInteractionResult(finalUrl: 'https://first.test/ok'),
    );

    expect((await first).finalUrl, 'https://first.test/ok');
    expect((await second).value, '7391');
    expect(coordinator.pendingCount, 0);
  });

  test('coordinator timeout releases a waiting source operation', () async {
    final coordinator = SourceInteractionCoordinator.forTesting();
    final subscription = coordinator.requests.listen((_) {});
    addTearDown(subscription.cancel);

    final result = await coordinator.request(
      sourceId: 'timeout',
      sourceName: 'Timeout',
      interaction: const SourceScriptInteractionRequest(
        signature: 'timeout',
        kind: SourceScriptInteractionKind.browserAwait,
        url: 'https://timeout.test',
      ),
      timeout: const Duration(milliseconds: 5),
    );

    expect(result.error, contains('timed out'));
    expect(coordinator.pendingCount, 0);
  });
}
