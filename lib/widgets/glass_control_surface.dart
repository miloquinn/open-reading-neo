import 'dart:ui';

import 'package:flutter/material.dart';

import '../utils/glass_config.dart';
import '../utils/ui_style.dart';

class GlassControlSurface extends StatelessWidget {
  const GlassControlSurface({
    super.key,
    required this.child,
    this.shape = const StadiumBorder(),
    this.color,
    this.enabled = true,
    this.emphasized = false,
    this.useGlass = true,
    this.blurBackground = true,
    this.duration = Duration.zero,
    this.curve = Curves.linear,
  });

  final Widget child;
  final OutlinedBorder shape;
  final Color? color;
  final bool enabled;
  final bool emphasized;
  final bool useGlass;
  final bool blurBackground;
  final Duration duration;
  final Curve curve;

  static bool usesGlass(BuildContext context, {bool useGlass = true}) {
    final theme = Theme.of(context);
    final isMaterial3Style =
        theme.extension<UiStyleThemeExtension>()?.isMaterial3Style ?? false;
    return useGlass &&
        !isMaterial3Style &&
        !GlassEffectConfig.shouldDisableBlur;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = scheme.brightness;
    final glassEnabled = usesGlass(context, useGlass: useGlass);
    final baseColor = color ?? scheme.secondaryContainer;
    final resolvedShape = shape.copyWith(
      side: BorderSide(
        color: _borderColor(
          scheme: scheme,
          brightness: brightness,
          glassEnabled: glassEnabled,
        ),
      ),
    );
    final decoration = glassEnabled
        ? _glassDecoration(
            brightness: brightness,
            baseColor: baseColor,
            shape: resolvedShape,
          )
        : ShapeDecoration(
            color: enabled
                ? baseColor
                : Color.lerp(baseColor, scheme.surface, 0.42),
            shape: resolvedShape,
          );
    final surface = AnimatedContainer(
      duration: duration,
      curve: curve,
      decoration: decoration,
      child: Opacity(opacity: enabled ? 1 : 0.58, child: child),
    );

    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      clipBehavior: Clip.antiAlias,
      child: glassEnabled && blurBackground
          ? BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: GlassEffectConfig.lightCardBlur,
                sigmaY: GlassEffectConfig.lightCardBlur,
              ),
              child: surface,
            )
          : surface,
    );
  }

  ShapeDecoration _glassDecoration({
    required Brightness brightness,
    required Color baseColor,
    required OutlinedBorder shape,
  }) {
    final cleanColor = GlassEffectConfig.chromeBaseColor(
      baseColor,
      brightness,
      lightBlend: brightness == Brightness.light ? 0.18 : 0,
    );
    final highlight = Color.lerp(
      cleanColor,
      Colors.white,
      brightness == Brightness.light ? 0.24 : 0.12,
    )!;
    final opacityScale = enabled ? 1.0 : 0.62;
    final leadingOpacity =
        (brightness == Brightness.light
            ? (emphasized ? 0.82 : 0.68)
            : (emphasized ? 0.66 : 0.52)) *
        opacityScale;
    final trailingOpacity =
        (brightness == Brightness.light
            ? (emphasized ? 0.68 : 0.54)
            : (emphasized ? 0.52 : 0.40)) *
        opacityScale;
    return ShapeDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          highlight.withValues(alpha: leadingOpacity),
          cleanColor.withValues(alpha: trailingOpacity),
        ],
      ),
      shape: shape,
    );
  }

  Color _borderColor({
    required ColorScheme scheme,
    required Brightness brightness,
    required bool glassEnabled,
  }) {
    if (!glassEnabled) {
      return (emphasized ? scheme.primary : scheme.outlineVariant).withValues(
        alpha: enabled ? 0.72 : 0.34,
      );
    }
    final source = emphasized ? scheme.primary : scheme.outlineVariant;
    final highlighted = Color.lerp(
      source,
      Colors.white,
      brightness == Brightness.light ? 0.16 : 0.24,
    )!;
    return highlighted.withValues(
      alpha: enabled ? (emphasized ? 0.62 : 0.42) : 0.24,
    );
  }
}
