import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/core/app_settings_service.dart';

/// Applies the app's five UI sizes to routes and overlays. Reading content
/// continues to use readerBodyTextScaler and its own font-size preference.
class AppTextScale extends StatelessWidget {
  const AppTextScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = context.select<AppSettingsNotifier, double>(
      (settings) => settings.appTextScaleFactor,
    );
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child,
    );
  }
}
