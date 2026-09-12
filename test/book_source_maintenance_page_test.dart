@Tags(['isolated-process'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_maintenance_coordinator.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/book_source_maintenance_page.dart';
import 'package:xxread/pages/book_sources/controllers/book_source_management_controller.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_pill.dart';

void main() {
  setUp(BookSourceRegistry.resetForTesting);

  testWidgets('restores persisted healthy results before a new check', (
    tester,
  ) async {
    final healthy = _withResult(
      _source('healthy', 'Healthy source'),
      checked: SourceHealthCapability.values.toSet(),
      respondTimeMs: 37,
    );
    final harness = await _pumpPage(tester, sources: [healthy]);

    await _reveal(tester, 'healthy');
    expect(find.text('可用'), findsWidgets);
    expect(find.textContaining('37 ms'), findsOneWidget);
    expect(harness.maintenance.beginCalls, isEmpty);
  });

  testWidgets('ignores an old failed assessment after source config changes', (
    tester,
  ) async {
    final oldSource = _source('changed', 'Changed source');
    final currentSource = ReadingSourceConfig.fromJson({
      ...oldSource.sourceConfig!,
      'searchUrl': '/new-search?q={{key}}',
    }).toRegisteredSource(id: oldSource.id);
    final maintenance = _FakeMaintenance()
      ..emit(
        BookSourceMaintenanceState(
          status: BookSourceMaintenanceStatus.completed,
          runId: 2,
          result: BookSourceMaintenanceResult(
            allSources: [oldSource],
            assessments: [
              _assessment(
                oldSource,
                BookSourceMaintenanceClassification.failed,
                failed: {SourceHealthCapability.content},
              ),
            ],
            remainingSources: const [],
          ),
        ),
      );
    await _pumpPage(tester, sources: [currentSource], maintenance: maintenance);

    await _reveal(tester, 'changed');
    expect(find.text('待确认'), findsWidgets);
    await tester.tap(find.byKey(const Key('maintenanceFilterProblems')));
    await tester.pump();
    expect(find.byKey(const Key('maintenanceSource-changed')), findsNothing);
  });

  testWidgets('newer persisted healthy result wins over an older failed run', (
    tester,
  ) async {
    final source = _source('newer', 'Newer healthy source');
    final persistedHealthy = _withResult(
      source,
      checked: SourceHealthCapability.values.toSet(),
      respondTimeMs: 19,
      checkedAt: DateTime.utc(2026, 9, 13),
    );
    final oldFailed = _assessment(
      source,
      BookSourceMaintenanceClassification.failed,
      failed: {SourceHealthCapability.content},
      checkedAt: DateTime.utc(2026, 9, 12),
    );
    final maintenance = _FakeMaintenance()
      ..emit(
        BookSourceMaintenanceState(
          status: BookSourceMaintenanceStatus.completed,
          runId: 3,
          result: BookSourceMaintenanceResult(
            allSources: [oldFailed.source],
            assessments: [oldFailed],
            remainingSources: const [],
          ),
        ),
      );
    await _pumpPage(
      tester,
      sources: [persistedHealthy],
      maintenance: maintenance,
    );

    await _reveal(tester, 'newer');
    expect(find.text('可用'), findsWidgets);
    expect(find.textContaining('19 ms'), findsOneWidget);
    await tester.tap(find.byKey(const Key('maintenanceFilterProblems')));
    await tester.pump();
    expect(find.byKey(const Key('maintenanceSource-newer')), findsNothing);
  });

  testWidgets('problem filter excludes unchecked sources from select visible', (
    tester,
  ) async {
    final failed = _source('failed', 'Failed source');
    final unchecked = _source('unchecked', 'Unchecked source');
    final harness = await _pumpPage(
      tester,
      sources: [failed, unchecked],
      assessments: [
        _assessment(
          failed,
          BookSourceMaintenanceClassification.failed,
          failed: {SourceHealthCapability.content},
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('maintenanceFilterProblems')));
    await tester.pump();
    await _revealControl(tester, const Key('maintenanceSelectVisible'));
    await tester.tap(find.byKey(const Key('maintenanceSelectVisible')));
    await tester.pump();

    expect(_tile(tester, 'failed').value, isTrue);
    expect(find.byKey(const Key('maintenanceSource-unchecked')), findsNothing);
    await tester.tap(find.byKey(const Key('maintenanceDisableSelected')));
    await tester.pumpAndSettle();
    expect(harness.registry.disabledWrites.single, {'failed'});
  });

  testWidgets('disabling all visible problems keeps their diagnoses visible', (
    tester,
  ) async {
    final failed = _source('failed', 'Failed source');
    final limited = _source('limited', 'Limited source');
    final harness = await _pumpPage(
      tester,
      sources: [failed, limited],
      assessments: [
        _assessment(
          failed,
          BookSourceMaintenanceClassification.failed,
          failed: {SourceHealthCapability.content},
        ),
        _assessment(
          limited,
          BookSourceMaintenanceClassification.limited,
          checked: {SourceHealthCapability.search},
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('maintenanceFilterProblems')));
    await tester.pump();
    await _revealControl(tester, const Key('maintenanceSelectVisible'));
    await tester.tap(find.byKey(const Key('maintenanceSelectVisible')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('maintenanceDisableSelected')));
    await tester.pumpAndSettle();

    expect(harness.registry.disabledWrites.single, {'failed', 'limited'});
    await _reveal(tester, 'failed');
    expect(find.text('Failed source'), findsOneWidget);
    expect(_tile(tester, 'failed').value, isTrue);
    await _reveal(tester, 'limited');
    expect(find.text('Limited source'), findsOneWidget);
    expect(_tile(tester, 'limited').value, isTrue);
  });

  testWidgets('delete confirms, removes selected sources, and refreshes rows', (
    tester,
  ) async {
    final first = _source('first', 'First source');
    final second = _source('second', 'Second source');
    final harness = await _pumpPage(tester, sources: [first, second]);

    await _reveal(tester, 'first');
    await tester.tap(find.byKey(const Key('maintenanceSource-first')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('maintenanceDeleteSelected')));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除选中的 1 个书源吗'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(harness.registry.removedWrites.single, {'first'});
    expect(find.byKey(const Key('maintenanceSource-first')), findsNothing);
    expect(find.text('Second source'), findsOneWidget);
  });

  testWidgets('write failure reports the error and preserves selection', (
    tester,
  ) async {
    final source = _source('broken-write', 'Broken write');
    await _pumpPage(
      tester,
      sources: [source],
      disableError: StateError('write failed'),
    );

    await _reveal(tester, 'broken-write');
    await tester.tap(find.byKey(const Key('maintenanceSource-broken-write')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('maintenanceDisableSelected')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maintenanceActionFailure')), findsOneWidget);
    expect(_tile(tester, 'broken-write').value, isTrue);
    expect(
      tester
          .widget<ButtonStyleButton>(
            find.byKey(const Key('maintenanceDisableSelected')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('changing filters never applies actions to hidden selections', (
    tester,
  ) async {
    final failed = _source('failed', 'Failed source');
    final available = _source('available', 'Available source');
    final harness = await _pumpPage(
      tester,
      sources: [failed, available],
      assessments: [
        _assessment(
          failed,
          BookSourceMaintenanceClassification.failed,
          failed: {SourceHealthCapability.content},
        ),
        _assessment(
          available,
          BookSourceMaintenanceClassification.available,
          checked: SourceHealthCapability.values.toSet(),
        ),
      ],
    );

    await _tapFilter(tester, const Key('maintenanceResultFilter-failed'));
    await tester.pump();
    await _revealControl(tester, const Key('maintenanceSelectVisible'));
    await tester.tap(find.byKey(const Key('maintenanceSelectVisible')));
    await tester.pump();
    await _tapFilter(tester, const Key('maintenanceResultFilter-available'));
    await tester.pump();
    await _revealControl(tester, const Key('maintenanceSelectVisible'));
    await tester.tap(find.byKey(const Key('maintenanceSelectVisible')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('maintenanceDisableSelected')));
    await tester.pumpAndSettle();

    expect(harness.registry.disabledWrites.single, {'available'});
  });

  testWidgets('shows partial results while running and can stop then resume', (
    tester,
  ) async {
    final done = _source('done', 'Completed source');
    final pending = _source('pending', 'Pending source');
    final maintenance = _FakeMaintenance()
      ..emit(
        BookSourceMaintenanceState(
          status: BookSourceMaintenanceStatus.running,
          runId: 4,
          progress: const BookSourceMaintenanceProgress(completed: 1, total: 2),
          result: BookSourceMaintenanceResult(
            allSources: [done],
            assessments: [
              _assessment(
                done,
                BookSourceMaintenanceClassification.failed,
                failed: {SourceHealthCapability.content},
              ),
            ],
            remainingSources: [pending],
          ),
        ),
      );
    await _pumpPage(tester, sources: [done, pending], maintenance: maintenance);

    expect(find.text('1 / 2'), findsOneWidget);
    await _reveal(tester, 'done');
    expect(find.text('Completed source'), findsOneWidget);
    expect(_tile(tester, 'done').onChanged, isNull);
    await tester.drag(
      find.byKey(const Key('bookSourceMaintenanceScroll')),
      const Offset(0, 1000),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('maintenanceStop')));
    await tester.pump();
    expect(maintenance.cancelCalls, 1);

    maintenance.emit(
      BookSourceMaintenanceState(
        status: BookSourceMaintenanceStatus.cancelled,
        runId: 4,
        progress: const BookSourceMaintenanceProgress(completed: 1, total: 2),
        result: BookSourceMaintenanceResult(
          allSources: [done],
          assessments: [
            _assessment(
              done,
              BookSourceMaintenanceClassification.failed,
              failed: {SourceHealthCapability.content},
            ),
          ],
          remainingSources: [pending],
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<BookSourcePill>(
            find.byKey(const Key('maintenanceFilterChecked')),
          )
          .selected,
      isTrue,
    );
    expect(find.byKey(const Key('maintenanceSource-done')), findsOneWidget);
    expect(find.byKey(const Key('maintenanceSource-pending')), findsNothing);
    await _revealControl(tester, const Key('maintenanceResume'));
    await tester.tap(find.byKey(const Key('maintenanceResume')));
    await tester.pump();
    expect(maintenance.resumeCalls, 1);
  });

  testWidgets(
    'cancelled run selects and deletes only completed sources then resumes',
    (tester) async {
      final failed = _source('failed-done', 'Failed completed source');
      final changed = _source('changed-done', 'Changed completed source');
      final pending = _source('pending', 'Never checked source');
      final maintenance = _FakeMaintenance()
        ..emit(
          BookSourceMaintenanceState(
            status: BookSourceMaintenanceStatus.cancelled,
            runId: 5,
            progress: const BookSourceMaintenanceProgress(
              completed: 2,
              total: 3,
            ),
            result: BookSourceMaintenanceResult(
              allSources: [failed, changed, pending],
              assessments: [
                _assessment(
                  failed,
                  BookSourceMaintenanceClassification.failed,
                  failed: {SourceHealthCapability.content},
                ),
                BookSourceMaintenanceAssessment(
                  source: changed,
                  classification: BookSourceMaintenanceClassification.unchecked,
                  error: StateError('configuration changed during check'),
                ),
              ],
              remainingSources: [pending],
            ),
          ),
        );
      final harness = await _pumpPage(
        tester,
        sources: [failed, changed, pending],
        maintenance: maintenance,
      );

      expect(
        tester
            .widget<BookSourcePill>(
              find.byKey(const Key('maintenanceFilterChecked')),
            )
            .selected,
        isTrue,
      );
      expect(
        find.byKey(const Key('maintenanceSource-failed-done')),
        findsOneWidget,
      );
      await _reveal(tester, 'changed-done');
      expect(
        find.byKey(const Key('maintenanceSource-changed-done')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('maintenanceSource-pending')), findsNothing);

      await _revealControl(tester, const Key('maintenanceSelectVisible'));
      await tester.tap(find.byKey(const Key('maintenanceSelectVisible')));
      await tester.pump();
      await _reveal(tester, 'failed-done');
      expect(_tile(tester, 'failed-done').value, isTrue);
      await _reveal(tester, 'changed-done');
      expect(_tile(tester, 'changed-done').value, isTrue);

      await tester.tap(find.byKey(const Key('maintenanceDeleteSelected')));
      await tester.pumpAndSettle();
      expect(find.textContaining('确定删除选中的 2 个书源吗'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(harness.registry.removedWrites.single, {
        'failed-done',
        'changed-done',
      });
      expect(
        harness.registry.sources.map((source) => source.id),
        contains('pending'),
      );
      await _revealControl(tester, const Key('maintenanceResume'));
      await tester.tap(find.byKey(const Key('maintenanceResume')));
      await tester.pump();
      expect(maintenance.resumeCalls, 1);
    },
  );

  testWidgets('result filters stay on one horizontally scrollable row', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.reset);
    final classifications = BookSourceMaintenanceClassification.values;
    final sources = [
      for (final classification in classifications)
        _source(classification.name, '${classification.name} source'),
    ];
    await _pumpPage(
      tester,
      sources: sources,
      assessments: [
        for (var index = 0; index < classifications.length; index++)
          _assessment(sources[index], classifications[index]),
      ],
    );

    final filters = find.byKey(const Key('maintenanceFiltersScroll'));
    expect(filters, findsOneWidget);
    expect(
      find.descendant(of: filters, matching: find.byType(Row)),
      findsWidgets,
    );
    final pills = find.descendant(
      of: filters,
      matching: find.byType(BookSourcePill),
    );
    expect(pills, findsNWidgets(classifications.length + 3));
    final tops = pills
        .evaluate()
        .map((element) => tester.getTopLeft(find.byWidget(element.widget)).dy)
        .toSet();
    expect(tops, hasLength(1));

    final horizontal = find.descendant(
      of: filters,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(horizontal).position;
    expect(position.maxScrollExtent, greaterThan(0));
    await _tapFilter(tester, const Key('maintenanceResultFilter-unchecked'));
    expect(position.pixels, greaterThan(0));
  });

  for (final width in [834.0, 840.0, 1024.0, 1440.0]) {
    testWidgets('uses the split maintenance layout at ${width.toInt()}px', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);

      await _pumpPage(tester, sources: [_source('wide', 'Wide source')]);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('maintenanceWideLayout')), findsOneWidget);
      expect(
        find.byKey(const Key('maintenanceControlsScroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('bookSourceMaintenanceScroll')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short landscape keeps a scrollable single column', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(844, 390);
    addTearDown(tester.view.reset);
    await _pumpPage(
      tester,
      sources: [_source('landscape', 'Landscape source')],
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('maintenanceWideLayout')), findsNothing);
    await _reveal(tester, 'landscape');
    expect(find.text('Landscape source').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text at the tablet breakpoint falls back to one column', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(840, 900);
    addTearDown(tester.view.reset);

    await _pumpPage(
      tester,
      sources: [_source('large-text', 'Large text source')],
      mediaQuery: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maintenanceWideLayout')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a 320px screen at 1.4 text scale without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.reset);
    final source = _source('narrow', 'A source with a fairly long name');

    await _pumpPage(
      tester,
      sources: [source],
      mediaQuery: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps a 3000-source result list lazy and searchable', (
    tester,
  ) async {
    final sources = List.generate(
      3000,
      (index) => _source('bulk-$index', 'Bulk source $index'),
    );
    await _pumpPage(tester, sources: sources);

    expect(find.byType(CheckboxListTile).evaluate().length, lessThan(30));
    await _revealControl(tester, const Key('maintenanceResultSearch'));
    await tester.enterText(
      find.byKey(const Key('maintenanceResultSearch')),
      'Bulk source 2999',
    );
    await tester.pump();
    await _reveal(tester, 'bulk-2999');

    expect(
      find.descendant(
        of: find.byKey(const Key('maintenanceSource-bulk-2999')),
        matching: find.text('Bulk source 2999'),
      ),
      findsOneWidget,
    );
    expect(find.byType(CheckboxListTile).evaluate().length, 1);
  });
}

class _Harness {
  const _Harness(this.registry, this.maintenance);

  final _MemoryRegistry registry;
  final _FakeMaintenance maintenance;
}

Future<_Harness> _pumpPage(
  WidgetTester tester, {
  required List<RegisteredBookSource> sources,
  List<BookSourceMaintenanceAssessment>? assessments,
  _FakeMaintenance? maintenance,
  Object? disableError,
  MediaQueryData? mediaQuery,
}) async {
  final assessmentSources = {
    for (final item in assessments ?? const <BookSourceMaintenanceAssessment>[])
      item.source.id: item.source,
  };
  final effectiveSources = [
    for (final source in sources) assessmentSources[source.id] ?? source,
  ];
  final registry = _MemoryRegistry(
    effectiveSources,
    disableError: disableError,
  );
  final controller = BookSourceManagementController(registry: registry);
  final coordinator = maintenance ?? _FakeMaintenance();
  addTearDown(controller.dispose);
  addTearDown(coordinator.dispose);
  await controller.load();
  if (assessments != null) {
    coordinator.emit(
      BookSourceMaintenanceState(
        status: BookSourceMaintenanceStatus.completed,
        runId: 1,
        progress: BookSourceMaintenanceProgress(
          completed: assessments.length,
          total: effectiveSources.length,
        ),
        result: BookSourceMaintenanceResult(
          allSources: assessments.map((item) => item.source).toList(),
          assessments: assessments,
          remainingSources: const [],
        ),
      ),
    );
  }
  Widget child = BookSourceMaintenancePage(
    controller: controller,
    maintenance: coordinator,
    readReferencedSourceIds: () async => {},
    onDedupe: (_) async {},
  );
  if (mediaQuery != null) child = MediaQuery(data: mediaQuery, child: child);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
  await tester.pump();
  return _Harness(registry, coordinator);
}

Future<void> _reveal(WidgetTester tester, String id) async {
  final row = find.byKey(Key('maintenanceSource-$id'));
  await tester.scrollUntilVisible(
    row,
    250,
    scrollable: find
        .descendant(
          of: find.byKey(const Key('bookSourceMaintenanceScroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pump();
}

Future<void> _revealControl(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('bookSourceMaintenanceScroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await Scrollable.ensureVisible(
    tester.element(target),
    alignment: 0.5,
    duration: Duration.zero,
  );
  await tester.pump();
}

Future<void> _tapFilter(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  expect(target, findsOneWidget);
  await Scrollable.ensureVisible(
    tester.element(target),
    alignment: 0.5,
    duration: Duration.zero,
  );
  await tester.pump();
  await tester.tap(target);
}

CheckboxListTile _tile(WidgetTester tester, String id) =>
    tester.widget<CheckboxListTile>(find.byKey(Key('maintenanceSource-$id')));

RegisteredBookSource _source(String id, String name) =>
    ReadingSourceConfig.fromJson({
      'bookSourceName': name,
      'bookSourceUrl': 'https://$id.example',
      'searchUrl': '/search?q={{key}}',
      'ruleSearch': {'bookList': '.book'},
      'ruleBookInfo': {'name': 'h1'},
      'ruleToc': {'chapterList': '.chapter'},
      'ruleContent': {'content': '#content'},
    }).toRegisteredSource(id: id);

RegisteredBookSource _withResult(
  RegisteredBookSource source, {
  required Set<SourceHealthCapability> checked,
  Set<SourceHealthCapability> failed = const {},
  bool timedOut = false,
  int? respondTimeMs,
  DateTime? checkedAt,
}) => withSourceHealthCheckResult(
  source,
  SourceHealthCheckResult(
    checked: checked,
    failed: failed,
    checkedAt: checkedAt ?? DateTime.utc(2026, 9, 12),
    respondTimeMs: respondTimeMs,
    timedOut: timedOut,
  ),
);

BookSourceMaintenanceAssessment _assessment(
  RegisteredBookSource source,
  BookSourceMaintenanceClassification classification, {
  Set<SourceHealthCapability> checked = const {
    SourceHealthCapability.search,
    SourceHealthCapability.info,
    SourceHealthCapability.catalog,
    SourceHealthCapability.content,
  },
  Set<SourceHealthCapability> failed = const {},
  DateTime? checkedAt,
}) {
  final result = SourceHealthCheckResult(
    checked: checked,
    failed: failed,
    checkedAt: checkedAt ?? DateTime.utc(2026, 9, 12),
    timedOut: classification == BookSourceMaintenanceClassification.timedOut,
  );
  final checkedSource = withSourceHealthCheckResult(source, result);
  return BookSourceMaintenanceAssessment(
    source: checkedSource,
    classification: classification,
    healthResult: result,
  );
}

class _MemoryRegistry extends BookSourceRegistry {
  _MemoryRegistry(List<RegisteredBookSource> sources, {this.disableError})
    : sources = List.of(sources);

  List<RegisteredBookSource> sources;
  final Object? disableError;
  final List<Set<String>> disabledWrites = [];
  final List<Set<String>> removedWrites = [];

  @override
  Future<List<RegisteredBookSource>> load() async => List.of(sources);

  @override
  Future<List<RegisteredBookSource>> loadInBackground() async =>
      List.of(sources);

  @override
  Future<List<String>> loadGroups() async => const [];

  @override
  Future<List<RegisteredBookSource>> setEnabledAll(
    Iterable<String> ids,
    bool enabled,
  ) async {
    final selected = ids.toSet();
    disabledWrites.add(selected);
    if (disableError case final error?) throw error;
    sources = [
      for (final source in sources)
        selected.contains(source.id)
            ? source.copyWith(enabled: enabled)
            : source,
    ];
    return List.of(sources);
  }

  @override
  Future<List<RegisteredBookSource>> removeAll(Iterable<String> ids) async {
    final selected = ids.toSet();
    removedWrites.add(selected);
    sources = sources
        .where((source) => !selected.contains(source.id))
        .toList(growable: false);
    return List.of(sources);
  }
}

class _FakeMaintenance extends BookSourceMaintenanceCoordinator {
  BookSourceMaintenanceState _state = const BookSourceMaintenanceState();
  final List<Set<String>> beginCalls = [];
  int cancelCalls = 0;
  int resumeCalls = 0;

  @override
  BookSourceMaintenanceState get state => _state;

  void emit(BookSourceMaintenanceState state) {
    _state = state;
    notifyListeners();
  }

  @override
  Future<void> begin(Iterable<RegisteredBookSource> sources) async {
    beginCalls.add(sources.map((source) => source.id).toSet());
  }

  @override
  void cancel() {
    cancelCalls++;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
  }
}
