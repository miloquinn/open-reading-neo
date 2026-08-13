import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_health_check_service.dart';
import 'package:xxread/book_sources/services/book_source_maintenance_coordinator.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_maintenance_sheet.dart';

void main() {
  testWidgets('maintenance chooser stays readable on a narrow phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final coordinator = BookSourceMaintenanceCoordinator(
      service: _HealthService(),
    );
    addTearDown(coordinator.dispose);

    await tester.pumpWidget(
      _app(BookSourceMaintenanceSheet(maintenance: coordinator)),
    );

    expect(find.text('Source maintenance'), findsOneWidget);
    expect(find.text('Source health check'), findsOneWidget);
    expect(find.text('Duplicate cleanup'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continue in background closes progress without cancelling', (
    tester,
  ) async {
    final service = _HealthService();
    final coordinator = BookSourceMaintenanceCoordinator(service: service);
    addTearDown(coordinator.dispose);
    unawaited(coordinator.start([_source()]));

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showModalBottomSheet<bool>(
              context: context,
              builder: (_) => BookSourceMaintenanceProgressSheet(
                maintenance: coordinator,
                onReview: () {},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Continue in background'), findsOneWidget);

    await tester.tap(find.text('Continue in background'));
    await tester.pumpAndSettle();
    expect(coordinator.state.isRunning, isTrue);
    expect(service.isCancelled?.call(), isFalse);
    service.completer.complete(const []);
    await tester.pump();
  });

  testWidgets('stop checking sends a cancellation request', (tester) async {
    final service = _HealthService();
    final coordinator = BookSourceMaintenanceCoordinator(service: service);
    addTearDown(coordinator.dispose);
    unawaited(coordinator.start([_source()]));

    await tester.pumpWidget(
      _app(
        BookSourceMaintenanceProgressSheet(
          maintenance: coordinator,
          onReview: () {},
        ),
      ),
    );
    await tester.tap(find.text('Stop checking'));
    expect(service.isCancelled?.call(), isTrue);
    service.completer.complete(const []);
    await tester.pump();
  });
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: home),
);

RegisteredBookSource _source() => RegisteredBookSource(
  id: 'source',
  name: 'Source',
  description: '',
  manifestUrl: Uri.parse('https://source.example/source.json'),
  apiBaseUrl: Uri.parse('https://source.example/'),
  protocolVersion: 'reading-1',
  languages: const [],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: const {'bookSourceUrl': 'https://source.example'},
);

class _HealthService extends BookSourceHealthCheckService {
  final completer = Completer<List<RegisteredBookSource>>();
  bool Function()? isCancelled;

  @override
  Future<List<RegisteredBookSource>> checkAllForCleanup(
    List<RegisteredBookSource> sources, {
    SourceHealthCheckProgress? onProgress,
    bool Function()? isCancelled,
  }) {
    this.isCancelled = isCancelled;
    return completer.future;
  }
}
