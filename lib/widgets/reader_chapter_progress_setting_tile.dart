import 'package:flutter/material.dart';

import '../core/reader/reader_settings.dart';
import '../utils/localization_extension.dart';

class ReaderChapterProgressSettingTile extends StatelessWidget {
  const ReaderChapterProgressSettingTile({
    super.key,
    required this.style,
    required this.onChanged,
  });

  final ReaderChapterProgressStyle style;
  final ValueChanged<ReaderChapterProgressStyle> onChanged;

  String _label(BuildContext context, ReaderChapterProgressStyle style) =>
      switch (style) {
        ReaderChapterProgressStyle.hidden =>
          context.l10n.readerChapterProgressHidden,
        ReaderChapterProgressStyle.fraction =>
          context.l10n.readerChapterProgressFraction(158, 168),
        ReaderChapterProgressStyle.remaining =>
          context.l10n.readerChapterProgressRemaining(158),
      };

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('reader-chapter-progress-tile'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.format_list_numbered_rounded),
    title: Text(context.l10n.readerChapterProgressTitle),
    subtitle: Text(_label(context, style)),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      final selected = await showModalBottomSheet<ReaderChapterProgressStyle>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(context.l10n.readerChapterProgressTitle)),
              RadioGroup<ReaderChapterProgressStyle>(
                groupValue: style,
                onChanged: (value) => Navigator.pop(sheetContext, value),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final style in ReaderChapterProgressStyle.values)
                      RadioListTile<ReaderChapterProgressStyle>(
                        key: ValueKey('reader-chapter-progress-${style.name}'),
                        value: style,
                        title: Text(_label(context, style)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      if (!context.mounted || selected == null || selected == style) return;
      onChanged(selected);
    },
  );
}
