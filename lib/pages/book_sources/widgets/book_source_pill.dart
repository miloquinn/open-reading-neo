import 'package:flutter/material.dart';

import '../../../widgets/glass_control_surface.dart';

/// A theme-aware selection pill with consistent motion and accessibility.
class BookSourcePill extends StatefulWidget {
  static const double pressedScale = 0.97;
  static const Duration pressDuration = Duration(milliseconds: 100);
  static const Duration releaseDuration = Duration(milliseconds: 180);
  static const Duration selectionDuration = Duration(milliseconds: 180);

  const BookSourcePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.icon,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    this.maxLabelWidth = 220,
    this.backgroundColor,
    this.selectedBackgroundColor,
    this.foregroundColor,
    this.selectedForegroundColor,
    this.showSelectedCheck = false,
    this.enableSurface = true,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final IconData? icon;
  final EdgeInsetsGeometry padding;
  final double? maxLabelWidth;
  final Color? backgroundColor;
  final Color? selectedBackgroundColor;
  final Color? foregroundColor;
  final Color? selectedForegroundColor;
  final bool showSelectedCheck;
  final bool enableSurface;

  @override
  State<BookSourcePill> createState() => _BookSourcePillState();
}

class _BookSourcePillState extends State<BookSourcePill> {
  bool _pressed = false;

  void _handleHighlightChanged(bool highlighted) {
    if (_pressed == highlighted) return;
    setState(() => _pressed = highlighted);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onPressed != null;
    final glassEnabled = GlassControlSurface.usesGlass(context);
    final background = widget.selected
        ? widget.selectedBackgroundColor ??
              (glassEnabled ? scheme.primaryContainer : scheme.primary)
        : widget.backgroundColor ?? scheme.secondaryContainer;
    final foreground = widget.selected
        ? widget.selectedForegroundColor ??
              (glassEnabled ? scheme.onPrimaryContainer : scheme.onPrimary)
        : widget.foregroundColor ?? scheme.onSecondaryContainer;
    final labelStyle =
        (Theme.of(context).textTheme.labelLarge ??
                DefaultTextStyle.of(context).style)
            .copyWith(
              color: foreground,
              fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w600,
            );
    final animationDuration = reduceMotion
        ? Duration.zero
        : (_pressed
              ? BookSourcePill.pressDuration
              : BookSourcePill.releaseDuration);
    final control = Material(
      color: Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: widget.onPressed,
        onHighlightChanged: enabled ? _handleHighlightChanged : null,
        focusColor: scheme.primary.withValues(alpha: 0.18),
        hoverColor: scheme.primary.withValues(alpha: 0.08),
        splashColor: scheme.primary.withValues(alpha: 0.14),
        child: Padding(
          padding: widget.padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon case final icon?) ...[
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: widget.maxLabelWidth ?? double.infinity,
                  ),
                  child: AnimatedDefaultTextStyle(
                    duration: reduceMotion
                        ? Duration.zero
                        : BookSourcePill.selectionDuration,
                    curve: Curves.easeOutCubic,
                    style: labelStyle,
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (widget.showSelectedCheck && widget.selected) ...[
                const SizedBox(width: 7),
                Icon(Icons.check_rounded, size: 18, color: foreground),
              ],
            ],
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: enabled,
      focusable: enabled,
      label: widget.label,
      onTap: widget.onPressed,
      child: ExcludeSemantics(
        child: AnimatedScale(
          key: const Key('bookSourcePillScale'),
          scale: _pressed && !reduceMotion ? BookSourcePill.pressedScale : 1,
          duration: animationDuration,
          curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            child: widget.enableSurface
                ? GlassControlSurface(
                    color: background,
                    enabled: enabled,
                    emphasized: widget.selected,
                    duration: reduceMotion
                        ? Duration.zero
                        : BookSourcePill.selectionDuration,
                    curve: Curves.easeOutCubic,
                    child: control,
                  )
                : control,
          ),
        ),
      ),
    );
  }
}
