import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/reader/reader_leaf_status.dart';
import '../core/reader/reader_auto_page_turn_controller.dart';
import '../utils/glass_config.dart';
import '../utils/localization_extension.dart';
import '../utils/reader_themes.dart';
import 'reader_top_information_bar.dart';

typedef ReaderStatusBuilder =
    Widget Function(BuildContext context, TextStyle? style, Key? key);

class ReaderChromeOverlay extends StatelessWidget {
  const ReaderChromeOverlay({
    super.key,
    required this.palette,
    required this.visible,
    required this.title,
    required this.statusBottom,
    required this.statusBuilder,
    required this.onBack,
    required this.onBookmark,
    required this.onTableOfContents,
    required this.onSettings,
    this.onSearch,
    this.searchTooltip,
    required this.backTooltip,
    required this.bookmarkTooltip,
    required this.tableOfContentsTooltip,
    required this.settingsTooltip,
    required this.bookmarked,
    this.onReadAloud,
    this.readAloudTooltip,
    this.readAloudActive = false,
    this.onAskAi,
    this.askAiTooltip,
    this.onChangeSource,
    this.changeSourceTooltip,
    this.onEditChapter,
    this.editChapterTooltip,
    this.bookmarkBusy = false,
    this.topKey,
    this.bottomKey,
    this.statusKey,
    this.showViewportStatus = true,
    this.showViewportTitle = false,
    this.viewportTitleTop = 0,
    this.viewportTitleKey,
    this.readerStatus,
    this.viewportStatusAlignment = Alignment.centerRight,
    this.viewportStatusHorizontalPadding = 14,
    this.showSettingsAction = true,
    this.autoPageTurnController,
    this.onResumeAutoPageTurn,
  });

