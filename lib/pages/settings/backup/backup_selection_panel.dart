import 'package:flutter/material.dart';
import '../../../services/backup/backup_selection.dart';
import '../../../services/backup/webdav_backup_controller.dart';
import 'backup_copy.dart';

class BackupSelectionPanel extends StatelessWidget {
  const BackupSelectionPanel({super.key, required this.controller});
  final WebDavBackupController controller;

  @override
  Widget build(BuildContext context) {
    final zh = BackupCopy.of(context).zh;
    final selection = controller.selection;
    void update({
      bool? reading,
      bool? statistics,
      bool? sources,
      bool? settings,
      Set<int>? ids,
    }) {
      controller.setSelection(
        BackupSelection(
          reading: reading ?? selection.reading,
          statistics: statistics ?? selection.statistics,
          sources: sources ?? selection.sources,
          settings: settings ?? selection.settings,
          bookIds: ids ?? selection.bookIds,
        ),
      );
    }

    final bytes = controller.books
        .where((b) => selection.bookIds.contains(b.id))
        .fold<int>(0, (sum, b) => sum + b.bytes);
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      title: Text(zh ? '备份内容' : 'Backup content'),
      subtitle: Text(
        zh
            ? '正文已选 ${selection.bookIds.length} 本 · ${backupBytes(bytes)}'
            : '${selection.bookIds.length} book files · ${backupBytes(bytes)}',
      ),
      children: [
        SwitchListTile.adaptive(
          title: Text(
            zh ? '书架、阅读进度、书签和笔记' : 'Library, progress, bookmarks and notes',
          ),
          subtitle: Text(
            zh
                ? '不含正文；换设备后需重新导入未备份的本地书籍。'
                : 'Without book files. Reimport omitted local books on a new device.',
          ),
          value: selection.reading || selection.bookIds.isNotEmpty,
          onChanged: controller.busy || selection.bookIds.isNotEmpty
              ? null
              : (v) => update(reading: v),
        ),
        SwitchListTile.adaptive(
          title: Text(zh ? '阅读统计' : 'Reading statistics'),
          value: selection.statistics,
          onChanged: controller.busy ? null : (v) => update(statistics: v),
        ),
        SwitchListTile.adaptive(
          title: Text(zh ? '书源' : 'Book sources'),
          value: selection.sources,
          onChanged: controller.busy ? null : (v) => update(sources: v),
        ),
        SwitchListTile.adaptive(
          title: Text(zh ? '阅读设置' : 'Reading settings'),
          value: selection.settings,
          onChanged: controller.busy ? null : (v) => update(settings: v),
        ),
        ListTile(
          title: Text(zh ? '选择书籍正文' : 'Choose book files'),
          subtitle: Text(
            zh
                ? '默认不备份正文，按需选择；大小为压缩前估算。'
                : 'No book files by default. Sizes are estimates before compression.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: controller.busy
              ? null
              : () async {
                  final result = await showDialog<Set<int>>(
                    context: context,
                    builder: (_) => _BookPicker(controller: controller, zh: zh),
                  );
                  if (result != null) update(ids: result);
                },
        ),
      ],
    );
  }
}

class _BookPicker extends StatefulWidget {
  const _BookPicker({required this.controller, required this.zh});
  final WebDavBackupController controller;
  final bool zh;
  @override
  State<_BookPicker> createState() => _BookPickerState();
}

class _BookPickerState extends State<_BookPicker> {
  late final Set<int> selected = {...widget.controller.selection.bookIds};
  late final Future<void> loading = widget.controller.loadBooks();
  String query = '';
  @override
  Widget build(BuildContext context) {
    final zh = widget.zh;
    return AlertDialog(
      title: Text(zh ? '选择书籍正文' : 'Choose book files'),
      content: SizedBox(
        width: 500,
        height: MediaQuery.sizeOf(context).height * .5,
        child: FutureBuilder<void>(
          future: loading,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text(
                zh
                    ? '无法读取书籍列表，请关闭后重试。'
                    : 'Could not load books. Close and retry.',
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final books = widget.controller.books;
            final visible = books
                .where(
                  (b) => b.title.toLowerCase().contains(query.toLowerCase()),
                )
                .toList();
            final bytes = books
                .where((b) => selected.contains(b.id))
                .fold<int>(0, (sum, b) => sum + b.bytes);
            return Column(
              children: [
                TextField(
                  decoration: InputDecoration(
                    hintText: zh ? '搜索书名' : 'Search books',
                  ),
                  onChanged: (v) => setState(() => query = v),
                ),
                Text(
                  zh
                      ? '已选 ${selected.length} 本 · ${backupBytes(bytes)}'
                      : '${selected.length} selected · ${backupBytes(bytes)}',
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () => setState(
                        () => selected.addAll(
                          visible.where((b) => b.available).map((b) => b.id),
                        ),
                      ),
                      child: Text(zh ? '全选当前列表' : 'Select visible'),
                    ),
                    TextButton(
                      onPressed: () => setState(selected.clear),
                      child: Text(zh ? '清空' : 'Clear'),
                    ),
                  ],
                ),
                Expanded(
                  child: visible.isEmpty
                      ? Center(child: Text(zh ? '没有本地书籍' : 'No local books'))
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (_, i) {
                            final book = visible[i];
                            return SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: Text(book.title),
                              subtitle: Text(
                                book.available
                                    ? backupBytes(book.bytes)
                                    : (zh ? '文件缺失' : 'File missing'),
                              ),
                              value: selected.contains(book.id),
                              onChanged: !book.available
                                  ? null
                                  : (v) => setState(() {
                                      if (v == true) {
                                        selected.add(book.id);
                                      } else {
                                        selected.remove(book.id);
                                      }
                                    }),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(zh ? '取消' : 'Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, selected),
          child: Text(zh ? '确定' : 'Done'),
        ),
      ],
    );
  }
}
