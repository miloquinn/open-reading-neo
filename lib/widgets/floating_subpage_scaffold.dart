import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/glass_config.dart';
import '../utils/page_style_helper.dart';
import '../utils/system_ui_helper.dart';
import 'glass_top_bar.dart';

/// Shared navigation shell for pushed secondary pages.
///
/// The page title is centered in a slim glass header matching the home chrome.
/// Navigation and page actions use equal edge hit targets without stacking
/// additional glass surfaces. Search, tabs, and larger page-specific tools stay
/// in the content hierarchy.
class FloatingSubpageScaffold extends StatelessWidget {
  const FloatingSubpageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.tools,
    this.backgroundColor,
    this.decoration,
    this.canPop = true,
    this.onBack,
    this.maxHeaderWidth = 1080,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset,
    this.headerHeight = 60,
    this.showHeader = true,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? tools;
  final Color? backgroundColor;
  final Decoration? decoration;
  final bool canPop;
  final VoidCallback? onBack;
  final double maxHeaderWidth;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomNavigationBar;
  final bool? resizeToAvoidBottomInset;
  final double headerHeight;
  final bool showHeader;

  static double headerExtentOf(
    BuildContext context, {
    double headerHeight = 60,
  }) {
    final contentHeight = headerHeight < 60 ? 60.0 : headerHeight;
    return MediaQuery.viewPaddingOf(context).top + contentHeight;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final systemTopInset = MediaQuery.viewPaddingOf(context).top;
    final chromeContentHeight = headerHeight < 60 ? 60.0 : headerHeight;
    final headerVisible =
        canPop || actions.isNotEmpty || (showHeader && title.trim().isNotEmpty);
    final headerContent = GlassTopBar(
      key: const ValueKey('floating-subpage-header'),
      title: title,
      centerTitle: true,
      systemTopInset: systemTopInset,
      contentHeight: chromeContentHeight,
      titleFontSize: 22,
      centerTitleSideInset:
          ((actions.isEmpty ? 1 : actions.length) * 48).toDouble() + 8,
      leading: canPop
          ? FloatingSubpageAction(
              key: const ValueKey('floating-subpage-back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack ?? () => Navigator.of(context).maybePop(),
              icon: Icons.arrow_back_rounded,
            )
          : const SizedBox.square(dimension: 48),
      trailing: actions.isNotEmpty
          ? Row(mainAxisSize: MainAxisSize.min, children: actions)
          : const SizedBox.square(dimension: 48),
    );
    return _SubpageSystemUi(
      brightness: scheme.brightness,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiHelper.overlayStyleForBrightness(scheme.brightness),
        child: Scaffold(
          backgroundColor: backgroundColor ?? scheme.surface,
          floatingActionButton: floatingActionButton,
          floatingActionButtonLocation: floatingActionButtonLocation,
          bottomNavigationBar: bottomNavigationBar,
          resizeToAvoidBottomInset: resizeToAvoidBottomInset,
          body: DecoratedBox(
            key: const ValueKey('floating-subpage-content-surface'),
            decoration:
                decoration ??
                BoxDecoration(
                  gradient: PageStyleHelper.backgroundGradient(context),
                ),
            child: Stack(
              children: [
                SafeArea(
                  top: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (tools != null) ...[
                        Padding(
                          padding: EdgeInsets.only(
                            top: headerVisible
                                ? headerExtentOf(
                                    context,
                                    headerHeight: headerHeight,
                                  )
                                : 0,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: maxHeaderWidth,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: tools!,
                              ),
                            ),
                          ),
                        ),
                      ],
                      Expanded(child: body),
                    ],
                  ),
                ),
                if (headerVisible)
                  Positioned(left: 0, right: 0, top: 0, child: headerContent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Resolves a scrollable's initial content padding while keeping its viewport
/// underneath the shared glass header.
EdgeInsets floatingSubpagePadding(
  BuildContext context, {
  double left = 16,
  double top = 12,
  double right = 16,
  double bottom = 32,
  double headerHeight = 60,
  bool includeHeader = true,
}) => EdgeInsets.fromLTRB(
  left,
  top +
      (includeHeader
          ? FloatingSubpageScaffold.headerExtentOf(
              context,
              headerHeight: headerHeight,
            )
          : 0),
  right,
  bottom,
);

class _SubpageSystemUi extends StatefulWidget {
  const _SubpageSystemUi({required this.brightness, required this.child});

  final Brightness brightness;
  final Widget child;

  @override
  State<_SubpageSystemUi> createState() => _SubpageSystemUiState();
}

class _SubpageSystemUiState extends State<_SubpageSystemUi> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _apply();
  }

  @override
  void didUpdateWidget(covariant _SubpageSystemUi oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.brightness != widget.brightness) _apply();
  }

  bool get _isCurrentRoute => ModalRoute.of(context)?.isCurrent ?? true;

  void _apply() {
    if (!_isCurrentRoute) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiHelper.overlayStyleForBrightness(widget.brightness),
    );
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _apply();
    });
    return widget.child;
  }
}

