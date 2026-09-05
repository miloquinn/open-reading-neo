import 'package:flutter/material.dart';

import '../core/reader/reader_auto_page_turn_controller.dart';
import '../utils/localization_extension.dart';
import '../utils/reader_themes.dart';
import 'reader_settings_controls.dart';

Future<ReaderAutoPageTurnSelection?> showReaderAutoPageTurnSheet({
  required BuildContext context,
  required ReaderThemePalette palette,
  required ReaderAutoPageTurnController controller,
  bool vertical = false,
}) => showModalBottomSheet<ReaderAutoPageTurnSelection>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  builder: (context) => _ReaderAutoPageTurnSheet(
    palette: palette,
    controller: controller,
    vertical: vertical,
  ),
);

class _ReaderAutoPageTurnSheet extends StatefulWidget {
  const _ReaderAutoPageTurnSheet({
    required this.palette,
    required this.controller,
    required this.vertical,
  });

  final ReaderThemePalette palette;
  final ReaderAutoPageTurnController controller;
  final bool vertical;

  @override
  State<_ReaderAutoPageTurnSheet> createState() =>
      _ReaderAutoPageTurnSheetState();
}

class _ReaderAutoPageTurnSheetState extends State<_ReaderAutoPageTurnSheet> {
  late ReaderAutoPageTurnMode _mode = widget.controller.modeFor(
    widget.vertical,
  );
  late final Map<ReaderAutoPageTurnMode, double> _seconds = {
    for (final mode in ReaderAutoPageTurnMode.values)
      mode: widget.controller.secondsFor(mode),
  };

  List<ReaderAutoPageTurnMode> get _modes => widget.vertical
      ? const [
          ReaderAutoPageTurnMode.continuous,
          ReaderAutoPageTurnMode.interval,
        ]
      : const [ReaderAutoPageTurnMode.timed, ReaderAutoPageTurnMode.sweep];

  @override
  Widget build(BuildContext context) {
    final textTheme = widget.palette
        .toThemeData(typography: Theme.of(context).textTheme)
        .textTheme;
    final seconds = _seconds[_mode]!;
    final roundedSeconds = seconds.round();
    return ReaderSettingsSheetFrame(
      palette: widget.palette,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.readerAutoPageTurnTitle,
            style: textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(_hint(context, _mode), style: textTheme.bodySmall),
          const SizedBox(height: 16),
          SegmentedButton<ReaderAutoPageTurnMode>(
            key: const ValueKey('reader-auto-page-turn-mode-selector'),
            segments: [
              for (final mode in _modes)
                ButtonSegment<ReaderAutoPageTurnMode>(
                  value: mode,
                  label: Text(_modeLabel(context, mode)),
                ),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: (selected) {
              setState(() => _mode = selected.single);
            },
          ),
          const SizedBox(height: 14),
          _AutoPageTurnPreview(mode: _mode, palette: widget.palette),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: Text(_parameterLabel(context, _mode))),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  context.l10n.readerAutoPageTurnSecondsPerScreen(
                    roundedSeconds,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
          Slider(
            key: const ValueKey('reader-auto-page-turn-interval-slider'),
            value: seconds,
            min: ReaderAutoPageTurnController.minIntervalSeconds.toDouble(),
            max: ReaderAutoPageTurnController.maxIntervalSeconds.toDouble(),
            divisions:
                (ReaderAutoPageTurnController.maxIntervalSeconds -
                    ReaderAutoPageTurnController.minIntervalSeconds) ~/
                5,
            label: context.l10n.readerAutoPageTurnSecondsPerScreen(
              roundedSeconds,
            ),
            onChanged: (value) => setState(() => _seconds[_mode] = value),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('reader-auto-page-turn-start'),
            onPressed: () => Navigator.of(
              context,
            ).pop(ReaderAutoPageTurnSelection(mode: _mode, seconds: seconds)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(context.l10n.readerAutoPageTurnStart),
          ),
        ],
      ),
    );
  }
}

