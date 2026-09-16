import 'package:flutter/material.dart';
import '../../../services/backup/backup_selection.dart';
import 'backup_copy.dart';

class RestoreOptionsDialog extends StatefulWidget {
  const RestoreOptionsDialog({super.key});
  @override
  State<RestoreOptionsDialog> createState() => _RestoreOptionsDialogState();
}

class _RestoreOptionsDialogState extends State<RestoreOptionsDialog> {
  bool reading = true,
      files = true,
      statistics = true,
      sources = true,
      settings = true,
      overwrite = false;
  @override
  Widget build(BuildContext context) {
    final zh = BackupCopy.of(context).zh;
    Widget option(String title, bool value, ValueChanged<bool> change) =>
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          value: value,
          onChanged: (v) => setState(() => change(v)),
        );
    return AlertDialog(
      title: Text(zh ? '恢复哪些内容' : 'Choose what to restore'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                zh
                    ? '仅恢复备份中包含的内容，未备份的类别保持不变。'
                    : 'Only included categories can be restored. Omitted categories stay unchanged.',
              ),
              option(zh ? '书架、进度与笔记' : 'Library, progress and notes', reading, (
                v,
              ) {
                reading = v;
                if (!v) files = false;
              }),
              if (reading)
                option(
                  zh ? '书籍正文与封面' : 'Book files and covers',
                  files,
                  (v) => files = v,
                ),
              option(
                zh ? '阅读统计' : 'Reading statistics',
                statistics,
                (v) => statistics = v,
              ),
              option(zh ? '书源' : 'Book sources', sources, (v) => sources = v),
              option(
                zh ? '阅读设置' : 'Reading settings',
                settings,
                (v) => settings = v,
              ),
              const Divider(height: 28),
              option(
                zh ? '允许覆盖现有数据' : 'Replace existing data',
                overwrite,
                (v) => overwrite = v,
              ),
              Text(
                overwrite
                    ? (zh
                          ? '替换所选类别和同一本书的数据。恢复前会保存本地数据副本。'
                          : 'Replace selected categories and matching books. A local data copy is saved first.')
                    : (zh
                          ? '保留已有书籍及进度，仅添加缺少的书籍和设置；已有统计或书源时跳过该类别。'
                          : 'Keep existing books and progress; add missing books and settings. Skip statistics or sources when already present.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(zh ? '取消' : 'Cancel'),
        ),
        FilledButton(
          onPressed: !reading && !statistics && !sources && !settings
              ? null
              : () => Navigator.pop(
                  context,
                  RestoreSelection(
                    reading: reading,
                    files: files,
                    statistics: statistics,
                    sources: sources,
                    settings: settings,
                    overwrite: overwrite,
                  ),
                ),
          child: Text(zh ? '恢复' : 'Restore'),
        ),
      ],
    );
  }
}
