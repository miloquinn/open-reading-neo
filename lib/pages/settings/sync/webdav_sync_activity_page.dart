import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'webdav_sync_widgets.dart';

import 'package:flutter/services.dart';
import 'package:xxread/services/sync/book_content_sync_service.dart';
import 'txt_sync_details_page.dart';
import 'webdav_sync_translator.dart';

class WebDavSyncActivityPage extends StatelessWidget {
  const WebDavSyncActivityPage({super.key});
  @override
  Widget build(BuildContext context) {
    final sync = context.watch<WebDavSyncController>();
    final l10n = context.l10n;
    return FloatingSubpageScaffold(
      title: l10n.cloudSyncActivity,
      body: SyncPageBody(
        children: [
          _SyncActivity(sync: sync),
          const SizedBox(height: 20),
          if (sync.lastFailure case final failure?) ...[
            Text(
              webDavSyncErrorText(context, failure.code),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              webDavSyncFailurePhaseText(
                context,
                sync.lastFailedPhase,
                bookFiles: sync.lastFailureIsFile,
              ),
            ),
            const SizedBox(height: 12),
            WebDavSyncFailureDetails(failure: failure),
            const SizedBox(height: 20),
          ],
          OutlinedButton.icon(
            icon: const Icon(Icons.copy_outlined),
            label: Text(l10n.cloudSyncDiagnostics),
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: sync.diagnosticSummary)),
          ),
        ],
      ),
    );
  }
}

class _SyncActivity extends StatelessWidget {
  const _SyncActivity({required this.sync});
  final WebDavSyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final metadataBusy = sync.status == WebDavSyncStatus.syncing;
    final fileFailed =
        sync.lastFailureIsFile ||
        sync.textStates.any(
          (state) =>
              state.status == BookContentSyncStatus.failed ||
              state.status == BookContentSyncStatus.conflict,
        );
    final progress = !sync.scope.progress
        ? l10n.cloudSyncLocalOnly
        : metadataBusy
        ? sync.phase == WebDavSyncPhase.none
              ? l10n.webDavSyncing
              : webDavSyncPhaseText(context, sync.phase)
        : sync.lastError != null && !sync.lastFailureIsFile
        ? l10n.cloudSyncFailed
        : sync.progressPending
        ? l10n.cloudSyncPending
        : sync.lastProgressSyncAt != null
        ? l10n.cloudSyncMetadataComplete
        : l10n.cloudSyncNoActivity;
    final files = !sync.scope.bookFiles
        ? l10n.cloudSyncLocalOnly
        : sync.syncingText
        ? l10n.webDavSyncing
        : fileFailed
        ? l10n.cloudSyncPendingFiles
        : sync.textStates.isEmpty
        ? l10n.cloudSyncNoBooks
        : sync.textStates.every(
            (state) => state.status == BookContentSyncStatus.synced,
          )
        ? l10n.cloudSyncCurrent
        : l10n.cloudSyncFileIdle;
    return SyncSurface(
      child: Column(
        children: [
          _StatusRow(
            icon: Icons.bookmark_border_rounded,
            title: l10n.cloudSyncProgress,
            detail: progress,
            failed: sync.lastError != null && !sync.lastFailureIsFile,
          ),
          const SyncDivider(),
          _StatusRow(
            icon: Icons.description_outlined,
            title: l10n.cloudSyncText,
            detail: files,
            failed: sync.scope.bookFiles && fileFailed,
            onTap: sync.isConfigured
                ? () => openSyncPage(context, const TxtSyncDetailsPage())
                : null,
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.title,
    required this.detail,
    this.failed = false,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String detail;
  final bool failed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      leading: Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
      title: Text(title, style: theme.textTheme.titleSmall),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          detail,
          style: theme.textTheme.bodySmall?.copyWith(
            color: failed
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: onTap,
    );
  }
}