String _modeLabel(BuildContext context, ReaderAutoPageTurnMode mode) =>
    switch (mode) {
      ReaderAutoPageTurnMode.timed => context.l10n.readerAutoPageTurnModeTimed,
      ReaderAutoPageTurnMode.sweep => context.l10n.readerAutoPageTurnModeSweep,
      ReaderAutoPageTurnMode.continuous =>
        context.l10n.readerAutoPageTurnModeContinuous,
      ReaderAutoPageTurnMode.interval =>
        context.l10n.readerAutoPageTurnModeInterval,
    };

String _hint(BuildContext context, ReaderAutoPageTurnMode mode) =>
    switch (mode) {
      ReaderAutoPageTurnMode.timed => context.l10n.readerAutoPageTurnTimedHint,
      ReaderAutoPageTurnMode.sweep => context.l10n.readerAutoPageTurnSweepHint,
      ReaderAutoPageTurnMode.continuous =>
        context.l10n.readerAutoPageTurnContinuousHint,
      ReaderAutoPageTurnMode.interval =>
        context.l10n.readerAutoPageTurnIntervalHint,
    };

String _parameterLabel(BuildContext context, ReaderAutoPageTurnMode mode) =>
    switch (mode) {
      ReaderAutoPageTurnMode.timed || ReaderAutoPageTurnMode.interval =>
        context.l10n.readerAutoPageTurnIntervalLabel,
      ReaderAutoPageTurnMode.sweep =>
        context.l10n.readerAutoPageTurnSweepDurationLabel,
      ReaderAutoPageTurnMode.continuous =>
        context.l10n.readerAutoPageTurnScrollSpeedLabel,
    };

class _AutoPageTurnPreview extends StatefulWidget {
  const _AutoPageTurnPreview({required this.mode, required this.palette});

  final ReaderAutoPageTurnMode mode;
  final ReaderThemePalette palette;

  @override
  State<_AutoPageTurnPreview> createState() => _AutoPageTurnPreviewState();
}

class _AutoPageTurnPreviewState extends State<_AutoPageTurnPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation
        ..stop()
        ..value = 0.45;
    } else if (!_animation.isAnimating && _animation.value == 0) {
      _animation.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _AutoPageTurnPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode &&
        !MediaQuery.disableAnimationsOf(context)) {
      _animation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('reader-auto-page-turn-preview'),
    height: 72,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: widget.palette.surface.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: widget.palette.secondaryText.withValues(alpha: 0.18),
      ),
    ),
    child: AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final progress = _animation.value;
        final offset = widget.mode == ReaderAutoPageTurnMode.continuous
            ? -18.0 * progress
            : widget.mode == ReaderAutoPageTurnMode.interval
            ? -18.0 * (progress > 0.65 ? (progress - 0.65) / 0.35 : 0)
            : 0.0;
        return Stack(
          children: [
            Transform.translate(
              offset: Offset(0, offset),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(
                    4,
                    (index) => Container(
                      width: index.isEven ? 190 : 150,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 7),
                      decoration: BoxDecoration(
                        color: widget.palette.text.withValues(alpha: 0.24),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.mode == ReaderAutoPageTurnMode.sweep)
              Positioned(
                left: 0,
                right: 0,
                top: 70 * progress,
                child: Container(
                  height: 1,
                  decoration: BoxDecoration(
                    color: widget.palette.accent.withValues(alpha: 0.65),
                    boxShadow: [
                      BoxShadow(
                        color: widget.palette.accent.withValues(alpha: 0.18),
                        blurRadius: 3,
                      ),
                    ],
                  ),
                ),
              ),
            if (widget.mode == ReaderAutoPageTurnMode.timed)
              Positioned(
                right: 14,
                bottom: 10,
                child: Icon(
                  Icons.skip_next_rounded,
                  size: 20,
                  color: widget.palette.accent.withValues(
                    alpha: progress > 0.78 ? 1 : 0.35,
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
