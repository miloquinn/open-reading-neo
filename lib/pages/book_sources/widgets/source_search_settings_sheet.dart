// 文件说明：聚合搜索页的设置面板，调整并发数、单源超时与书源数量上限。
// 技术要点：Flutter 半屏 ModalBottomSheet、滑块。

import 'package:flutter/material.dart';
import 'package:xxread/book_sources/services/book_source_search_settings.dart';
import 'package:xxread/utils/localization_extension.dart';

/// 展示搜索参数设置面板；每次滑块松手都会通过 [onChanged] 实时回传最新值，
/// 由调用方负责应用并持久化，因此拖动手势关闭面板时无需额外处理。
Future<void> showSourceSearchSettingsSheet({
  required BuildContext context,
  required BookSourceSearchSettings settings,
  required int enabledSourceCount,
  required ValueChanged<BookSourceSearchSettings> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxWidth: 720),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (sheetContext) => _SourceSearchSettingsSheet(
      initial: settings,
      enabledSourceCount: enabledSourceCount,
      onChanged: onChanged,
    ),
  );
}

class _SourceSearchSettingsSheet extends StatefulWidget {
  const _SourceSearchSettingsSheet({
    required this.initial,
    required this.enabledSourceCount,
    required this.onChanged,
  });

  final BookSourceSearchSettings initial;
  final int enabledSourceCount;
  final ValueChanged<BookSourceSearchSettings> onChanged;

  @override
  State<_SourceSearchSettingsSheet> createState() =>
      _SourceSearchSettingsSheetState();
}

class _SourceSearchSettingsSheetState
    extends State<_SourceSearchSettingsSheet> {
  late BookSourceSearchSettings _settings = widget.initial;

  void _commit(BookSourceSearchSettings updated) {
    setState(() => _settings = updated);
    widget.onChanged(updated);
  }

  void _resetDefaults() => _commit(BookSourceSearchSettings.defaults);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final overLimit = widget.enabledSourceCount > _settings.sourceLimit;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.bookSourcesSearchSettingsTitle,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            _SettingsSlider(
              sliderKey: const Key('bookSourceSearchConcurrencySlider'),
              icon: Icons.bolt_rounded,
              label: l10n.bookSourcesSearchConcurrencyLabel,
              value: _settings.maxConcurrentSearches.toDouble(),
              min: BookSourceSearchSettings.minConcurrency.toDouble(),
              max: BookSourceSearchSettings.maxConcurrency.toDouble(),
              onChanged: (value) => _commit(
                _settings.copyWith(maxConcurrentSearches: value.round()),
              ),
            ),
            _SettingsSlider(
              sliderKey: const Key('bookSourceSearchTimeoutSlider'),
              icon: Icons.timer_outlined,
              label: l10n.bookSourcesSearchTimeoutLabel,
              value: _settings.perSourceSearchTimeout.inSeconds.toDouble(),
              min: BookSourceSearchSettings.minTimeoutSeconds.toDouble(),
              max: BookSourceSearchSettings.maxTimeoutSeconds.toDouble(),
              onChanged: (value) => _commit(
                _settings.copyWith(
                  perSourceSearchTimeout: Duration(seconds: value.round()),
                ),
              ),
            ),
            _SettingsSlider(
              sliderKey: const Key('bookSourceSearchSourceLimitSlider'),
              icon: Icons.travel_explore_outlined,
              label: l10n.bookSourcesSearchSourceLimitLabel,
              value: _settings.sourceLimit.toDouble(),
              min: BookSourceSearchSettings.minSourceLimit.toDouble(),
              max: BookSourceSearchSettings.maxSourceLimit.toDouble(),
              divisions:
                  (BookSourceSearchSettings.maxSourceLimit -
                      BookSourceSearchSettings.minSourceLimit) ~/
                  20,
              onChanged: (value) =>
                  _commit(_settings.copyWith(sourceLimit: value.round())),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.bookSourcesSearchSourceLimitDescription,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            if (overLimit) ...[
              const SizedBox(height: 10),
              Text(
                l10n.bookSourcesSearchSourceLimitWarning(
                  widget.enabledSourceCount,
                  _settings.sourceLimit,
                ),
                style: TextStyle(color: scheme.error, height: 1.4),
              ),
            ],
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _resetDefaults,
                child: Text(l10n.bookSourcesSearchResetDefaults),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSlider extends StatelessWidget {
  const _SettingsSlider({
    required this.sliderKey,
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final Key sliderKey;
  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        SizedBox(width: 128, child: Text(label)),
        Expanded(
          child: Slider(
            key: sliderKey,
            value: value,
            min: min,
            max: max,
            divisions: divisions ?? (max - min).round(),
            label: value.round().toString(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