  final ReaderThemePalette palette;
  final bool visible;
  final String title;
  final double statusBottom;
  final ReaderStatusBuilder statusBuilder;
  final VoidCallback onBack;
  final VoidCallback? onBookmark;
  final VoidCallback? onTableOfContents;
  final VoidCallback onSettings;
  final VoidCallback? onSearch;
  final String? searchTooltip;
  final VoidCallback? onReadAloud;
  final VoidCallback? onAskAi;
  final String? askAiTooltip;
  final VoidCallback? onChangeSource;
  final String? changeSourceTooltip;
  final VoidCallback? onEditChapter;
  final String? editChapterTooltip;
  final String backTooltip;
  final String bookmarkTooltip;
  final String tableOfContentsTooltip;
  final String settingsTooltip;
  final String? readAloudTooltip;
  final bool bookmarked;
  final bool readAloudActive;
  final bool bookmarkBusy;
  final Key? topKey;
  final Key? bottomKey;
  final Key? statusKey;
  final bool showViewportStatus;
  final bool showViewportTitle;
  final double viewportTitleTop;
  final Key? viewportTitleKey;
  final ReaderLeafStatusData? readerStatus;
  final AlignmentGeometry viewportStatusAlignment;
  final double viewportStatusHorizontalPadding;
  final bool showSettingsAction;
  final ReaderAutoPageTurnController? autoPageTurnController;
  final VoidCallback? onResumeAutoPageTurn;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final chromeDuration = reducedMotion
        ? Duration.zero
        : Duration(milliseconds: visible ? 300 : 420);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showViewportTitle)
          Positioned(
            left: 30,
            right: 30,
            top: viewportTitleTop,
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: viewportTitleKey,
                opacity: visible ? 0 : 1,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: ReaderTopInformationBar(
                  palette: palette,
                  title: title,
                  status: readerStatus,
                ),
              ),
            ),
          ),
        if (showViewportStatus)
          Positioned(
            left: 0,
            right: 0,
            bottom: statusBottom,
            child: IgnorePointer(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: viewportStatusHorizontalPadding,
                ),
                child: Align(
                  alignment: viewportStatusAlignment,
                  child: statusBuilder(
                    context,
                    textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      height: 1,
                      color: palette.secondaryText.withValues(
                        alpha: visible ? 0 : 0.58,
                      ),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    statusKey,
                  ),
                ),
              ),
            ),
          ),
        if (!showViewportStatus && statusKey != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: statusBottom,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: 0,
                  child: statusBuilder(context, null, statusKey),
                ),
              ),
            ),
          ),
        AnimatedPositioned(
          key: topKey,
          duration: chromeDuration,
          curve: Curves.easeOutCubic,
          left: 20,
          right: 20,
          top: visible ? 10 : -130,
          child: IgnorePointer(
            ignoring: !visible,
            child: ExcludeSemantics(
              excluding: !visible,
              child: SafeArea(
                bottom: false,
                child: ReaderControlBar(
                  palette: palette,
                  isTopBar: true,
                  child: SizedBox(
                    height: 58,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 7,
                      ),
                      child: Row(
                        children: [
                          ReaderControlIconButton(
                            palette: palette,
                            onPressed: onBack,
                            tooltip: backTooltip,
                            icon: Icons.arrow_back_rounded,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              title,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.1,
                                color: palette.text,
                              ),
                            ),
                          ),
                          ReaderControlIconButton(
                            palette: palette,
                            onPressed: bookmarkBusy ? null : onBookmark,
                            tooltip: bookmarkTooltip,
                            icon: bookmarked
                                ? Icons.bookmark_rounded
                                : Icons.bookmark_border_rounded,
                          ),
                          if (onChangeSource != null || onEditChapter != null)
                            PopupMenuButton<String>(
                              key: const ValueKey('reader-more-menu'),
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).moreButtonTooltip,
                              color: palette.background,
                              icon: Icon(
                                Icons.more_horiz_rounded,
                                color: palette.text,
                              ),
                              onSelected: (value) {
                                if (value == 'change-source') {
                                  onChangeSource?.call();
                                } else if (value == 'edit-chapter') {
                                  onEditChapter?.call();
                                }
                              },
                              itemBuilder: (context) => [
                                if (onEditChapter != null)
                                  PopupMenuItem(
                                    value: 'edit-chapter',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.edit_note_rounded),
                                        const SizedBox(width: 12),
                                        Text(editChapterTooltip ?? ''),
                                      ],
                                    ),
                                  ),
                                if (onChangeSource != null)
                                  PopupMenuItem(
                                    value: 'change-source',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.swap_horiz_rounded),
                                        const SizedBox(width: 12),
                                        Text(changeSourceTooltip ?? ''),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        AnimatedPositioned(
          key: bottomKey,
          duration: chromeDuration,
          curve: Curves.easeOutCubic,
          left: 22,
          right: 22,
          bottom: visible ? 16 : -110,
          child: IgnorePointer(
            ignoring: !visible,
            child: ExcludeSemantics(
              excluding: !visible,
              child: SafeArea(
                top: false,
                child: ReaderControlBar(
                  palette: palette,
                  isTopBar: false,
                  child: SizedBox(
                    height: 64,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ReaderControlIconButton(
                            palette: palette,
                            onPressed: onTableOfContents,
                            tooltip: tableOfContentsTooltip,
                            icon: Icons.format_list_bulleted_rounded,
                          ),
                          if (onSearch != null)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onSearch,
                              tooltip: searchTooltip ?? '',
                              icon: Icons.search_rounded,
                            ),
                          if (onReadAloud != null)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onReadAloud,
                              tooltip: readAloudTooltip ?? '',
                              icon: readAloudActive
                                  ? Icons.graphic_eq_rounded
                                  : Icons.headphones_rounded,
                            ),
                          if (onAskAi != null)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onAskAi,
                              tooltip: askAiTooltip ?? '',
                              icon: Icons.auto_awesome_outlined,
                            ),
                          if (showSettingsAction)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onSettings,
                              tooltip: settingsTooltip,
                              icon: Icons.tune_rounded,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (autoPageTurnController != null)
          _ReaderAutoPageTurnControl(
            palette: palette,
            controller: autoPageTurnController!,
            chromeVisible: visible,
            onResume: onResumeAutoPageTurn,
          ),
        if (autoPageTurnController != null)
          AnimatedBuilder(
            animation: autoPageTurnController!,
            builder: (context, _) {
              final shown = visible && autoPageTurnController!.shortcutVisible;
              return AnimatedPositioned(
                key: const ValueKey('reader-auto-page-turn-shortcut-slide'),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : Duration(milliseconds: shown ? 300 : 420),
                curve: Curves.easeOutCubic,
                right: shown ? 8 + MediaQuery.paddingOf(context).right : -72,
                top: MediaQuery.sizeOf(context).height * 0.56,
                child: IgnorePointer(
                  ignoring: !shown,
                  child: ExcludeSemantics(
                    excluding: !shown,
                    child: _ReaderAutoPageTurnShortcut(
                      palette: palette,
                      controller: autoPageTurnController!,
                      onResume: onResumeAutoPageTurn,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _ReaderAutoPageTurnControl extends StatefulWidget {
  const _ReaderAutoPageTurnControl({
    required this.palette,
    required this.controller,
    required this.chromeVisible,
    required this.onResume,
  });

  final ReaderThemePalette palette;
  final ReaderAutoPageTurnController controller;
  final bool chromeVisible;
  final VoidCallback? onResume;

  @override
  State<_ReaderAutoPageTurnControl> createState() =>
      _ReaderAutoPageTurnControlState();
}

class _ReaderAutoPageTurnControlState extends State<_ReaderAutoPageTurnControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 420),
    value: widget.controller.isActive ? 1 : 0,
  );
  late final CurvedAnimation _motion = CurvedAnimation(
    parent: _reveal,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  Timer? _hideTimer;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controllerChanged();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animateVisibility();
  }

  @override
  void didUpdateWidget(covariant _ReaderAutoPageTurnControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _controllerChanged();
    }
    if (!oldWidget.chromeVisible && widget.chromeVisible) {
      _showTemporarily();
    }
  }

  void _animateVisibility() {
    final shown = widget.controller.isActive && !_hidden;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _reveal.value = shown ? 1 : 0;
    } else if (shown) {
      _reveal.forward();
    } else {
      _reveal.reverse();
    }
  }

  void _controllerChanged() {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() => _hidden = false);
    _animateVisibility();
    if (!widget.controller.isActive || !widget.controller.isRunning) return;
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && widget.controller.isRunning) {
        setState(() => _hidden = true);
        _animateVisibility();
      }
    });
  }

  void _showTemporarily() {
    _controllerChanged();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_controllerChanged);
    _motion.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final textTheme = Theme.of(context).textTheme;
    final mode = controller.mode;
    final modeLabel = switch (mode) {
      ReaderAutoPageTurnMode.timed => context.l10n.readerAutoPageTurnModeTimed,
      ReaderAutoPageTurnMode.sweep => context.l10n.readerAutoPageTurnModeSweep,
      ReaderAutoPageTurnMode.continuous =>
        context.l10n.readerAutoPageTurnModeContinuous,
      ReaderAutoPageTurnMode.interval =>
        context.l10n.readerAutoPageTurnModeInterval,
    };
    final summary = controller.isRunning
        ? context.l10n.readerAutoPageTurnModeValue(
            modeLabel,
            controller.secondsFor(mode).round(),
          )
        : context.l10n.readerAutoPageTurnModePaused(
            modeLabel,
            controller.secondsFor(mode).round(),
          );
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, child) {
        if (_reveal.isDismissed && !controller.isActive) {
          return const SizedBox.shrink();
        }
        return AnimatedPositioned(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          left: 22,
          right: 22,
          bottom: widget.chromeVisible ? 96 : 16,
          child: IgnorePointer(
            ignoring: !controller.isActive || _hidden,
            child: ExcludeSemantics(
              excluding: !controller.isActive || _hidden,
              // Keep glass out of opacity save layers so it samples the page
              // throughout the animation. Travel beyond the bar and its shadow.
              child: Transform.translate(
                offset: Offset(
                  0,
                  (1 - _motion.value) *
                      (96 + MediaQuery.paddingOf(context).bottom + 80),
                ),
                child: child,
              ),
            ),
          ),
        );
      },
      child: SafeArea(
        top: false,
        child: ReaderControlBar(
          key: const ValueKey('reader-auto-page-turn-control-bar'),
          palette: widget.palette,
          isTopBar: false,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Icon(_modeIcon(mode), size: 20, color: widget.palette.text),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelLarge?.copyWith(
                        color: widget.palette.text,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey(
                      controller.isRunning
                          ? 'reader-auto-page-turn-pause'
                          : 'reader-auto-page-turn-resume',
                    ),
                    onPressed: controller.isRunning
                        ? () => controller.pause(smooth: true)
                        : (widget.onResume ?? controller.start),
                    tooltip: controller.isRunning
                        ? context.l10n.pause
                        : context.l10n.readerAutoPageTurnResume,
                    icon: Icon(
                      controller.isRunning
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    color: widget.palette.text,
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    key: const ValueKey('reader-auto-page-turn-stop'),
                    onPressed: controller.stop,
                    tooltip: context.l10n.stop,
                    icon: const Icon(Icons.stop_rounded),
                    color: widget.palette.text,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _modeIcon(ReaderAutoPageTurnMode mode) => switch (mode) {
    ReaderAutoPageTurnMode.timed => Icons.av_timer_rounded,
    ReaderAutoPageTurnMode.sweep => Icons.vertical_align_bottom_rounded,
    ReaderAutoPageTurnMode.continuous => Icons.south_rounded,
    ReaderAutoPageTurnMode.interval => Icons.keyboard_double_arrow_down_rounded,
  };
}

class _ReaderAutoPageTurnShortcut extends StatelessWidget {
  const _ReaderAutoPageTurnShortcut({
    required this.palette,
    required this.controller,
    this.onResume,
  });

  final ReaderThemePalette palette;
  final ReaderAutoPageTurnController controller;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final running = controller.isRunning;
      final duration = MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 280);
      return AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: palette.controlBar.withValues(alpha: running ? 0.96 : 0.8),
          border: Border.all(
            color: palette.text.withValues(alpha: running ? 0.22 : 0.1),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: IconButton(
          key: const ValueKey('reader-auto-page-turn-shortcut'),
          tooltip: running
              ? context.l10n.pause
              : controller.isActive
              ? context.l10n.readerAutoPageTurnResume
              : context.l10n.readerAutoPageTurnStart,
          onPressed: running
              ? () => controller.pause(smooth: true)
              : (onResume ?? controller.start),
          color: palette.text,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          icon: AnimatedSwitcher(
            duration: duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: Icon(
              running ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey(running),
              size: 22,
            ),
          ),
        ),
      );
    },
  );
}

class ReaderControlBar extends StatelessWidget {
  const ReaderControlBar({
    super.key,
    required this.palette,
    required this.isTopBar,
    required this.child,
    this.borderRadius,
  });

  final ReaderThemePalette palette;
  final bool isTopBar;
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final effectiveBorderRadius = borderRadius ?? BorderRadius.circular(999);
    final blurEnabled = !GlassEffectConfig.shouldDisableBlur;
    // 不叠加预设，直接使用与悬浮导航栏/首页顶栏一致的标准玻璃参数
    final config = GlassEffectHelper.getReadingControlConfig(
      isTopBar: isTopBar,
      brightness: palette.brightness,
    );
    final surfaceOpacity = blurEnabled ? config['opacity']! : 1.0;
    final cleanSurface = blurEnabled
        ? GlassEffectConfig.chromeBaseColor(
            palette.controlBar,
            palette.brightness,
            lightBlend: 0.28,
          )
        : palette.controlBar;
    final highlight = blurEnabled
        ? Color.lerp(
            cleanSurface,
            Colors.white,
            palette.brightness == Brightness.dark ? 0.06 : 0.1,
          )!
        : cleanSurface;
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: effectiveBorderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            highlight.withValues(
              alpha: (surfaceOpacity + (blurEnabled ? 0.08 : 0.0)).clamp(
                0.0,
                1.0,
              ),
            ),
            cleanSurface.withValues(
              alpha: (surfaceOpacity - (blurEnabled ? 0.02 : 0.0)).clamp(
                0.0,
                1.0,
              ),
            ),
          ],
        ),
        border: Border.all(
          color: blurEnabled
              ? Color.lerp(
                  palette.border,
                  Colors.white,
                  palette.brightness == Brightness.dark ? 0.16 : 0.14,
                )!.withValues(
                  alpha: palette.brightness == Brightness.light ? 0.28 : 0.54,
                )
              : palette.border,
          width: 1,
        ),
      ),
      child: Material(color: Colors.transparent, child: child),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: effectiveBorderRadius,
        boxShadow: [
          BoxShadow(
            color: blurEnabled
                ? GlassEffectConfig.chromeShadowColor(
                    source: palette.shadow,
                    brightness: palette.brightness,
                    darkOpacity: 0.46,
                  )
                : palette.shadow.withValues(
                    alpha: palette.brightness == Brightness.dark ? 0.46 : 0.22,
                  ),
            blurRadius: blurEnabled && palette.brightness == Brightness.light
                ? 24
                : 32,
            spreadRadius: -5,
            offset: Offset(
              0,
              blurEnabled && palette.brightness == Brightness.light ? 8 : 16,
            ),
          ),
          if (!blurEnabled || palette.brightness == Brightness.dark)
            BoxShadow(
              color: palette.shadow.withValues(alpha: 0.10),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: effectiveBorderRadius,
        child: blurEnabled
            ? BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: config['blur']!,
                  sigmaY: config['blur']!,
                ),
                child: panel,
              )
            : panel,
      ),
    );
  }
}

