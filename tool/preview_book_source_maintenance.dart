// Capture all states:
// flutter test --no-pub tool/preview_book_source_maintenance.dart
// Capture the revised UI separately:
// flutter test --no-pub --dart-define=MAINTENANCE_PREVIEW_VARIANT=after tool/preview_book_source_maintenance.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_maintenance_coordinator.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_cleanup_review_sheet.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_maintenance_sheet.dart';
import 'package:xxread/utils/app_themes.dart';

const _captureKey = Key('maintenance-preview-capture');
const _surfaceKey = Key('maintenance-preview-surface');
const _previewFont = 'MaintenancePreviewChinese';
const _variant = String.fromEnvironment(
  'MAINTENANCE_PREVIEW_VARIANT',
  defaultValue: 'baseline',
);
const _outputDirectory = '.omx/maintenance-previews/$_variant';

void main() {
  final specs = <_PreviewSpec>[
    const _PreviewSpec('entry', _PreviewScene.entry),
    const _PreviewSpec('progress', _PreviewScene.progress),
    const _PreviewSpec('cancelling', _PreviewScene.cancelling),
    const _PreviewSpec('cancelled', _PreviewScene.cancelled),
    const _PreviewSpec('failed', _PreviewScene.failed),
    const _PreviewSpec('review', _PreviewScene.review),
    const _PreviewSpec(
      'entry-narrow-large-text',
      _PreviewScene.entry,
      size: Size(320, 844),
      textScale: 1.35,
    ),
    const _PreviewSpec(
      'review-dark',
      _PreviewScene.review,
      brightness: Brightness.dark,
    ),
  ];

  for (final spec in specs) {
    testWidgets('capture ${spec.name}', (tester) async {
      await tester.runAsync(_loadPreviewFonts);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = spec.size;
      addTearDown(tester.view.reset);

      final coordinator = _PreviewMaintenanceCoordinator(_stateFor(spec.scene));
      addTearDown(coordinator.dispose);
      await tester.pumpWidget(_previewApp(spec, coordinator));
      await tester.pump(const Duration(milliseconds: 240));

      expect(tester.takeException(), isNull);
      await _writePng(tester, spec.name, _captureKey);
      await _writePng(tester, '${spec.name}-panel', _surfaceKey);
    });
  }
}

