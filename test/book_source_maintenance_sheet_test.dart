import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/pages/book_sources/book_source_management_page.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_health_check_service.dart';
import 'package:xxread/book_sources/services/book_source_maintenance_coordinator.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_maintenance_sheet.dart';

void main() {
  setUp(() async {
    await BookSourceRegistry.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });
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
  testWidgets(
    'scope selection returns exactly the selected compatible source IDs',
    (tester) async {
      final coordinator = BookSourceMaintenanceCoordinator(
        service: _HealthService(),
      );
      addTearDown(coordinator.dispose);
      BookSourceMaintenanceRequest? request;
      final a = _source();
      final b = _source(id: 'disabled', enabled: false);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                request =
                    await showModalBottomSheet<BookSourceMaintenanceRequest>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => BookSourceMaintenanceSheet(
                        maintenance: coordinator,
                        sources: [a, b],
                      ),
                    );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('1 sources in this scope'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('maintenanceScope-all')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('bookSourcesDedupeMaintenanceAction')),
      );
      await tester.pumpAndSettle();
      expect(request!.sourceIds, {'source', 'disabled'});
      expect(request!.action, BookSourceMaintenanceAction.dedupe);
    },
  );

  testWidgets(
    'cancelled progress keeps the original denominator and offers resume',
    (tester) async {
      final source = _source();
      final coordinator = _FixedMaintenance(
        BookSourceMaintenanceState(
          status: BookSourceMaintenanceStatus.cancelled,
          progress: const BookSourceMaintenanceProgress(completed: 1, total: 3),
          result: BookSourceMaintenanceResult(
            allSources: [
              source,
              _source(id: 'b'),
              _source(id: 'c'),
            ],
            assessments: const [],
            remainingSources: [
              _source(id: 'b'),
              _source(id: 'c'),
            ],
          ),
        ),
      );
      addTearDown(coordinator.dispose);
      await tester.pumpWidget(
        _app(
          BookSourceMaintenanceProgressSheet(
            maintenance: coordinator,
            onReview: () {},
          ),
        ),
      );
      expect(find.text('Check stopped'), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.text('33%'), findsOneWidget);
      expect(find.text('100%'), findsNothing);
      expect(
        find.byKey(const Key('bookSourcesMaintenanceResumeButton')),
        findsOneWidget,
      );
      await tester.pumpWidget(
        _app(BookSourceMaintenanceSheet(maintenance: coordinator)),
      );
      expect(
        find.text('Checked 1 source(s); 0 need attention'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'an application-owned check survives leaving and reopening management',
    (tester) async {
      final service = _HealthService();
      final coordinator = BookSourceMaintenanceCoordinator(service: service);
      final navigator = GlobalKey<NavigatorState>();
      unawaited(coordinator.start([_source()]));
      await tester.pumpWidget(
        ChangeNotifierProvider<BookSourceMaintenanceCoordinator>.value(
          value: coordinator,
          child: MaterialApp(
            navigatorKey: navigator,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const BookSourceManagementPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(coordinator.state.isRunning, isTrue);
      expect(service.isCancelled?.call(), isFalse);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const BookSourceManagementPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bookSourcesToolButton')));
      await tester.pumpAndSettle();
      expect(find.text('Source maintenance 0/1'), findsOneWidget);
      service.completer.complete(const []);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      coordinator.dispose();
    },
  );
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: home),
);

RegisteredBookSource _source({String id = 'source', bool enabled = true}) =>
    RegisteredBookSource(
      id: id,
      name: 'Source',
      description: '',
      manifestUrl: Uri.parse('https://source.example/source.json'),
      apiBaseUrl: Uri.parse('https://source.example/'),
      protocolVersion: 'reading-1',
      languages: const [],
      capabilities: const {'search'},
      enabled: enabled,
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
    SourceHealthCheckItemCompleted? onItemCompleted,
    SourceHealthCheckItemError? onItemError,
  }) {
    this.isCancelled = isCancelled;
    return completer.future;
  }
}

class _FixedMaintenance extends BookSourceMaintenanceCoordinator {
  _FixedMaintenance(this.fixed);
  final BookSourceMaintenanceState fixed;
  @override
  BookSourceMaintenanceState get state => fixed;
}
