import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/glass_config.dart';
import 'glass_control_surface.dart';

/// Trigger appearance is independent of the shared menu surface and motion.
enum AppMenuButtonStyle { plain, circular }

/// The shared anchored menu. Keep PopupMenuEntry as the data adapter so callers
/// retain their values, disabled states, checked items and section dividers.
class AppPopupMenuButton<T> extends StatefulWidget {
  const AppPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.onCanceled,
    this.initialValue,
    this.tooltip,
    this.icon,
    this.child,
    this.enabled = true,
    this.constraints,
    this.color,
    this.iconSize = 24,
    this.padding = const EdgeInsets.all(8),
    this.anchorRadius,
    this.buttonStyle = AppMenuButtonStyle.plain,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final ValueChanged<T>? onSelected;
  final VoidCallback? onCanceled;
  final T? initialValue;
  final String? tooltip;
  final Widget? icon;
  final Widget? child;
  final bool enabled;
  final BoxConstraints? constraints;
  final Color? color;
  final double iconSize;
  final EdgeInsetsGeometry padding;
  final double? anchorRadius;
  final AppMenuButtonStyle buttonStyle;

  @override
  State<AppPopupMenuButton<T>> createState() => _AppPopupMenuButtonState<T>();
}

class _AppPopupMenuButtonState<T> extends State<AppPopupMenuButton<T>> {
  bool _open = false;

  Future<void> _show() async {
    if (_open || !widget.enabled) return;
    final items = widget.itemBuilder(context);
    if (items.isEmpty) return;
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _open = true);
    try {
      final value = await showAppMenu<T>(
        context: context,
        anchor: anchor,
        items: items,
        initialValue: widget.initialValue,
        constraints: widget.constraints,
        color: widget.color,
        anchorRadius: widget.anchorRadius,
        anchorIcon: widget.child == null
            ? IconTheme.merge(
                data: IconThemeData(size: widget.iconSize),
                child: widget.icon ?? const Icon(Icons.more_vert_rounded),
              )
            : null,
      );
      if (!mounted) return;
      setState(() => _open = false);
      if (value != null) {
        widget.onSelected?.call(value);
      } else {
        widget.onCanceled?.call();
      }
    } finally {
      if (mounted && _open) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tooltip =
        widget.tooltip ?? MaterialLocalizations.of(context).moreButtonTooltip;
    final iconButton = IconButton(
      tooltip: tooltip,
      onPressed: widget.enabled ? _show : null,
      padding: widget.padding,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      iconSize: widget.iconSize,
      icon: widget.icon ?? const Icon(Icons.more_vert_rounded),
    );
    final trigger = widget.child != null
        ? Tooltip(
            message: tooltip,
            child: InkWell(
              onTap: widget.enabled ? _show : null,
              borderRadius: BorderRadius.circular(widget.anchorRadius ?? 24),
              child: widget.child,
            ),
          )
        : widget.buttonStyle == AppMenuButtonStyle.circular
        ? GlassControlSurface(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            shape: const CircleBorder(),
            enabled: widget.enabled,
            child: iconButton,
          )
        : iconButton;
    // Retain the trigger's layout and focus while the route owns its surface.
    return IgnorePointer(
      ignoring: _open,
      child: Opacity(opacity: _open ? 0 : 1, child: trigger),
    );
  }
}

/// [anchor] is in global logical coordinates, like RenderBox.localToGlobal.
/// Resolves only after the reverse transition, before a caller opens another UI.
Future<T?> showAppMenu<T>({
  required BuildContext context,
  required Rect anchor,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  BoxConstraints? constraints,
  Color? color,
  double? anchorRadius,
  Widget? anchorIcon,
}) async {
  if (items.isEmpty) return null;
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final route = _AppMenuRoute<T>(
    anchor: anchor.shift(-overlay.localToGlobal(Offset.zero)),
    items: items,
    initialValue: initialValue,
    constraints: constraints,
    color: color,
    anchorRadius: anchorRadius ?? anchor.shortestSide / 2,
    anchorIcon: anchorIcon,
    media: MediaQuery.of(context),
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  );
  final result = await navigator.push<T>(route);
  await route.completed;
  route.selectedCallback?.call();
  return result;
}

