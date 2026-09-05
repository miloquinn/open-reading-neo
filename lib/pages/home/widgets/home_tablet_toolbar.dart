import 'package:flutter/material.dart';

/// Clear controls above the tablet's continuous top backdrop.
/// Equal side columns reserve the floating navigation's exact center position.
class HomeTabletToolbar extends StatelessWidget {
  const HomeTabletToolbar({
    super.key,
    required this.title,
    required this.height,
    required this.horizontalPadding,
    this.navigationWidth,
    this.leading,
    this.trailing,
  });

  final String title;
  final double height;
  final double horizontalPadding;
  final double? navigationWidth;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final heading = Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 8)],
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: leading == null ? 30 : 22,
              fontWeight: FontWeight.w700,
              height: 1,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        child: Row(
          children: [
            Expanded(child: heading),
            if (navigationWidth != null) ...[
              SizedBox(width: navigationWidth! + 32),
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: trailing),
              ),
            ] else if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
