import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_maintenance_assessment.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_cleanup_review_sheet.dart';

void main() {
  testWidgets('starts with no selected sources and a disabled action', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_reviewSheet()));

    expect(_selectedIds(tester), isEmpty);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('maintenanceDisableSelected')),
          )
          .onPressed,
      isNull,
    );
  });

  final filterCases = <BookSourceMaintenanceClassification, Set<String>>{
    BookSourceMaintenanceClassification.available: {'available'},
    BookSourceMaintenanceClassification.limited: {'limited'},
    BookSourceMaintenanceClassification.failed: {
      'failed',
      'failed-disabled',
      'failed-referenced',
    },
    BookSourceMaintenanceClassification.timedOut: {'timed-out'},
    BookSourceMaintenanceClassification.unchecked: {'unchecked'},
  };
  for (final entry in filterCases.entries) {
    testWidgets('shows only ${entry.key.name} sources when filtered', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_reviewSheet()));

      await tester.tap(
        find.byKey(Key('maintenanceResultFilter-${entry.key.name}')),
      );
      await tester.pump();

      for (final id in entry.value) {
        await tester.scrollUntilVisible(
          _sourceFinder(id),
          120,
          scrollable: _reviewScrollable,
        );
        expect(_sourceFinder(id), findsOneWidget);
      }
      for (final id in _allIds.difference(entry.value)) {
        expect(_sourceFinder(id), findsNothing);
      }
    });
  }

  testWidgets('searches source names without changing selection', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_reviewSheet()));

    await tester.enterText(
      find.byKey(const Key('maintenanceResultSearch')),
      '超时示例',
    );
    await tester.pump();

    expect(_sourceFinder('timed-out'), findsOneWidget);
    for (final id in _allIds.difference({'timed-out'})) {
      expect(_sourceFinder(id), findsNothing);
    }
    expect(_selectedIds(tester), isEmpty);
  });

  testWidgets('searches source addresses', (tester) async {
    await tester.pumpWidget(_app(_reviewSheet()));

    await tester.enterText(
      find.byKey(const Key('maintenanceResultSearch')),
      'unchecked.example',
    );
    await tester.pump();

    expect(_sourceFinder('unchecked'), findsOneWidget);
    for (final id in _allIds.difference({'unchecked'})) {
      expect(_sourceFinder(id), findsNothing);
    }
  });

  testWidgets(
    'select failures chooses only enabled unreferenced failed sources',
    (tester) async {
      Set<String>? result;
      await tester.pumpWidget(
        _app(
          _ReviewLauncher(
            sheet: _reviewSheet(),
            onResult: (value) => result = value,
          ),
        ),
      );
      await tester.tap(find.text('打开结果'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('选择明确失败项'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('maintenanceDisableSelected')));
      await tester.pumpAndSettle();

      expect(result, {'failed'});
    },
  );

  testWidgets('select all changes visible sources and preserves hidden ones', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_reviewSheet()));
    await _tapSource(tester, 'limited');
    await _tapFilter(tester, 'failed');

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(await _sourceSelected(tester, 'failed'), isTrue);
    expect(await _sourceSelected(tester, 'failed-disabled'), isFalse);
    expect(await _sourceSelected(tester, 'failed-referenced'), isTrue);

    await _tapFilter(tester, 'limited');
    expect(await _sourceSelected(tester, 'limited'), isTrue);

    await _tapFilter(tester, 'failed');

    await tester.tap(find.text('取消全选'));
    await tester.pump();
    expect(await _sourceSelected(tester, 'failed'), isFalse);
    expect(await _sourceSelected(tester, 'failed-referenced'), isFalse);
    await _tapFilter(tester, 'limited');
    expect(await _sourceSelected(tester, 'limited'), isTrue);
  });

  testWidgets('returns exactly the explicitly selected source ids', (
    tester,
  ) async {
    Set<String>? result;
    await tester.pumpWidget(
      _app(
        _ReviewLauncher(
          sheet: _reviewSheet(),
          onResult: (value) => result = value,
        ),
      ),
    );
    await tester.tap(find.text('打开结果'));
    await tester.pumpAndSettle();
    await _tapSource(tester, 'limited');

    await tester.tap(find.byKey(const Key('maintenanceDisableSelected')));
    await tester.pumpAndSettle();

    expect(result, {'limited'});
  });

  testWidgets('uses current source metadata with an older assessment', (
    tester,
  ) async {
    final old = _healthCase(
      'changed',
      '旧名称',
      checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
      failed: const {SourceHealthCapability.content},
    );
    final current = _source('changed', '当前名称', enabled: false);
    await tester.pumpWidget(
      _app(
        BookSourceCleanupReviewSheet(
          fullyAvailableCount: 0,
          needsAttention: [current],
          assessments: [old.assessment],
        ),
      ),
    );

    expect(find.text('当前名称'), findsOneWidget);
    expect(find.text('旧名称'), findsNothing);
    expect(
      tester.widget<CheckboxListTile>(_sourceFinder('changed')).onChanged,
      isNull,
    );
  });

  testWidgets(
    'remains scrollable without overflow on a narrow large-text view',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_reviewSheet(), textScale: 1.4));

      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        _sourceFinder('unchecked'),
        180,
        scrollable: _reviewScrollable,
      );
      await tester.pump();

      expect(_sourceFinder('unchecked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _reviewSheet() {
  final cases = _cases();
  return BookSourceCleanupReviewSheet(
    fullyAvailableCount: 1,
    fullyAvailableSources: [cases.first.source],
    needsAttention: cases.skip(1).map((item) => item.source).toList(),
    assessments: cases.map((item) => item.assessment).toList(),
    referencedSourceIds: const {'failed-referenced'},
  );
}

Widget _app(Widget home, {double textScale = 1}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: home),
);

