import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../../services/backup/webdav_backup_controller.dart';
import '../../../services/sync/sync_models.dart';
import '../../../widgets/floating_subpage_scaffold.dart';
import '../../../widgets/restartable_app.dart';
import '../sync/webdav_setup_page.dart';
import '../sync/webdav_sync_translator.dart';
import 'backup_copy.dart';
import 'restore_options_dialog.dart';
import '../../../utils/page_style_helper.dart';
import 'backup_selection_panel.dart';
import '../../../services/backup/backup_selection.dart';
import '../../../services/library/download_task_controller.dart';
import '../../../book_sources/services/book_source_maintenance_coordinator.dart';
import '../../../utils/reader_themes.dart';

class WebDavBackupPage extends StatefulWidget {
  const WebDavBackupPage({super.key});
  @override
  State<WebDavBackupPage> createState() => _WebDavBackupPageState();
}

class _WebDavBackupPageState extends State<WebDavBackupPage> {
  String? _message;
  WebDavSyncFailure? _failure;
  bool _restored = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.read<WebDavBackupController>().isConfigured) {
        _run(context.read<WebDavBackupController>().refresh);
      }
    });
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() {
      _message = null;
      _failure = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = success);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = e is WebDavSyncFailure
            ? webDavSyncErrorText(context, e.code)
            : BackupCopy.of(context).failed;
        _failure = e is WebDavSyncFailure ? e : null;
      });
    }
  }

  Future<void> _restore(CloudBackup snapshot) async {
    final options = await showDialog<RestoreSelection>(
      context: context,
      builder: (_) => const RestoreOptionsDialog(),
    );
    if (options == null || !mounted) return;
    context.read<WebDavBackupController>().restoreSelection = options;
    await _run(() async {
      await context.read<WebDavBackupController>().restore(snapshot);
      if (mounted) setState(() => _restored = true);
    });
  }

  Widget _card(BuildContext context, Widget child) {
    final palette = PageStyleHelper.palette(context);
    return Material(
      color: palette.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final backup = context.watch<WebDavBackupController>();
    final copy = BackupCopy.of(context);
    final otherWrites =
        (context.watch<DownloadTaskController?>()?.hasActiveTasks ?? false) ||
        (context.watch<BookSourceMaintenanceCoordinator?>()?.state.isRunning ??
            false);
    return PopScope(
      canPop: !backup.busy && !_restored,
      child: FloatingSubpageScaffold(
        title: copy.title,
        body: ListView(
          padding: floatingSubpagePadding(context, top: 20, bottom: 40),
          children: [
            if (_restored) ...[
              Text(
                copy.restored,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(copy.restartHint),
              if (backup.recoveryPath != null)
                SelectableText(backup.recoveryPath!),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  ReaderThemes.invalidateSavedPaletteCache();
                  RestartableApp.restart(context);
                },
                child: Text(copy.restart),
              ),
            ] else ...[
              _card(
                context,
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 28,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        copy.zh ? '留住每一次阅读' : 'Keep your reading journey',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        copy.description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PageStyleHelper.palette(context).iconMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (otherWrites) Text(copy.waitForTasks),
              const SizedBox(height: 12),
              Text(
                copy.privacy,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PageStyleHelper.palette(context).iconMuted,
                ),
              ),
              const SizedBox(height: 20),
              _card(
                context,
                ListTile(
                  title: Text(copy.configure),
                  subtitle: Text(
                    backup.isConfigured
                        ? (backup.serverUrl ?? '')
                        : (copy.zh ? '连接你的云端空间' : 'Connect your storage'),
                  ),
                  leading: const Icon(Icons.cloud_outlined),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: backup.busy || otherWrites
                      ? null
                      : () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const WebDavSetupPage(),
                            ),
                          );
                          if (mounted && backup.isConfigured) {
                            await _run(backup.refresh);
                          }
                        },
                ),
              ),
              if (backup.isConfigured) ...[
                const SizedBox(height: 16),
                _card(context, BackupSelectionPanel(controller: backup)),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed:
                      backup.busy || otherWrites || backup.selection.isEmpty
                      ? null
                      : () => _run(backup.backup, success: copy.done),
                  icon: const Icon(Icons.backup_outlined),
                  label: Text(copy.backup),
                ),
                TextButton(
                  onPressed: backup.busy ? null : () => _run(backup.disconnect),
                  child: Text(copy.disconnect),
                ),
              ],
              if (backup.busy) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: backup.progress,
                  ),
                ),
                const SizedBox(height: 12),
                Text(copy.stage(backup.stage)),
                if (backup.progress != null)
                  Text(
                    '${(backup.progress! * 100).toStringAsFixed(0)}% · ${backupBytes(backup.completedBytes)} / ${backupBytes(backup.totalBytes)}',
                  ),
                if (backup.stage == 'uploading' ||
                    backup.stage == 'downloading')
                  Text('${backupBytes(backup.bytesPerSecond)}/s'),
                Text(copy.working),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(_message!),
                ),
              if (_failure != null)
                WebDavSyncFailureDetails(failure: _failure!),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      copy.history,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: copy.refresh,
                    onPressed: backup.busy || !backup.isConfigured
                        ? null
                        : () => _run(backup.refresh),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              if (backup.isConfigured &&
                  backup.backups.isEmpty &&
                  !backup.busy &&
                  _message == null)
                Text(copy.empty),
              for (final item in backup.backups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _card(
                    context,
                    ListTile(
                      leading: const Icon(Icons.folder_zip_outlined),
                      title: Text(
                        DateFormat.yMd(
                          Localizations.localeOf(context).toLanguageTag(),
                        ).add_Hms().format(item.createdAt.toLocal()),
                      ),
                      subtitle: Text(
                        item.bytes == null
                            ? 'ZIP'
                            : '${(item.bytes! / 1024 / 1024).toStringAsFixed(1)} MB · ZIP',
                      ),
                      trailing: TextButton(
                        onPressed: backup.busy || otherWrites
                            ? null
                            : () => _restore(item),
                        child: Text(copy.restore),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
