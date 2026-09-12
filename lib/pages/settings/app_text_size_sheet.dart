import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/core/app_settings_service.dart';
import '../../utils/localization_extension.dart';

class AppTextSizeSheet extends StatelessWidget {
  const AppTextSizeSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettingsNotifier>();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.appTextSize, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                l10n.appTextSizeDescription,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  l10n.appTextSizePreview,
                  key: const ValueKey('app-text-size-preview'),
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              const SizedBox(height: 12),
              for (
                var level = 0;
                level < AppSettingsNotifier.appTextScaleFactors.length;
                level++
              )
                Semantics(
                  selected: settings.appTextScaleLevel == level,
                  child: ListTile(
                    key: ValueKey('app-text-size-$level'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(
                      level == AppSettingsNotifier.defaultAppTextScaleLevel
                          ? l10n.appTextSizeDefault
                          : '${(AppSettingsNotifier.appTextScaleFactors[level] * 100).round()}%',
                    ),
                    trailing: Icon(
                      settings.appTextScaleLevel == level
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: settings.appTextScaleLevel == level
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => settings.setAppTextScaleLevel(level),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