class ReaderControlIconButton extends StatelessWidget {
  const ReaderControlIconButton({
    super.key,
    required this.palette,
    required this.onPressed,
    required this.tooltip,
    required this.icon,
  });

  final ReaderThemePalette palette;
  final VoidCallback? onPressed;
  final String tooltip;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final glassEnabled = !GlassEffectConfig.shouldDisableBlur;
    final cleanControlFill = glassEnabled
        ? GlassEffectConfig.chromeBaseColor(
            palette.controlFill,
            palette.brightness,
            lightBlend: 0.22,
          )
        : palette.controlFill;
    return IconButton.filledTonal(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 22),
      style: IconButton.styleFrom(
        foregroundColor: palette.text,
        backgroundColor: cleanControlFill.withValues(
          alpha: glassEnabled
              ? (palette.brightness == Brightness.light ? 0.76 : 0.58)
              : 1.0,
        ),
        minimumSize: const Size.square(44),
        maximumSize: const Size.square(44),
        padding: EdgeInsets.zero,
        side: BorderSide(
          color: glassEnabled
              ? Color.lerp(palette.border, Colors.white, 0.12)!.withValues(
                  alpha: palette.brightness == Brightness.light ? 0.28 : 0.48,
                )
              : palette.border,
          width: 0.8,
        ),
        shape: const CircleBorder(),
      ),
    );
  }
}