class _AppMenuRoute<T> extends PopupRoute<T> {
  _AppMenuRoute({
    required this.anchor,
    required this.items,
    required this.initialValue,
    required this.constraints,
    required this.color,
    required this.anchorRadius,
    required this.anchorIcon,
    required this.media,
    required this.themes,
    required this.barrierLabel,
  });

  final Rect anchor;
  final List<PopupMenuEntry<T>> items;
  final T? initialValue;
  final BoxConstraints? constraints;
  final Color? color;
  final double anchorRadius;
  final Widget? anchorIcon;
  final MediaQueryData media;
  final CapturedThemes themes;
  VoidCallback? selectedCallback;

  @override
  final String barrierLabel;
  @override
  bool get barrierDismissible => true;
  @override
  Color? get barrierColor => Colors.transparent;
  @override
  Duration get transitionDuration => media.disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 360);
  @override
  Duration get reverseTransitionDuration => media.disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 280);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return themes.wrap(
      MediaQuery(
        data: media,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).pop(),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                FocusScope.of(context).nextFocus(),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                FocusScope.of(context).previousFocus(),
          },
          child: LayoutBuilder(
            builder: (context, viewport) {
              final safe = Rect.fromLTRB(
                media.padding.left + 12,
                media.padding.top + 12,
                viewport.maxWidth - media.padding.right - 12,
                viewport.maxHeight -
                    math.max(media.padding.bottom, media.viewInsets.bottom) -
                    12,
              );
              final availableWidth = math.max(1.0, safe.width);
              final double width = math.min<double>(
                availableWidth,
                math
                    .max(272.0, math.min(anchor.width, 360.0))
                    .clamp(
                      constraints?.minWidth ?? 0.0,
                      constraints?.maxWidth ?? double.infinity,
                    ),
              );
              final geometry = _MenuGeometry(anchor, safe, anchorRadius);
              return CustomSingleChildLayout(
                delegate: _MenuLayout(geometry, width),
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final progress = Curves.easeInOutCubicEmphasized.transform(
                      animation.value,
                    );
                    final clipper = _MenuClipper(geometry, progress);
                    final scheme = Theme.of(context).colorScheme;
                    final reveal = const Interval(
                      0.22,
                      0.82,
                      curve: Curves.easeOut,
                    ).transform(animation.value);
                    return CustomPaint(
                      key: const ValueKey('app-menu-morph-surface'),
                      painter: _MenuShadow(clipper, scheme.shadow, progress),
                      foregroundPainter: _MenuBorder(
                        clipper,
                        scheme.outlineVariant,
                      ),
                      child: ClipPath(
                        clipper: clipper,
                        child: BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX: GlassControlSurface.usesGlass(context)
                                ? GlassEffectConfig.modalBlur
                                : 0,
                            sigmaY: GlassControlSurface.usesGlass(context)
                                ? GlassEffectConfig.modalBlur
                                : 0,
                          ),
                          child: Material(
                            color:
                                color ??
                                scheme.surfaceContainerLow.withValues(
                                  alpha: 0.96,
                                ),
                            child: Stack(
                              children: [
                                IgnorePointer(
                                  ignoring:
                                      animation.status !=
                                      AnimationStatus.completed,
                                  child: Opacity(opacity: reveal, child: child),
                                ),
                                if (anchorIcon != null && progress < 1)
                                  Positioned.fill(
                                    child: CustomSingleChildLayout(
                                      delegate: _AnchorIconLayout(geometry),
                                      child: Opacity(
                                        opacity: (1 - animation.value / 0.24)
                                            .clamp(0.0, 1.0),
                                        child: anchorIcon,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: FocusTraversalGroup(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: _tiles(context),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _tiles(BuildContext context) {
    bool focusAssigned = false;
    return [
      for (final item in items)
        if (item is PopupMenuDivider)
          const Divider(height: 11, indent: 12, endIndent: 12)
        else if (item is PopupMenuItem<T>)
          _AppMenuTile(
            key: item.key,
            item: item,
            selected: item is CheckedPopupMenuItem<T>
                ? item.checked
                : initialValue != null && item.value == initialValue,
            autofocus: item.enabled && !focusAssigned && (focusAssigned = true),
            onTap: item.enabled
                ? () {
                    selectedCallback = item.onTap;
                    Navigator.of(context).pop(item.value);
                  }
                : null,
          ),
    ];
  }
}

class _AppMenuTile<T> extends StatelessWidget {
  const _AppMenuTile({
    super.key,
    required this.item,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });
  final PopupMenuItem<T> item;
  final bool selected;
  final bool autofocus;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = item.child;
    final tile = content is ListTile ? content : null;
    return Semantics(
      selected: selected,
      enabled: item.enabled,
      button: true,
      child: InkWell(
        onTap: onTap,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(14),
        child: Opacity(
          opacity: item.enabled ? 1 : 0.42,
          child: Ink(
            decoration: BoxDecoration(
              color: selected ? scheme.primary.withValues(alpha: 0.09) : null,
              borderRadius: BorderRadius.circular(14),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: math.max(48, item.height)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: scheme.onSurfaceVariant, size: 21),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                    child: Row(
                      children: [
                        if (tile?.leading != null) ...[
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Center(child: tile!.leading),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: tile == null
                              ? content ?? const SizedBox.shrink()
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    tile.title ?? const SizedBox.shrink(),
                                    if (tile.subtitle != null) tile.subtitle!,
                                  ],
                                ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.check_rounded,
                            color: scheme.primary,
                            size: 19,
                          ),
                        ] else if (tile?.trailing != null)
                          tile!.trailing!,
                      ],
                    ),
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

class _MenuGeometry {
  const _MenuGeometry(this.anchor, this.safe, this.radius);
  final Rect anchor;
  final Rect safe;
  final double radius;

  Offset position(Size size) {
    final x = (anchor.right - size.width).clamp(
      safe.left,
      math.max(safe.left, safe.right - size.width),
    );
    // Grow down from a top action; grow upward from a bottom list action.
    final y =
        (anchor.top + size.height <= safe.bottom
                ? anchor.top
                : anchor.bottom - size.height)
            .clamp(safe.top, math.max(safe.top, safe.bottom - size.height));
    return Offset(x.toDouble(), y.toDouble());
  }

  RRect shape(Size size, double progress) {
    final origin = anchor.shift(-position(size));
    final rect = Rect.lerp(origin, Offset.zero & size, progress)!;
    return RRect.fromRectAndRadius(
      rect,
      Radius.circular(lerpDouble(radius, 22, progress)!),
    );
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.geometry, this.width);
  final _MenuGeometry geometry;
  final double width;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: math.max(1, geometry.safe.height),
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      geometry.position(childSize);
  @override
  bool shouldRelayout(covariant _MenuLayout oldDelegate) => true;
}

class _AnchorIconLayout extends SingleChildLayoutDelegate {
  _AnchorIconLayout(this.geometry);
  final _MenuGeometry geometry;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tight(geometry.anchor.size);
  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      geometry.anchor.topLeft - geometry.position(size);
  @override
  bool shouldRelayout(covariant _AnchorIconLayout oldDelegate) => true;
}

class _MenuClipper extends CustomClipper<Path> {
  _MenuClipper(this.geometry, this.progress);
  final _MenuGeometry geometry;
  final double progress;
  @override
  Path getClip(Size size) => Path()..addRRect(geometry.shape(size, progress));
  @override
  bool shouldReclip(covariant _MenuClipper oldClipper) => true;
}

class _MenuShadow extends CustomPainter {
  _MenuShadow(this.clipper, this.color, this.progress);
  final _MenuClipper clipper;
  final Color color;
  final double progress;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawShadow(
    clipper.getClip(size),
    color.withValues(alpha: 0.2 * progress),
    12 * progress,
    true,
  );
  @override
  bool shouldRepaint(covariant _MenuShadow oldDelegate) => true;
}

class _MenuBorder extends CustomPainter {
  _MenuBorder(this.clipper, this.color);
  final _MenuClipper clipper;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    clipper.getClip(size),
    Paint()
      ..color = color.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8,
  );
  @override
  bool shouldRepaint(covariant _MenuBorder oldDelegate) => true;
}
