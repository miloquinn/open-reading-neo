// 文件说明：整页图片阅读器共用骨架（漫画 CBZ/CBT/CBR 与 PDF 共用）。
// 技术要点：PageView 翻页 + InteractiveViewer 双击/双指缩放（缩放中锁翻页）；
// 复用共享 3×3 点击区域（RTL 下镜像列）、Android 音量键翻页与屏幕常亮；
// 控制层提供上/下一页、进度滑条、跳页输入、按书持久化的阅读方向
// 与页面背景设置；页数据由调用方按需提供并自行缓存。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/core/reader/paged_image_reader_settings.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';
import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/core/reader/reader_tap_zones.dart';
import 'package:xxread/core/reader/reader_volume_key_controller.dart';
import 'package:xxread/pages/reader/image/image_reader_chrome.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_settings_controls.dart';
import 'package:xxread/widgets/reader_theme_background.dart';

/// 单页图片阅读器：加载、翻页、缩放、点击区域、页码指示与跳页。
///
/// [loadPage] 返回某页的图片字节；调用方负责缓存（重复调用应命中缓存）。
/// 翻页后会对相邻页调用 [loadPage] 做预载，结果丢弃、错误忽略。
/// [bookId] 用于按书持久化阅读方向；为 null 时方向仅在会话内生效。
class PagedImageReader extends StatefulWidget {
  const PagedImageReader({
    super.key,
    required this.title,
    required this.pageCount,
    required this.initialPage,
    required this.loadPage,
    this.onPageChanged,
    this.bookId,
    this.settingsId,
    this.palette,
    this.defaultDirection = ImageReaderDirection.ltr,
    this.onRetryPage,
    this.onReachedEnd,
    this.onReachedStart,
    this.onTableOfContents,
    this.onDirectionChanged,
    this.backgroundOverride,
    this.onSettings,
  });

  final String title;
  final int pageCount;
  final int initialPage;
  final Future<Uint8List> Function(int index, {bool preload}) loadPage;
  final ValueChanged<int>? onPageChanged;
  final int? bookId;

  /// Stable string identity for non-local books (online source + book ID).
  final String? settingsId;
  final ReaderThemePalette? palette;
  final ImageReaderDirection defaultDirection;
  final Future<void> Function(int index)? onRetryPage;
  final VoidCallback? onReachedEnd;
  final VoidCallback? onReachedStart;
  final VoidCallback? onTableOfContents;
  final Future<void> Function(ImageReaderDirection direction)?
  onDirectionChanged;
  final ImageReaderBackground? backgroundOverride;
  final VoidCallback? onSettings;

  @override
  State<PagedImageReader> createState() => _PagedImageReaderState();
}

class _PagedImageReaderState extends State<PagedImageReader> {
  late final PageController _pageController;
  final ItemScrollController _verticalItemController = ItemScrollController();
  final ItemPositionsListener _verticalPositions =
      ItemPositionsListener.create();
  late int _currentPage;
  bool _chromeVisible = false;
  bool _boundaryHandled = false;

  /// 任一页处于放大状态时禁用 PageView 滑动，把手势留给平移。
  bool _zoomed = false;

  static const _settingsStore = PagedImageReaderSettingsStore();
  ReaderTapZones _tapZones = ReaderTapZones.defaults;
  late ImageReaderDirection _direction = widget.defaultDirection;
  ImageReaderBackground _background = ImageReaderBackground.black;

  ReaderThemePalette get _palette => widget.palette ?? ReaderThemes.pureBlack;
  bool get _vertical => _direction == ImageReaderDirection.vertical;
  bool get _rtl => _direction == ImageReaderDirection.rtl;

  @override
  void initState() {
    super.initState();
    _background = widget.backgroundOverride ?? ImageReaderBackground.black;
    _currentPage = widget.initialPage.clamp(0, widget.pageCount - 1);
    _pageController = PageController(initialPage: _currentPage);
    _verticalPositions.itemPositions.addListener(_handleVerticalPositions);
    _preloadAround(_currentPage);
    unawaited(_restoreSettings());
    unawaited(ReaderKeepScreenOnController.activate(this));
    unawaited(_activateVolumeKeys());
  }

  @override
  void didUpdateWidget(covariant PagedImageReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    final background = widget.backgroundOverride;
    if (background != null && background != oldWidget.backgroundOverride) {
      _background = background;
    }
  }