Widget _previewApp(
  _PreviewSpec spec,
  BookSourceMaintenanceCoordinator coordinator,
) {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppThemes.defaultAccentColor,
    brightness: spec.brightness,
  );
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(
      colorScheme: scheme,
      fontFamily: _previewFont,
      useMaterial3: true,
    ),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(spec.textScale)),
        child: RepaintBoundary(
          key: _captureKey,
          child: Scaffold(
            appBar: AppBar(title: const Text('书源管理')),
            body: Stack(
              fit: StackFit.expand,
              children: [
                const _ManagementBackdrop(),
                ModalBarrier(
                  color: Colors.black.withValues(alpha: 0.32),
                  dismissible: false,
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: RepaintBoundary(
                    key: _surfaceKey,
                    child: Material(
                      color: scheme.surface,
                      elevation: 3,
                      clipBehavior: Clip.antiAlias,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: spec.size.height - 72,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _DragHandle(),
                            Flexible(
                              child: _sceneWidget(spec.scene, coordinator),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _sceneWidget(
  _PreviewScene scene,
  BookSourceMaintenanceCoordinator coordinator,
) {
  if (scene == _PreviewScene.entry) {
    return BookSourceMaintenanceSheet(
      maintenance: coordinator,
      sources: _entrySources(),
      selectedSourceIds: const {'sample-b', 'sample-c'},
    );
  }
  if (scene == _PreviewScene.review) {
    final sources = _reviewSources();
    final assessments = sources
        .map(bookSourceMaintenanceAssessment)
        .toList(growable: false);
    return BookSourceCleanupReviewSheet(
      fullyAvailableCount: 1,
      fullyAvailableSources: [sources.first],
      needsAttention: sources.skip(1).toList(growable: false),
      assessments: assessments,
      referencedSourceIds: const {'sample-c'},
    );
  }
  return BookSourceMaintenanceProgressSheet(
    maintenance: coordinator,
    onReview: () {},
  );
}

BookSourceMaintenanceState _stateFor(_PreviewScene scene) {
  return switch (scene) {
    _PreviewScene.entry ||
    _PreviewScene.review => const BookSourceMaintenanceState(),
    _PreviewScene.progress => const BookSourceMaintenanceState(
      status: BookSourceMaintenanceStatus.running,
      runId: 1,
      progress: BookSourceMaintenanceProgress(completed: 37, total: 128),
    ),
    _PreviewScene.cancelling => BookSourceMaintenanceState(
      status: BookSourceMaintenanceStatus.cancelling,
      runId: 2,
      progress: const BookSourceMaintenanceProgress(completed: 38, total: 128),
      result: _maintenanceResult(
        completed: 38,
        remaining: 90,
        sources: _entrySources(),
      ),
    ),
    _PreviewScene.cancelled => BookSourceMaintenanceState(
      status: BookSourceMaintenanceStatus.cancelled,
      runId: 3,
      progress: const BookSourceMaintenanceProgress(completed: 2, total: 5),
      result: _maintenanceResult(completed: 2, remaining: 3),
    ),
    _PreviewScene.failed => BookSourceMaintenanceState(
      status: BookSourceMaintenanceStatus.failed,
      runId: 4,
      progress: const BookSourceMaintenanceProgress(completed: 1, total: 5),
      result: _maintenanceResult(completed: 1, remaining: 4),
      failure: '网络连接中断，请稍后重试。',
    ),
  };
}

BookSourceMaintenanceResult _maintenanceResult({
  required int completed,
  required int remaining,
  List<RegisteredBookSource>? sources,
}) {
  final candidates = sources ?? _reviewSources();
  final completedSources = candidates.take(completed).toList(growable: false);
  final remainingSources = candidates
      .skip(completed)
      .take(remaining)
      .toList(growable: false);
  return BookSourceMaintenanceResult(
    allSources: completedSources,
    assessments: completedSources
        .map(bookSourceMaintenanceAssessment)
        .toList(growable: false),
    remainingSources: remainingSources,
  );
}

List<RegisteredBookSource> _entrySources() => [
  ..._reviewSources(),
  for (var index = 6; index <= 128; index++)
    _checkedSource(
      'sample-$index',
      '示例书源 $index',
      checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
      failed: const {},
      enabled: index <= 110,
    ),
];

List<RegisteredBookSource> _reviewSources() => [
  _checkedSource(
    'sample-a',
    '示例书源 A',
    checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
    failed: const {},
  ),
  _checkedSource(
    'sample-b',
    '示例书源 B',
    checked: const {SourceHealthCapability.search},
    failed: const {},
  ),
  _checkedSource(
    'sample-c',
    '示例书源 C',
    checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
    failed: const {SourceHealthCapability.content},
  ),
  _checkedSource(
    'sample-d',
    '示例书源 D',
    checked: const {},
    failed: const {},
    timedOut: true,
  ),
  _checkedSource(
    'sample-e',
    '示例书源 E',
    checked: const {},
    failed: const {},
    hasResult: false,
  ),
];

RegisteredBookSource _checkedSource(
  String id,
  String name, {
  required Set<SourceHealthCapability> checked,
  required Set<SourceHealthCapability> failed,
  bool timedOut = false,
  bool enabled = true,
  bool hasResult = true,
}) {
  final source = RegisteredBookSource(
    id: id,
    name: name,
    description: '用于界面预览的匿名示例',
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
  if (!hasResult) return source;
  return withSourceHealthCheckResult(
    source,
    SourceHealthCheckResult(
      checked: checked,
      failed: failed,
      checkedAt: DateTime.utc(2026, 9, 5),
      timedOut: timedOut,
    ),
  );
}

Future<void> _writePng(WidgetTester tester, String name, Key key) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('Could not encode preview PNG.');
    final directory = Directory(_outputDirectory)..createSync(recursive: true);
    File('${directory.path}/$name.png').writeAsBytesSync(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  });
}

Future<void> _loadPreviewFonts() async {
  final executable = Platform.resolvedExecutable;
  final marker = '${Platform.pathSeparator}bin${Platform.pathSeparator}cache';
  final markerIndex = executable.indexOf(marker);
  final inferredRoot = markerIndex < 0
      ? null
      : executable.substring(0, markerIndex);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? inferredRoot;
  if (flutterRoot == null) {
    throw StateError('Set FLUTTER_ROOT to load MaterialIcons.');
  }
  final fontCandidates = [
    ?Platform.environment['BOOK_SOURCE_PREVIEW_FONT'],
    '/System/Library/Fonts/PingFang.ttc',
    '/System/Library/Fonts/Hiragino Sans GB.ttc',
    '/System/Library/Fonts/STHeiti Medium.ttc',
  ];
  final fontFile = fontCandidates
      .map(File.new)
      .firstWhere((candidate) => candidate.existsSync());
  final fontBytes = await fontFile.readAsBytes();
  final iconBytes = await File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  await Future.wait([
    (FontLoader(_previewFont)..addFont(
          Future.value(
            ByteData.view(
              fontBytes.buffer,
              fontBytes.offsetInBytes,
              fontBytes.lengthInBytes,
            ),
          ),
        ))
        .load(),
    (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.view(
              iconBytes.buffer,
              iconBytes.offsetInBytes,
              iconBytes.lengthInBytes,
            ),
          ),
        ))
        .load(),
  ]);
}

class _PreviewMaintenanceCoordinator extends BookSourceMaintenanceCoordinator {
  _PreviewMaintenanceCoordinator(this.previewState);

  final BookSourceMaintenanceState previewState;

  @override
  BookSourceMaintenanceState get state => previewState;

  @override
  void cancel() {}
}

class _ManagementBackdrop extends StatelessWidget {
  const _ManagementBackdrop();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 5,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => Card(
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.menu_book_rounded)),
          title: Text('示例书源 ${index + 1}'),
          subtitle: const Text('匿名预览数据'),
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

enum _PreviewScene { entry, progress, cancelling, cancelled, failed, review }

class _PreviewSpec {
  const _PreviewSpec(
    this.name,
    this.scene, {
    this.size = const Size(390, 844),
    this.textScale = 1,
    this.brightness = Brightness.light,
  });

  final String name;
  final _PreviewScene scene;
  final Size size;
  final double textScale;
  final Brightness brightness;
}