List<_AssessmentCase> _cases() => [
  _healthCase(
    'available',
    '可用示例',
    checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
  ),
  _healthCase(
    'limited',
    '部分可用示例',
    checked: const {SourceHealthCapability.search},
  ),
  _healthCase(
    'failed',
    '失败示例',
    checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
    failed: const {SourceHealthCapability.content},
  ),
  _healthCase(
    'failed-disabled',
    '已停用失败示例',
    checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
    failed: const {SourceHealthCapability.content},
    enabled: false,
  ),
  _healthCase(
    'failed-referenced',
    '书架引用失败示例',
    checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
    failed: const {SourceHealthCapability.content},
  ),
  _healthCase('timed-out', '超时示例', checked: const {}, timedOut: true),
  _uncheckedCase('unchecked', '待确认示例'),
];

_AssessmentCase _healthCase(
  String id,
  String name, {
  required Set<SourceHealthCapability> checked,
  Set<SourceHealthCapability> failed = const {},
  bool timedOut = false,
  bool enabled = true,
}) {
  final source = withSourceHealthCheckResult(
    _source(id, name, enabled: enabled),
    SourceHealthCheckResult(
      checked: checked,
      failed: failed,
      checkedAt: DateTime.utc(2026, 9, 5),
      timedOut: timedOut,
    ),
  );
  return _AssessmentCase(source, bookSourceMaintenanceAssessment(source));
}

_AssessmentCase _uncheckedCase(String id, String name) {
  final source = _source(id, name);
  return _AssessmentCase(
    source,
    bookSourceMaintenanceAssessment(
      source,
      error: StateError('No result returned'),
    ),
  );
}

RegisteredBookSource _source(String id, String name, {bool enabled = true}) =>
    RegisteredBookSource(
      id: id,
      name: name,
      description: '',
      manifestUrl: Uri.parse('https://$id.example/source.json'),
      apiBaseUrl: Uri.parse('https://$id.example/'),
      protocolVersion: 'reading-1',
      languages: const ['zh'],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: enabled,
      addedAt: DateTime.utc(2026, 9, 5),
      sourceProtocol: BookSourceProtocolKind.readingSource,
      sourceConfig: {'bookSourceUrl': 'https://$id.example'},
    );

Finder _sourceFinder(String id) =>
    find.byKey(ValueKey('bookSourceCleanupItem-$id'), skipOffstage: false);

Set<String> _selectedIds(WidgetTester tester) => {
  for (final item in tester.widgetList<CheckboxListTile>(
    find.byType(CheckboxListTile, skipOffstage: false),
  ))
    if (item.value == true)
      '${(item.key! as ValueKey).value}'.replaceFirst(
        'bookSourceCleanupItem-',
        '',
      ),
};

Future<void> _tapSource(WidgetTester tester, String id) async {
  await tester.scrollUntilVisible(
    _sourceFinder(id),
    120,
    scrollable: _reviewScrollable,
  );
  await tester.drag(_reviewScrollable, const Offset(0, -120));
  await tester.pump();
  await tester.tap(_sourceFinder(id));
  await tester.pump();
}

Future<void> _tapFilter(WidgetTester tester, String name) async {
  await tester.drag(_reviewScrollable, const Offset(0, 1200));
  await tester.pump();
  await tester.tap(find.byKey(Key('maintenanceResultFilter-$name')));
  await tester.pump();
}

Future<bool?> _sourceSelected(WidgetTester tester, String id) async {
  await tester.scrollUntilVisible(
    _sourceFinder(id),
    120,
    scrollable: _reviewScrollable,
  );
  return tester.widget<CheckboxListTile>(_sourceFinder(id)).value;
}

const _allIds = {
  'available',
  'limited',
  'failed',
  'failed-disabled',
  'failed-referenced',
  'timed-out',
  'unchecked',
};

final _reviewScrollable = find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

class _AssessmentCase {
  const _AssessmentCase(this.source, this.assessment);

  final RegisteredBookSource source;
  final BookSourceMaintenanceAssessment assessment;
}

class _ReviewLauncher extends StatelessWidget {
  const _ReviewLauncher({required this.sheet, required this.onResult});

  final Widget sheet;
  final ValueChanged<Set<String>?> onResult;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton(
        onPressed: () async {
          final result = await showModalBottomSheet<Set<String>>(
            context: context,
            isScrollControlled: true,
            builder: (_) => sheet,
          );
          onResult(result);
        },
        child: const Text('打开结果'),
      ),
    );
  }
}
