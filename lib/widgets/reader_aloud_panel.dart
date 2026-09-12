import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/reader/reader_aloud_controller.dart';
import '../services/reader_aloud_service.dart';
import '../pages/settings/cloud_tts_settings_page.dart';
import '../services/tts_service.dart';
import '../services/tts_service_translator.dart';
import '../utils/localization_extension.dart';
import '../utils/reader_themes.dart';
import 'generated_book_cover.dart';
import 'app_menu.dart';

Future<void> showReaderAloudPlayer({
  required BuildContext context,
  required ReaderAloudController controller,
  required TtsService ttsService,
  required ReaderAloudService aloudService,
  required ReaderThemePalette palette,
  required ThemeData themeData,
  String author = '',
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (routeContext) => Theme(
      data: themeData,
      child: ReaderAloudPlayerPage(
        controller: controller,
        ttsService: ttsService,
        aloudService: aloudService,
        palette: palette,
        author: author,
      ),
    ),
  ),
);

Future<void> showReaderAloudSettingsSheet({
  required BuildContext context,
  required ReaderAloudController controller,
  required TtsService ttsService,
  required ReaderAloudService aloudService,
  required ReaderThemePalette palette,
  required ThemeData themeData,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  enableDrag: true,
  showDragHandle: true,
  backgroundColor: palette.controlBar,
  constraints: BoxConstraints(
    maxWidth: 720,
    maxHeight: MediaQuery.sizeOf(context).height * 0.72,
  ),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  clipBehavior: Clip.antiAlias,
  builder: (sheetContext) => Theme(
    data: themeData,
    child: ReaderAloudPanel(
      controller: controller,
      ttsService: ttsService,
      aloudService: aloudService,
      palette: palette,
    ),
  ),
);

/// Kept for callers that still use the former settings-sheet entry point.
@Deprecated('Use showReaderAloudPlayer or showReaderAloudSettingsSheet')
Future<void> showReaderAloudPanelSheet({
  required BuildContext context,
  required ReaderAloudController controller,
  required TtsService ttsService,
  required ReaderAloudService aloudService,
  required ReaderThemePalette palette,
  required ThemeData themeData,
}) => showReaderAloudSettingsSheet(
  context: context,
  controller: controller,
  ttsService: ttsService,
  aloudService: aloudService,
  palette: palette,
  themeData: themeData,
);

class ReaderAloudPlayerPage extends StatefulWidget {
  const ReaderAloudPlayerPage({
    super.key,
    required this.controller,
    required this.ttsService,
    required this.aloudService,
    required this.palette,
    this.author = '',
  });

  final ReaderAloudController controller;
  final TtsService ttsService;
  final ReaderAloudService aloudService;
  final ReaderThemePalette palette;
  final String author;

  @override
  State<ReaderAloudPlayerPage> createState() => _ReaderAloudPlayerPageState();
}

class _ReaderAloudPlayerPageState extends State<ReaderAloudPlayerPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.ttsService.ensureVoicesLoaded());
    unawaited(widget.aloudService.initialize());
    if (!widget.controller.isActive) {
      unawaited(widget.controller.start());
    }
  }

  double? _pendingVolume;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.palette.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            widget.controller,
            widget.ttsService,
            widget.aloudService,
          ]),
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final controller = widget.controller;
              final chapter = controller.currentChapter;
              final palette = widget.palette;
              final wide =
                  constraints.maxWidth >= 700 ||
                  (constraints.maxWidth >= 500 &&
                      constraints.maxWidth > constraints.maxHeight);
              return Center(
                child: SizedBox(
                  width: wide ? 1120 : 560,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Row(
                          children: [
                            _roundButton(
                              key: const ValueKey('reader-aloud-close'),
                              icon: Icons.keyboard_arrow_down_rounded,
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).closeButtonTooltip,
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                children: [
                                  Text(
                                    controller.source.bookTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                          color: palette.text,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                  if (chapter != null)
                                    Text(
                                      chapter.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: palette.secondaryText,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            _roundButton(
                              key: const ValueKey('reader-aloud-timer'),
                              icon: controller.sleepDuration == null
                                  ? Icons.timer_outlined
                                  : Icons.timer_rounded,
                              tooltip: context.l10n.ttsTimerStop,
                              onPressed: _showSettings,
                            ),
                          ],
                        ),
                      ),

                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, body) {
                            // Reserve the controls first; the cover absorbs
                            // differences in screen height and safe areas.
                            final compact = body.maxHeight < 600;
                            final narrowWide = wide && body.maxWidth < 760;
                            return Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: narrowWide ? 16 : (wide ? 32 : 20),
                                vertical: body.maxHeight < 300 ? 4 : 8,
                              ),
                              child: wide
                                  ? Row(
                                      key: const ValueKey(
                                        'reader-aloud-wide-layout',
                                      ),
                                      children: [
                                        Expanded(
                                          flex: narrowWide ? 4 : 5,
                                          child: Center(
                                            child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxHeight: 580,
                                              ),
                                              child: _artworkAndSentence(
                                                compact: compact,
                                                wide: true,
                                              ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(width: narrowWide ? 24 : 40),
                                        Expanded(
                                          flex: narrowWide ? 6 : 5,
                                          child: Center(
                                            child: _playbackControls(
                                              compact: compact,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : Column(
                                      children: [
                                        Expanded(
                                          child: _artworkAndSentence(
                                            compact: compact,
                                            wide: false,
                                          ),
                                        ),
                                        SizedBox(height: compact ? 8 : 16),
                                        _playbackControls(compact: compact),
                                      ],
                                    ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _artworkAndSentence({required bool compact, required bool wide}) {
    final segment = widget.controller.currentSegment;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wide ? 300 : 224,
                  maxHeight: wide ? 420 : 314,
                ),
                child: AspectRatio(
                  aspectRatio: 5 / 7,
                  child: Container(
                    key: const ValueKey('reader-aloud-cover'),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: widget.palette.shadow.withValues(alpha: 0.24),
                          blurRadius: 28,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: GeneratedBookCover(
                      title: widget.controller.source.bookTitle,
                      author: widget.author,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: compact ? 4 : 16),
        SizedBox(
          height:
              MediaQuery.textScalerOf(context).scale(16) *
              1.65 *
              (compact ? 2 : 3),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Text(
                segment?.text ?? context.l10n.ttsReading,
                key: ValueKey(segment?.startOffset),
                maxLines: compact ? 2 : 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 16,
                  color: widget.palette.text,
                  height: 1.65,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _playbackControls({required bool compact}) {
    final controller = widget.controller;
    final chapter = controller.currentChapter;
    final palette = widget.palette;
    final playing = controller.state == ReaderAloudPlaybackState.playing;
    final loading = controller.state == ReaderAloudPlaybackState.loading;
    final volume = _pendingVolume ?? widget.ttsService.speechVolume;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(
          value: controller.chapterProgress,
          minHeight: 4,
          borderRadius: BorderRadius.circular(99),
          color: palette.accent,
          backgroundColor: palette.border.withValues(alpha: 0.42),
        ),
        SizedBox(height: compact ? 8 : 16),
        Row(
          children: [
            Expanded(
              child: _featureButton(
                icon: Icons.speed_rounded,
                label:
                    '${context.l10n.ttsSpeed} ${(widget.ttsService.speechRate * 2).toStringAsFixed(1)}×',
                onPressed: _showSettings,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _featureButton(
                key: const ValueKey('reader-aloud-chapters'),
                icon: Icons.format_list_bulleted_rounded,
                label: context.l10n.currentChapter,
                onPressed: _showChapters,
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 8 : 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _transportButton(
              icon: Icons.first_page_rounded,
              tooltip: context.l10n.tapZonePreviousChapter,
              onPressed: chapter == null || chapter.index == 0
                  ? null
                  : () => unawaited(controller.previousChapter()),
            ),
            _transportButton(
              icon: Icons.fast_rewind_rounded,
              tooltip: context.l10n.ttsPreviousSentence,
              onPressed: () => unawaited(controller.previous()),
            ),
            IconButton.filled(
              key: const ValueKey('reader-aloud-play-pause'),
              tooltip: playing ? context.l10n.pause : context.l10n.play,
              onPressed: loading
                  ? null
                  : () => unawaited(
                      playing
                          ? controller.pause()
                          : controller.state == ReaderAloudPlaybackState.paused
                          ? controller.resume()
                          : controller.start(),
                    ),
              iconSize: compact ? 32 : 38,
              padding: EdgeInsets.all(compact ? 16 : 20),
              style: IconButton.styleFrom(
                backgroundColor: palette.accent,
                foregroundColor: palette.onAccent,
              ),
              icon: loading
                  ? SizedBox.square(
                      dimension: compact ? 32 : 38,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: palette.onAccent,
                      ),
                    )
                  : Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
            ),
            _transportButton(
              icon: Icons.fast_forward_rounded,
              tooltip: context.l10n.ttsNextSentence,
              onPressed: () => unawaited(controller.next()),
            ),
            _transportButton(
              icon: Icons.last_page_rounded,
              tooltip: context.l10n.tapZoneNextChapter,
              onPressed:
                  chapter == null ||
                      chapter.index + 1 >= controller.source.chapterCount
                  ? null
                  : () => unawaited(controller.nextChapter()),
            ),
          ],
        ),
        SizedBox(height: compact ? 4 : 12),
        Row(
          children: [
            Tooltip(
              message: context.l10n.ttsVolume,
              child: Icon(
                volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_down_rounded,
                color: palette.secondaryText,
                size: 22,
              ),
            ),
            Expanded(
              child: Semantics(
                label: context.l10n.ttsVolume,
                child: Slider(
                  key: const ValueKey('reader-aloud-volume'),
                  value: volume,
                  activeColor: palette.accent,
                  inactiveColor: palette.border.withValues(alpha: 0.42),
                  label: '${(volume * 100).round()}%',
                  semanticFormatterCallback: (value) =>
                      '${(value * 100).round()}%',
                  onChanged: (value) => setState(() => _pendingVolume = value),
                  onChangeEnd: (value) => unawaited(_commitVolume(value)),
                ),
              ),
            ),
            Text(
              '${(volume * 100).round()}%',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: palette.secondaryText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        OutlinedButton.icon(
          key: const ValueKey('reader-aloud-engine'),
          onPressed: _showSettings,
          icon: Icon(
            widget.aloudService.usesCloud
                ? Icons.cloud_outlined
                : Icons.record_voice_over_outlined,
            size: 20,
          ),
          label: Text(
            widget.aloudService.usesCloud
                ? _copy('云端朗读引擎', 'Cloud voice', 'クラウド音声')
                : _copy('系统朗读引擎', 'System voice', 'システム音声'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: palette.secondaryText,
            side: BorderSide(color: palette.border),
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          ),
        ),
      ],
    );
  }

  Future<void> _commitVolume(double value) async {
    try {
      await widget.ttsService.setVolume(value);
      if (widget.aloudService.activeEngineType == ReaderAloudEngineType.cloud) {
        await widget.aloudService.syncVolume();
      } else {
        await widget.controller.refreshPlayback();
      }
    } finally {
      if (mounted) setState(() => _pendingVolume = null);
    }
  }

  Widget _roundButton({
    Key? key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) => IconButton.filledTonal(
    key: key,
    onPressed: onPressed,
    tooltip: tooltip,
    icon: Icon(icon),
    style: IconButton.styleFrom(
      backgroundColor: widget.palette.controlFill,
      foregroundColor: widget.palette.text,
    ),
  );

  Widget _featureButton({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => OutlinedButton.icon(
    key: key,
    onPressed: onPressed,
    icon: Icon(icon, size: 22),
    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    style: OutlinedButton.styleFrom(
      foregroundColor: widget.palette.text,
      side: BorderSide(color: widget.palette.border),
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      textStyle: Theme.of(context).textTheme.labelMedium,
    ),
  );

  Widget _transportButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    icon: Icon(icon),
    iconSize: 30,
    color: widget.palette.text,
    disabledColor: widget.palette.secondaryText.withValues(alpha: 0.28),
  );

  Future<void> _showSettings() => showReaderAloudSettingsSheet(
    context: context,
    controller: widget.controller,
    ttsService: widget.ttsService,
    aloudService: widget.aloudService,
    palette: widget.palette,
    themeData: Theme.of(context),
  );

  Future<void> _showChapters() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: widget.palette.controlBar,
      constraints: BoxConstraints(
        maxWidth: 620,
        maxHeight: MediaQuery.sizeOf(context).height * 0.68,
      ),
      builder: (context) => ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        itemCount: widget.controller.source.chapterCount,
        itemBuilder: (context, index) => FutureBuilder<ReaderAloudChapter?>(
          future: widget.controller.source.loadChapter(index),
          builder: (context, snapshot) {
            final chapter = snapshot.data;
            final selected = widget.controller.currentChapter?.index == index;
            return ListTile(
              selected: selected,
              leading: selected
                  ? Icon(Icons.graphic_eq_rounded, color: widget.palette.accent)
                  : SizedBox(
                      width: 24,
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: widget.palette.secondaryText),
                      ),
                    ),
              title: Text(
                chapter?.title ?? context.l10n.readerChapterFallback(index + 1),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: chapter == null
                  ? null
                  : () => Navigator.of(context).pop(index),
            );
          },
        ),
      ),
    );
    if (selected != null && mounted) {
      await widget.controller.playChapter(selected);
    }
  }

  String _copy(String zh, String en, String ja) =>
      switch (Localizations.localeOf(context).languageCode) {
        'en' => en,
        'ja' => ja,
        _ => zh,
      };
}

class ReaderAloudPanel extends StatefulWidget {
  const ReaderAloudPanel({
    super.key,
    required this.controller,
    required this.ttsService,
    required this.aloudService,
    required this.palette,
  });

  final ReaderAloudController controller;
  final TtsService ttsService;
  final ReaderAloudService aloudService;
  final ReaderThemePalette palette;

  @override
  State<ReaderAloudPanel> createState() => _ReaderAloudPanelState();
}

class _ReaderAloudPanelState extends State<ReaderAloudPanel> {
  Timer? _sleepTimerTicker;
  Timer? _speechRateCommitTimer;
  double? _pendingSpeechRate;
  double? _pendingPitch;
  int _speechRateCommitGeneration = 0;
  Future<void> _speechRateCommitChain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    unawaited(widget.ttsService.ensureVoicesLoaded());
    unawaited(widget.aloudService.initialize());
    _sleepTimerTicker = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && widget.controller.sleepRemaining != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sleepTimerTicker?.cancel();
    _speechRateCommitTimer?.cancel();
    _speechRateCommitGeneration++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          widget.controller,
          widget.ttsService,
          widget.aloudService,
        ]),
        builder: (context, _) {
          final controller = widget.controller;
          final tts = widget.ttsService;
          final aloud = widget.aloudService;
          final errorCode = tts.lastError;
          final speechRate = _pendingSpeechRate ?? tts.speechRate;
          final pitch = _pendingPitch ?? tts.speechPitch;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.ttsPanelTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: widget.palette.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                      color: widget.palette.secondaryText,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _engineSelector(context, controller, aloud),
                const SizedBox(height: 20),
                if (aloud.usesCloud)
                  _cloudConfigurationCard(context, aloud)
                else
                  _voicePicker(context, tts, controller),
                const SizedBox(height: 24),
                _slider(
                  context,
                  label: context.l10n.ttsSpeed,
                  value: speechRate,
                  min: 0.1,
                  max: 1,
                  // flutter_tts maps 0.5 to Android's native 1.0 (normal
                  // speed), so show the effective multiplier to the user.
                  valueLabel: '${(speechRate * 2).toStringAsFixed(2)}×',
                  onChanged: (value) {
                    setState(() => _pendingSpeechRate = value);
                    _scheduleSpeechRateCommit(value, controller, tts);
                  },
                  onChangeEnd: (value) => _scheduleSpeechRateCommit(
                    value,
                    controller,
                    tts,
                    delay: Duration.zero,
                  ),
                ),
                if (!aloud.usesCloud)
                  _slider(
                    context,
                    label: context.l10n.ttsPitch,
                    value: pitch,
                    min: 0.5,
                    max: 2,
                    valueLabel: pitch.toStringAsFixed(2),
                    onChanged: (value) => setState(() => _pendingPitch = value),
                    onChangeEnd: (value) =>
                        unawaited(_commitPitch(value, controller, tts)),
                  ),
                const SizedBox(height: 8),
                Divider(color: widget.palette.border.withValues(alpha: 0.5)),
                _sleepTimerCard(context, controller),
                if (errorCode != null ||
                    controller.lastError != null ||
                    aloud.cloudError != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    aloud.cloudError ??
                        (errorCode == null
                            ? context.l10n.ttsPlaybackFailed
                            : translateTtsError(
                                context,
                                errorCode,
                                tts.lastErrorLanguage,
                              )),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _scheduleSpeechRateCommit(
    double value,
    ReaderAloudController controller,
    TtsService tts, {
    Duration delay = const Duration(milliseconds: 180),
  }) {
    final generation = ++_speechRateCommitGeneration;
    _speechRateCommitTimer?.cancel();
    _speechRateCommitTimer = Timer(delay, () {
      // Keep platform-channel calls ordered. If another slider value arrives,
      // the older operation can save its value but must not restart playback.
      _speechRateCommitChain = _speechRateCommitChain
          .then((_) async {
            if (!mounted || generation != _speechRateCommitGeneration) return;
            await tts.setSpeechRate(value);
            if (!mounted || generation != _speechRateCommitGeneration) return;
            await controller.refreshPlayback();
            if (mounted && generation == _speechRateCommitGeneration) {
              setState(() => _pendingSpeechRate = null);
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint('Failed to apply reader speech rate: $error');
            if (mounted && generation == _speechRateCommitGeneration) {
              setState(() => _pendingSpeechRate = null);
            }
          });
    });
  }

  Future<void> _commitPitch(
    double value,
    ReaderAloudController controller,
    TtsService tts,
  ) async {
    try {
      await tts.setPitch(value);
      await controller.refreshPlayback();
    } finally {
      if (mounted) setState(() => _pendingPitch = null);
    }
  }

  Widget _engineSelector(
    BuildContext context,
    ReaderAloudController controller,
    ReaderAloudService aloud,
  ) => SegmentedButton<ReaderAloudEngineType>(
    segments: [
      ButtonSegment(
        value: ReaderAloudEngineType.system,
        icon: const Icon(Icons.phone_android_rounded),
        label: Text(_copy(context, '系统语音', 'System', 'システム音声')),
      ),
      ButtonSegment(
        value: ReaderAloudEngineType.cloud,
        icon: const Icon(Icons.cloud_outlined),
        label: Text(_copy(context, '云端 TTS', 'Cloud TTS', 'クラウド TTS')),
      ),
    ],
    style: SegmentedButton.styleFrom(
      backgroundColor: widget.palette.controlFill.withValues(alpha: 0.5),
      selectedBackgroundColor: widget.palette.accent.withValues(alpha: 0.12),
      selectedForegroundColor: widget.palette.accent,
      foregroundColor: widget.palette.secondaryText,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
    ),
    selected: {aloud.engineType},
    showSelectedIcon: false,
    onSelectionChanged: (selection) {
      final selected = selection.first;
      if (selected == aloud.engineType) return;
      unawaited(() async {
        final resumeAfterChange =
            controller.state == ReaderAloudPlaybackState.playing;
        if (resumeAfterChange) await controller.pause();
        await aloud.setEngineType(selected);
        if (resumeAfterChange) await controller.resume();
      }());
    },
  );

  Widget _cloudConfigurationCard(
    BuildContext context,
    ReaderAloudService aloud,
  ) => Material(
    color: widget.palette.surface.withValues(alpha: 0.72),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      leading: Icon(
        aloud.hasCloudApiKey ? Icons.cloud_done_outlined : Icons.key_outlined,
        color: aloud.hasCloudApiKey
            ? widget.palette.accent
            : widget.palette.secondaryText,
      ),
      title: Text(
        '${aloud.cloudSettings.model} · ${aloud.cloudSettings.voice}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        aloud.hasCloudApiKey
            ? _copy(
                context,
                '管理音色与连接',
                'Voice and connection settings',
                '音声と接続の設定',
              )
            : _copy(context, '配置云端朗读', 'Set up cloud voice', 'クラウド音声を設定'),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => unawaited(_showCloudSettings(context, aloud)),
    ),
  );

  Future<void> _showCloudSettings(
    BuildContext context,
    ReaderAloudService aloud,
  ) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CloudTtsSettingsPage(service: aloud)),
    );
    if (saved == true && mounted) {
      await widget.controller.refreshPlayback();
    }
  }

  String _copy(BuildContext context, String zh, String en, String ja) {
    return switch (Localizations.localeOf(context).languageCode) {
      'en' => en,
      'ja' => ja,
      _ => zh,
    };
  }

  Widget _slider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double>? onChangeEnd,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: widget.palette.text),
              ),
            ),
            Text(
              valueLabel,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: widget.palette.accent,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          label: valueLabel,
          semanticFormatterCallback: (value) => label == context.l10n.ttsSpeed
              ? '${(value * 2).toStringAsFixed(2)}×'
              : value.toStringAsFixed(2),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 16),
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    ),
  );

  Widget _voicePicker(
    BuildContext context,
    TtsService tts,
    ReaderAloudController controller,
  ) {
    final voices = tts.availableVoices;
    final selectedId = voices.any((voice) => voice.id == tts.currentVoice?.id)
        ? tts.currentVoice!.id
        : '';
    final currentVoice = voices
        .where((voice) => voice.id == selectedId)
        .firstOrNull;
    return AppPopupMenuButton<String>(
      key: ValueKey('reader-aloud-voice:$selectedId:${voices.length}'),
      initialValue: selectedId,
      anchorRadius: 12,
      enabled: !tts.isLoadingVoices,
      tooltip: _copy(context, '音色', 'Voice', '音声'),
      color: widget.palette.controlBar,
      itemBuilder: (context) => [
        PopupMenuItem(value: '', child: Text(context.l10n.ttsSystemDefault)),
        for (final voice in voices)
          PopupMenuItem(
            value: voice.id,
            child: Text(
              voice.subtitle.isEmpty
                  ? voice.title
                  : '${voice.title} · ${voice.subtitle}',
            ),
          ),
      ],
      onSelected: (id) {
        unawaited(() async {
          if (id.isEmpty) {
            await tts.clearSelectedVoice();
          } else {
            final voice = voices.where((voice) => voice.id == id).firstOrNull;
            if (voice == null) return;
            await tts.setVoice(voice);
          }
          await controller.refreshPlayback();
        }());
      },
      child: InputDecorator(
        isEmpty: false,
        decoration: InputDecoration(
          labelText: _copy(context, '音色', 'Voice', '音声'),
          enabled: !tts.isLoadingVoices,
          filled: true,
          fillColor: widget.palette.controlFill.withValues(alpha: 0.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                currentVoice == null
                    ? context.l10n.ttsSystemDefault
                    : currentVoice.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.unfold_more_rounded, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _sleepTimerCard(
    BuildContext context,
    ReaderAloudController controller,
  ) {
    final remaining = controller.sleepRemaining;
    return ListTile(
      key: const ValueKey('reader-aloud-sleep-timer-card'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.bedtime_outlined,
        color: remaining == null
            ? widget.palette.secondaryText
            : widget.palette.accent,
      ),
      title: Text(context.l10n.ttsTimerStop),
      subtitle: Text(
        remaining == null
            ? context.l10n.ttsTimerOff
            : _copy(
                context,
                '剩余 ${_formatTimerDuration(context, remaining)}',
                '${_formatTimerDuration(context, remaining)} remaining',
                '残り ${_formatTimerDuration(context, remaining)}',
              ),
      ),
      trailing: remaining == null
          ? const Icon(Icons.chevron_right_rounded)
          : IconButton(
              key: const ValueKey('reader-aloud-sleep-timer-clear'),
              tooltip: context.l10n.ttsTimerOff,
              onPressed: () => controller.setSleepTimer(null),
              icon: const Icon(Icons.close_rounded),
            ),
      onTap: () => unawaited(_showSleepTimerPicker(context, controller)),
    );
  }

  Future<void> _showSleepTimerPicker(
    BuildContext context,
    ReaderAloudController controller,
  ) async {
    final remaining = controller.sleepRemaining;
    final initialMinutes = remaining == null
        ? 30
        : ((remaining.inSeconds + 59) ~/ 60).clamp(1, 1439).toInt();
    var selected = Duration(minutes: initialMinutes);
    final result = await showModalBottomSheet<Duration>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      enableDrag: true,
      showDragHandle: true,
      backgroundColor: widget.palette.controlBar,
      constraints: BoxConstraints(
        maxWidth: 620,
        maxHeight: MediaQuery.sizeOf(context).height * 0.62,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => Theme(
        data: widget.palette.toThemeData(
          typography: Theme.of(context).textTheme,
        ),
        child: StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.l10n.ttsTimerStop,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: widget.palette.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _timerPickerSummary(selected),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: widget.palette.accent,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 154,
                  child: CupertinoTheme(
                    data: CupertinoThemeData(
                      brightness: widget.palette.brightness,
                      primaryColor: widget.palette.accent,
                      textTheme: CupertinoTextThemeData(
                        pickerTextStyle: TextStyle(
                          color: widget.palette.text,
                          fontSize: 22,
                        ),
                      ),
                    ),
                    child: CupertinoTimerPicker(
                      key: const ValueKey('reader-aloud-sleep-timer-picker'),
                      mode: CupertinoTimerPickerMode.hm,
                      initialTimerDuration: selected,
                      minuteInterval: 1,
                      onTimerDurationChanged: (value) =>
                          setSheetState(() => selected = value),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (controller.sleepDuration != null) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              Navigator.of(sheetContext).pop(Duration.zero),
                          child: Text(context.l10n.ttsTimerOff),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('reader-aloud-sleep-timer-confirm'),
                        onPressed: selected > Duration.zero
                            ? () => Navigator.of(sheetContext).pop(selected)
                            : null,
                        icon: const Icon(Icons.bedtime_rounded),
                        label: Text(
                          _copy(context, '开始计时', 'Start timer', 'タイマー開始'),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    controller.setSleepTimer(result > Duration.zero ? result : null);
  }

  String _timerPickerSummary(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    return '${hours.toString().padLeft(2, '0')} : '
        '${minutes.toString().padLeft(2, '0')}';
  }

  String _formatTimerDuration(BuildContext context, Duration value) {
    final roundedMinutes = ((value.inSeconds + 59) ~/ 60)
        .clamp(0, 1439)
        .toInt();
    final hours = roundedMinutes ~/ 60;
    final minutes = roundedMinutes.remainder(60);
    if (hours == 0) {
      return _copy(context, '$minutes 分钟', '$minutes min', '$minutes 分');
    }
    if (minutes == 0) {
      return _copy(context, '$hours 小时', '$hours hr', '$hours 時間');
    }
    return _copy(
      context,
      '$hours 小时 $minutes 分钟',
      '$hours hr $minutes min',
      '$hours 時間 $minutes 分',
    );
  }
}
