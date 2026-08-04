import 'dart:ui';

import 'package:flutter/material.dart';

import '../utils/glass_config.dart';
import '../utils/ui_style.dart';

/// The single glass chrome surface shared by the home shell and pushed pages.
class GlassTopBar extends StatelessWidget {
  const GlassTopBar({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.centerTitle = false,
    this.systemTopInset,
    this.contentHeight = 60,
    this.titleFontSize = 34,
    this.titleFontWeight = FontWeight.w700,
    this.horizontalPadding = 16,
    this.centerTitleSideInset = 56,
  });

  final String title;
  final Widget? leading;
  final Widget? trailing;
  final bool centerTitle;
  final double? systemTopInset;
  final double contentHeight;
  final double titleFontSize;
  final FontWeight titleFontWeight;
  final double horizontalPadding;
  final double centerTitleSideInset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final topInset = systemTopInset ?? MediaQuery.viewPaddingOf(context).top;
    final isMaterial3Style =
        Theme.of(
          context,
        ).extension<UiStyleThemeExtension>()?.isMaterial3Style ??
        false;
    final useBlur = !isMaterial3Style && !GlassEffectConfig.shouldDisableBlur;
    final content = Container(
      key: const ValueKey('glass-top-bar-surface'),
      height: topInset + contentHeight,
      decoration: BoxDecoration(
        color: isMaterial3Style
            ? scheme.surfaceContainerHigh
            : GlassEffectConfig.chromeSurfaceColor(context),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          topInset + 6,
          horizontalPadding,
          6,
        ),
        child: centerTitle
            ? Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: centerTitleSideInset,
                        ),
                        child: Center(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: titleFontSize,
                              fontWeight: titleFontWeight,
                              color: scheme.onSurface,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Align(alignment: Alignment.centerLeft, child: leading),
                  Align(alignment: Alignment.centerRight, child: trailing),
                ],
              )
            : Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 8)],
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: titleFontSize,
                        fontWeight: titleFontWeight,
                        color: scheme.onSurface,
                        height: 1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ?trailing,
                ],
              ),
      ),
    );

    return ClipRect(
      child: useBlur
          ? BackdropFilter(
              enabled: useBlur,
              filter: ImageFilter.blur(
                sigmaX: GlassEffectConfig.appBarBlur,
                sigmaY: GlassEffectConfig.appBarBlur,
              ),
              child: content,
            )
          : content,
    );
  }
}
