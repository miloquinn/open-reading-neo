import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/source_engine/source_interaction_coordinator.dart';
import 'package:xxread/book_sources/source_engine/source_script_contract.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/source_verification_page.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required SourceInteractionCoordinator coordinator,
    required SourceInteractionTicket ticket,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => SourceVerificationPage(
                      ticket: ticket,
                      coordinator: coordinator,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  ({
    SourceInteractionCoordinator coordinator,
    SourceInteractionTicket ticket,
    Future<SourceScriptInteractionResult> pending,
  })
  startCodeChallenge() {
    final coordinator = SourceInteractionCoordinator.forTesting();
    late SourceInteractionTicket ticket;
    final subscription = coordinator.requests.listen((value) => ticket = value);
    addTearDown(subscription.cancel);
    final pending = coordinator.request(
      sourceId: 'src',
      sourceName: 'Src',
      interaction: const SourceScriptInteractionRequest(
        signature: 'code',
        kind: SourceScriptInteractionKind.verificationCode,
        url: 'https://example.test/captcha',
      ),
    );
    return (coordinator: coordinator, ticket: ticket, pending: pending);
  }

  testWidgets('submit completes the injected coordinator, not the singleton', (
    tester,
  ) async {
    final challenge = startCodeChallenge();
    await pumpPage(
      tester,
      coordinator: challenge.coordinator,
      ticket: challenge.ticket,
    );

    await tester.enterText(find.byType(TextField), '7391');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect((await challenge.pending).value, '7391');
    expect(challenge.coordinator.pendingCount, 0);
    expect(SourceInteractionCoordinator.instance.pendingCount, 0);
    expect(
      (await SourceInteractionCoordinator.instance.request(
        sourceId: 'idle',
        sourceName: 'Idle',
        interaction: const SourceScriptInteractionRequest(
          signature: 'idle',
          kind: SourceScriptInteractionKind.verificationCode,
          url: 'https://idle.test',
        ),
      )).error,
      contains('not ready'),
    );
    expect(find.byType(SourceVerificationPage), findsNothing);
  });

  testWidgets('cancel completes the injected ticket as cancelled', (
    tester,
  ) async {
    final challenge = startCodeChallenge();
    await pumpPage(
      tester,
      coordinator: challenge.coordinator,
      ticket: challenge.ticket,
    );

    await tester.tap(find.text('Cancel verification'));
    await tester.pumpAndSettle();

    expect((await challenge.pending).cancelled, isTrue);
    expect(challenge.coordinator.pendingCount, 0);
    expect(find.byType(SourceVerificationPage), findsNothing);
  });

  testWidgets('back cancels the injected ticket and pops', (tester) async {
    final challenge = startCodeChallenge();
    await pumpPage(
      tester,
      coordinator: challenge.coordinator,
      ticket: challenge.ticket,
    );

    await tester.tap(find.byKey(const ValueKey('floating-subpage-back')));
    await tester.pumpAndSettle();

    expect((await challenge.pending).cancelled, isTrue);
    expect(challenge.coordinator.pendingCount, 0);
    expect(find.byType(SourceVerificationPage), findsNothing);
  });
}