  @override
  void dispose() {
    unawaited(ReaderVolumeKeyController.deactivate(this));
    unawaited(ReaderKeepScreenOnController.deactivate(this));
    _verticalPositions.itemPositions.removeListener(_handleVerticalPositions);
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _restoreSettings() async {
    final zones = await const ReaderSettingsStore().loadTapZones();
    final direction = widget.settingsId == null
        ? await _settingsStore.loadDirection(
            widget.bookId,
            fallback: widget.defaultDirection,
          )
        : await _settingsStore.loadDirectionForKey(
            widget.settingsId,
            fallback: widget.defaultDirection,
          );
    final background =
        widget.backgroundOverride ?? await _settingsStore.loadBackground();
    if (!mounted) return;
    final directionChanged = _direction != direction;
    setState(() {
      _tapZones = zones;
      _direction = direction;
      _background = background;
    });
    if (directionChanged && direction == ImageReaderDirection.vertical) {
      _scheduleVerticalJump(_currentPage);
    }
  }

  Future<void> _activateVolumeKeys() {
    return ReaderVolumeKeyController.activate(
      owner: this,
      pageTurningAvailable: true,
      onNextPage: _goToNextPage,
      onPreviousPage: _goToPreviousPage,
    );
  }

  void _preloadAround(int index) {
    for (final neighbor in <int>[index + 1, index - 1, index + 2]) {
      if (neighbor < 0 || neighbor >= widget.pageCount) continue;
      unawaited(
        widget
            .loadPage(neighbor, preload: true)
            .then((_) {}, onError: (Object _) {}),
      );
    }
  }

  void _onPageChanged(int index) {
    _setCurrentPage(index);
  }

  void _setCurrentPage(int index) {
    final target = index.clamp(0, widget.pageCount - 1);
    if (target == _currentPage) return;
    _boundaryHandled = false;
    setState(() => _currentPage = target);
    _preloadAround(target);
    widget.onPageChanged?.call(target);
  }

  void _scheduleVerticalJump(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_verticalItemController.isAttached) return;
      _verticalItemController.jumpTo(index: index, alignment: 0);
    });
  }

  void _handleVerticalPositions() {
    if (!_vertical || !mounted) return;
    final positions = _verticalPositions.itemPositions.value;
    if (positions.isEmpty) return;
    final visible = positions.where(
      (position) =>
          position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1,
    );
    if (visible.isEmpty) return;
    final nearest = visible.reduce((left, right) {
      final leftDistance = left.itemLeadingEdge.abs();
      final rightDistance = right.itemLeadingEdge.abs();
      return leftDistance <= rightDistance ? left : right;
    });
    _setCurrentPage(nearest.index);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollEndNotification) _boundaryHandled = false;
    if (notification is! OverscrollNotification || _boundaryHandled) {
      return false;
    }
    if (_currentPage == 0 && widget.onReachedStart != null) {
      _boundaryHandled = true;
      widget.onReachedStart!();
    } else if (_currentPage == widget.pageCount - 1 &&
        widget.onReachedEnd != null) {
      _boundaryHandled = true;
      widget.onReachedEnd!();
    }
    return false;
  }

  void _setZoomed(bool zoomed) {
    if (_zoomed == zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  void _goToPage(int index, {bool animate = true}) {
    final target = index.clamp(0, widget.pageCount - 1);
    if (target == _currentPage) return;
    if (_vertical) {
      if (!_verticalItemController.isAttached) return;
      if (animate) {
        unawaited(
          _verticalItemController.scrollTo(
            index: target,
            alignment: 0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
      } else {
        _verticalItemController.jumpTo(index: target, alignment: 0);
      }
      return;
    }
    if (!_pageController.hasClients) return;
    if (animate) {
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _pageController.jumpToPage(target);
    }
  }

  void _goToNextPage() {
    if (_currentPage >= widget.pageCount - 1) {
      widget.onReachedEnd?.call();
      return;
    }
    _goToPage(_currentPage + 1);
  }

  void _goToPreviousPage() {
    if (_currentPage <= 0) {
      widget.onReachedStart?.call();
      return;
    }
    _goToPage(_currentPage - 1);
  }

  void _handleTap(Offset position, Size size) {
    if (_chromeVisible) {
      setState(() => _chromeVisible = false);
      return;
    }
    // RTL 时镜像列：默认「左列上一页」在日漫方向下自然变成「点左边翻下一页」。
    final lookup = _rtl
        ? Offset(size.width - position.dx, position.dy)
        : position;
    switch (_tapZones.actionAt(lookup, size)) {
      case ReaderTapZoneAction.previousPage:
        _goToPreviousPage();
      case ReaderTapZoneAction.nextPage:
        _goToNextPage();
      case ReaderTapZoneAction.menu:
        setState(() => _chromeVisible = true);
      case ReaderTapZoneAction.previousChapter:
      case ReaderTapZoneAction.nextChapter:
      case ReaderTapZoneAction.none:
        // 整页图片书没有章节结构，章节动作与无操作一样忽略。
        break;
    }
  }

  Future<void> _setDirection(ImageReaderDirection direction) async {
    if (_direction == direction) return;
    final onDirectionChanged = widget.onDirectionChanged;
    if (onDirectionChanged != null) {
      await onDirectionChanged(direction);
      return;
    }
    setState(() => _direction = direction);
    if (direction == ImageReaderDirection.vertical) {
      _scheduleVerticalJump(_currentPage);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _pageController.jumpToPage(_currentPage);
      });
    }
    if (widget.settingsId == null) {
      await _settingsStore.saveDirection(widget.bookId, direction);
    } else {
      await _settingsStore.saveDirectionForKey(widget.settingsId, direction);
    }
  }

  Future<void> _setBackground(ImageReaderBackground background) async {
    setState(() => _background = background);
    await _settingsStore.saveBackground(background);
  }

  Future<void> _showSettingsSheet() async {
    final l10n = context.l10n;
    final prefs = await SharedPreferences.getInstance();
    var keepScreenOn =
        prefs.getBool(ReaderKeepScreenOnController.preferenceKey) ?? false;
    var volumeKeys =
        prefs.getBool(ReaderVolumeKeyController.preferenceKey) ?? true;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => ReaderSettingsSheetFrame(
          palette: _palette,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.imageReaderSettings,
                style: TextStyle(
                  color: _palette.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              _SheetSectionLabel(text: l10n.imageReaderDirectionTitle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _SheetChoiceChip(
                    label: l10n.imageReaderDirectionVertical,
                    selected: _vertical,
                    onTap: () async {
                      await _setDirection(ImageReaderDirection.vertical);
                      setSheetState(() {});
                    },
                  ),
                  _SheetChoiceChip(
                    label: l10n.imageReaderDirectionLtr,
                    selected: _direction == ImageReaderDirection.ltr,
                    onTap: () async {
                      await _setDirection(ImageReaderDirection.ltr);
                      setSheetState(() {});
                    },
                  ),
                  _SheetChoiceChip(
                    label: l10n.imageReaderDirectionRtl,
                    selected: _rtl,
                    onTap: () async {
                      await _setDirection(ImageReaderDirection.rtl);
                      setSheetState(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SheetSectionLabel(text: l10n.imageReaderBackgroundTitle),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final background in ImageReaderBackground.values) ...[
                    _SheetChoiceChip(
                      label: switch (background) {
                        ImageReaderBackground.black =>
                          l10n.imageReaderBackgroundBlack,
                        ImageReaderBackground.gray =>
                          l10n.imageReaderBackgroundGray,
                        ImageReaderBackground.white =>
                          l10n.imageReaderBackgroundWhite,
                      },
                      swatch: background.color,
                      selected: _background == background,
                      onTap: () async {
                        await _setBackground(background);
                        setSheetState(() {});
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  l10n.settingsKeepScreenOnTitle,
                  style: TextStyle(color: _palette.text, fontSize: 14),
                ),
                subtitle: Text(
                  l10n.settingsKeepScreenOnSubtitle,
                  style: TextStyle(color: _palette.secondaryText, fontSize: 12),
                ),
                value: keepScreenOn,
                onChanged: (value) async {
                  setSheetState(() => keepScreenOn = value);
                  await ReaderKeepScreenOnController.setPreference(value);
                  await ReaderKeepScreenOnController.reapply(this);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  l10n.settingsVolumeKeyTurnTitle,
                  style: TextStyle(color: _palette.text, fontSize: 14),
                ),
                subtitle: Text(
                  l10n.settingsVolumeKeyTurnSubtitle,
                  style: TextStyle(color: _palette.secondaryText, fontSize: 12),
                ),
                value: volumeKeys,
                onChanged: (value) async {
                  setSheetState(() => volumeKeys = value);
                  await prefs.setBool(
                    ReaderVolumeKeyController.preferenceKey,
                    value,
                  );
                  await _activateVolumeKeys();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _background.color,
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) =>
                    _handleTap(details.localPosition, constraints.biggest),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: _vertical
                      ? ScrollablePositionedList.builder(
                          initialScrollIndex: _currentPage,
                          itemScrollController: _verticalItemController,
                          itemPositionsListener: _verticalPositions,
                          itemCount: widget.pageCount,
                          padding: EdgeInsets.zero,
                          itemBuilder: (context, index) => _ContinuousImagePage(
                            key: ValueKey('continuous-image-$index'),
                            pageIndex: index,
                            loadPage: widget.loadPage,
                            onRetry: widget.onRetryPage,
                            lightBackground: _background.isLight,
                          ),
                        )
                      : PageView.builder(
                          controller: _pageController,
                          reverse: _rtl,
                          physics: _zoomed
                              ? const NeverScrollableScrollPhysics()
                              : const PageScrollPhysics(),
                          itemCount: widget.pageCount,
                          onPageChanged: _onPageChanged,
                          itemBuilder: (context, index) => _ZoomablePageView(
                            pageIndex: index,
                            loadPage: widget.loadPage,
                            onRetry: widget.onRetryPage,
                            onZoomChanged: _setZoomed,
                            lightBackground: _background.isLight,
                          ),
                        ),
                ),
              ),
            ),
          ),
          ImageReaderChrome(
            palette: _palette,
            visible: _chromeVisible,
            title: widget.title,
            pageIndex: _currentPage,
            pageCount: widget.pageCount,
            directionIcon: _vertical
                ? Icons.swap_vert_rounded
                : Icons.swap_horiz_rounded,
            directionLabel: switch (_direction) {
              ImageReaderDirection.vertical =>
                context.l10n.imageReaderDirectionVertical,
              ImageReaderDirection.ltr => context.l10n.imageReaderDirectionLtr,
              ImageReaderDirection.rtl => context.l10n.imageReaderDirectionRtl,
            },
            onBack: () {
              BookOpenTransition.beginExit();
              Navigator.of(context).maybePop();
            },
            onPageSelected: (index) => _goToPage(index, animate: false),
            onTableOfContents: widget.onTableOfContents,
            onDirection: () => unawaited(
              _setDirection(
                _vertical
                    ? ImageReaderDirection.ltr
                    : ImageReaderDirection.vertical,
              ),
            ),
            onSettings: widget.onSettings ?? _showSettingsSheet,
          ),
        ],
      ),
    );
  }
}

class _SheetSectionLabel extends StatelessWidget {
  const _SheetSectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        color: palette.onSurfaceVariant,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// 设置面板的选择胶囊；[swatch] 可选显示色样圆点。
class _SheetChoiceChip extends StatelessWidget {
  const _SheetChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.swatch,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? swatch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.14)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (swatch != null) ...[
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white38),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? scheme.primary : scheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContinuousImagePage extends StatefulWidget {
  const _ContinuousImagePage({
    super.key,
    required this.pageIndex,
    required this.loadPage,
    required this.onRetry,
    required this.lightBackground,
  });

  final int pageIndex;
  final Future<Uint8List> Function(int index, {bool preload}) loadPage;
  final Future<void> Function(int index)? onRetry;
  final bool lightBackground;

  @override
  State<_ContinuousImagePage> createState() => _ContinuousImagePageState();
}

class _ContinuousImagePageState extends State<_ContinuousImagePage> {
  late Future<Uint8List> _bytes = widget.loadPage(widget.pageIndex);
  int _retrySerial = 0;

  Future<void> _retry() async {
    final serial = ++_retrySerial;
    await widget.onRetry?.call(widget.pageIndex);
    if (!mounted || serial != _retrySerial) return;
    final next = widget.loadPage(widget.pageIndex);
    setState(() {
      _bytes = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final placeholderColor = widget.lightBackground
        ? Colors.black26
        : Colors.white38;
    final progressColor = widget.lightBackground
        ? Colors.black26
        : Colors.white24;
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          comicDebugLog(
            'page-bytes',
            'failed page=${widget.pageIndex + 1} mode=vertical',
            error: snapshot.error,
            stackTrace: snapshot.stackTrace,
          );
          return _PageFailure(
            color: placeholderColor,
            onRetry: _retry,
            minHeight: 360,
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return SizedBox(
            height: 360,
            child: Center(
              child: CircularProgressIndicator(color: progressColor),
            ),
          );
        }
        return Image.memory(
          data,
          width: double.infinity,
          fit: BoxFit.fitWidth,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            comicDebugLog(
              'image-decode',
              'failed page=${widget.pageIndex + 1} bytes=${data.length} mode=vertical',
              error: error,
              stackTrace: stackTrace,
            );
            return _PageFailure(
              color: placeholderColor,
              onRetry: _retry,
              minHeight: 360,
            );
          },
        );
      },
    );
  }
}

/// 单页视图：加载中转圈，加载后 InteractiveViewer 支持双击/双指缩放。
class _ZoomablePageView extends StatefulWidget {
  const _ZoomablePageView({
    required this.pageIndex,
    required this.loadPage,
    required this.onRetry,
    required this.onZoomChanged,
    required this.lightBackground,
  });

  final int pageIndex;
  final Future<Uint8List> Function(int index, {bool preload}) loadPage;
  final Future<void> Function(int index)? onRetry;
  final ValueChanged<bool> onZoomChanged;
  final bool lightBackground;

  @override
  State<_ZoomablePageView> createState() => _ZoomablePageViewState();
}

class _ZoomablePageViewState extends State<_ZoomablePageView> {
  final TransformationController _transform = TransformationController();
  TapDownDetails? _doubleTapDetails;
  late Future<Uint8List> _bytes = widget.loadPage(widget.pageIndex);
  int _retrySerial = 0;

  @override
  void didUpdateWidget(covariant _ZoomablePageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageIndex != widget.pageIndex ||
        oldWidget.loadPage != widget.loadPage) {
      _bytes = widget.loadPage(widget.pageIndex);
      _transform.value = Matrix4.identity();
      widget.onZoomChanged(false);
    }
  }

  Future<void> _retry() async {
    final serial = ++_retrySerial;
    await widget.onRetry?.call(widget.pageIndex);
    if (!mounted || serial != _retrySerial) return;
    final next = widget.loadPage(widget.pageIndex);
    setState(() {
      _bytes = next;
    });
  }

  @override
  void dispose() {
    widget.onZoomChanged(false);
    _transform.dispose();
    super.dispose();
  }

  void _reportZoom() {
    widget.onZoomChanged(_transform.value.getMaxScaleOnAxis() > 1.02);
  }

  void _handleDoubleTap() {
    if (_transform.value.getMaxScaleOnAxis() > 1.02) {
      _transform.value = Matrix4.identity();
    } else {
      final position = _doubleTapDetails?.localPosition;
      const scale = 2.4;
      if (position != null) {
        _transform.value = Matrix4.identity()
          ..translateByDouble(
            -position.dx * (scale - 1),
            -position.dy * (scale - 1),
            0,
            1,
          )
          ..scaleByDouble(scale, scale, scale, 1);
      }
    }
    _reportZoom();
  }

  @override
  Widget build(BuildContext context) {
    final placeholderColor = widget.lightBackground
        ? Colors.black26
        : Colors.white38;
    final progressColor = widget.lightBackground
        ? Colors.black26
        : Colors.white24;
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          comicDebugLog(
            'page-bytes',
            'failed page=${widget.pageIndex + 1}',
            error: snapshot.error,
            stackTrace: snapshot.stackTrace,
          );
          return _PageFailure(color: placeholderColor, onRetry: _retry);
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return Center(child: CircularProgressIndicator(color: progressColor));
        }
        return GestureDetector(
          onDoubleTapDown: (details) => _doubleTapDetails = details,
          onDoubleTap: _handleDoubleTap,
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 1,
            maxScale: 5,
            onInteractionEnd: (_) => _reportZoom(),
            child: Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) {
                  comicDebugLog(
                    'image-decode',
                    'failed page=${widget.pageIndex + 1} bytes=${bytes.length}',
                    error: error,
                    stackTrace: stackTrace,
                  );
                  return _PageFailure(color: placeholderColor, onRetry: _retry);
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PageFailure extends StatelessWidget {
  const _PageFailure({
    required this.color,
    required this.onRetry,
    this.minHeight,
  });

  final Color color;
  final Future<void> Function() onRetry;
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight ?? 120),
      child: Center(
        child: OutlinedButton.icon(
          onPressed: () => unawaited(onRetry()),
          icon: Icon(Icons.refresh_rounded, color: color),
          label: Text(context.l10n.retry, style: TextStyle(color: color)),
        ),
      ),
    );
  }
}

/// 打开失败 / 无内容时的全屏提示页。
class PagedReaderMessageScaffold extends StatelessWidget {
  const PagedReaderMessageScaffold({
    super.key,
    required this.title,
    required this.message,
    required this.palette,
    this.onRetry,
  });

  final String title;
  final String message;
  final ReaderThemePalette palette;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: palette.toThemeData(typography: Theme.of(context).textTheme),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ReaderThemeBackground(
          palette: palette,
          child: SafeArea(
            child: Stack(
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: palette.text, height: 1.4),
                        ),
                        if (onRetry != null) ...[
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: onRetry,
                            icon: const Icon(Icons.refresh_rounded),
                            label: Text(context.l10n.retry),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  top: 10,
                  child: Material(
                    color: palette.surface.withValues(alpha: 0.88),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(Icons.arrow_back_rounded, color: palette.text),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