class FloatingSubpageAction extends StatelessWidget {
  const FloatingSubpageAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          backgroundColor: scheme.surface.withValues(alpha: 0.2),
          disabledBackgroundColor: scheme.surface.withValues(alpha: 0.12),
          side: BorderSide(
            color: scheme.onSurface.withValues(alpha: 0.16),
            width: 0.8,
          ),
          shape: const CircleBorder(),
          iconSize: 30,
        ),
      ),
    );
  }
}

class FloatingSubpageMenuAction<T> extends StatelessWidget {
  const FloatingSubpageMenuAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
  });

  final IconData icon;
  final String tooltip;
  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = itemBuilder(context)
        .whereType<PopupMenuItem<T>>()
        .map(
          (item) => FloatingSubpageMenuItem<T>(
            value: item.value as T,
            child: item.child ?? const SizedBox.shrink(),
            enabled: item.enabled,
            itemKey: item.key,
          ),
        )
        .toList(growable: false);
    return FloatingSubpageMenuButton<T>(
      tooltip: tooltip,
      icon: icon,
      items: items,
      onSelected: onSelected,
    );
  }
}

class FloatingSubpageMenuItem<T> {
  const FloatingSubpageMenuItem({
    required this.value,
    required this.child,
    this.enabled = true,
    this.itemKey,
  });

  final T value;
  final Widget child;
  final bool enabled;
  final Key? itemKey;
}

class FloatingSubpageMenuButton<T> extends StatelessWidget {
  const FloatingSubpageMenuButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.items,
    required this.onSelected,
  });

  final IconData icon;
  final String tooltip;
  final List<FloatingSubpageMenuItem<T>> items;
  final ValueChanged<T> onSelected;

  Future<void> _show(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final mediaQuery = MediaQuery.of(context);
    final menuWidth = (overlay.size.width - 40).clamp(220.0, 248.0);
    final menuLeft = (topLeft.dx + box.size.width - menuWidth).clamp(
      20.0,
      overlay.size.width - menuWidth - 20,
    );
    final menuTop = topLeft.dy + box.size.height + 10;
    final selected = await showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: mediaQuery.disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 320),
      pageBuilder: (dialogContext, _, _) => Stack(
        children: [
          Positioned(
            left: menuLeft,
            top: menuTop,
            width: menuWidth,
            child: Material(
              color: Colors.transparent,
              child: _FloatingSubpageMenuSurface<T>(
                items: items,
                onSelected: (value) => Navigator.of(dialogContext).pop(value),
              ),
            ),
          ),
        ],
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: animation.drive(
            Tween<double>(
              begin: 0.82,
              end: 1,
            ).chain(CurveTween(curve: const Interval(0, 0.42))),
          ),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.08, -0.08),
              end: Offset.zero,
            ).animate(curved),
            child: ScaleTransition(
              alignment: Alignment.topRight,
              scale: Tween<double>(begin: 0.76, end: 1).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
    if (selected != null && context.mounted) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: IconButton(
      tooltip: tooltip,
      onPressed: () => _show(context),
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: Theme.of(
          context,
        ).colorScheme.surface.withValues(alpha: 0.2),
        side: BorderSide(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.16),
          width: 0.8,
        ),
        shape: const CircleBorder(),
        iconSize: 30,
      ),
    ),
  );
}

class _FloatingSubpageMenuSurface<T> extends StatelessWidget {
  const _FloatingSubpageMenuSurface({
    required this.items,
    required this.onSelected,
  });

  final List<FloatingSubpageMenuItem<T>> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(22);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.16),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: GlassEffectConfig.modalBlur,
            sigmaY: GlassEffectConfig.modalBlur,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: GlassEffectConfig.chromeSurfaceColor(
                context,
                opacity: scheme.brightness == Brightness.light ? 0.78 : 0.64,
              ),
              borderRadius: radius,
              border: Border.all(
                color: scheme.onSurface.withValues(alpha: 0.1),
                width: 0.8,
              ),
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: scheme.onSurfaceVariant),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: scheme.onSurface),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var index = 0; index < items.length; index++) ...[
                        _FloatingSubpageMenuTile(
                          key: items[index].itemKey,
                          item: items[index],
                          onTap: items[index].enabled
                              ? () => onSelected(items[index].value)
                              : null,
                        ),
                        if (index != items.length - 1)
                          Divider(
                            height: 1,
                            indent: 54,
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.45,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingSubpageMenuTile<T> extends StatelessWidget {
  const _FloatingSubpageMenuTile({
    super.key,
    required this.item,
    required this.onTap,
  });

  final FloatingSubpageMenuItem<T> item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: Opacity(
      opacity: onTap == null ? 0.42 : 1,
      child: SizedBox(
        height: 54,
        child: Row(
          children: [
            const SizedBox(width: 4),
            SizedBox.square(
              dimension: 42,
              child: Center(
                child: item.child is ListTile
                    ? (item.child as ListTile).leading
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontWeight: FontWeight.w600),
                child: item.child is ListTile
                    ? (item.child as ListTile).title ?? const SizedBox.shrink()
                    : item.child,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    ),
  );
}
