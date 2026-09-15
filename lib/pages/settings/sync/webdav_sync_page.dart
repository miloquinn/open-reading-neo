import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'webdav_sync_widgets.dart';

import 'package:intl/intl.dart';
import 'book_file_sync_page.dart';
import 'webdav_progress_page.dart';
import 'webdav_sync_settings_page.dart';
import 'webdav_sync_activity_page.dart';
import 'webdav_transfer_guide_page.dart';
import 'webdav_setup_page.dart';
import 'webdav_sync_translator.dart';

class WebDavSyncPage extends StatelessWidget {
  const WebDavSyncPage({super.key});
  @override
  Widget build(BuildContext context) {
    final sync = context.watch<WebDavSyncController>();
    final l10n = context.l10n;
    return FloatingSubpageScaffold(
      title: l10n.cloudSyncTitle,
      body: SyncPageBody(
        children: [
          _SyncOverview(sync: sync),
          const SizedBox(height: 24),
          if (sync.lastFailure != null) ...[
            SyncSurface(
              child: SyncNavigationTile(
                icon: Icons.error_outline,
                title: l10n.cloudSyncNeedsAttention,
                detail: webDavSyncErrorText(context, sync.lastFailure!.code),
                onTap: () =>
                    openSyncPage(context, const WebDavSyncActivityPage()),
              ),
            ),
            const SizedBox(height: 16),
          ],
          SyncSurface(
            child: Column(
              children: [
                SyncNavigationTile(
                  icon: Icons.bookmark_border_rounded,
                  title: l10n.webDavScopeProgress,
                  detail: l10n.cloudSyncProgressOnlyHint,
                  onTap: sync.isConfigured
                      ? () => openSyncPage(context, const WebDavProgressPage())
                      : null,
                ),
                const SyncDivider(),
                SyncNavigationTile(
                  icon: Icons.menu_book_outlined,
                  title: l10n.webDavBookFilesTitle,
                  detail: l10n.cloudSyncFilesEntryHint,
                  onTap: sync.isConfigured
                      ? () => openSyncPage(context, const BookFileSyncPage())
                      : null,
                ),
                const SyncDivider(),
                SyncNavigationTile(
                  icon: Icons.tune_rounded,
                  title: l10n.cloudSyncSettings,
                  detail: l10n.cloudSyncSettingsHint,
                  onTap: () =>
                      openSyncPage(context, const WebDavSyncSettingsPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SyncSurface(
            child: SyncNavigationTile(
              icon: Icons.phonelink_setup_rounded,
              title: l10n.cloudSyncTransferGuide,
              detail: l10n.cloudSyncTransferGuideHint,
              onTap: () =>
                  openSyncPage(context, const WebDavTransferGuidePage()),
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncOverview extends StatelessWidget {
  const _SyncOverview({required this.sync});
  final WebDavSyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final configured = sync.isConfigured;
    final busy =
        sync.status == WebDavSyncStatus.syncing ||
        sync.status == WebDavSyncStatus.testing ||
        sync.syncingText;
    final failed =
        sync.lastError != null ||
        sync.status == WebDavSyncStatus.failed ||
        sync.status == WebDavSyncStatus.partialFailure;
    final title = !configured
        ? l10n.webDavNotConfigured
        : busy
        ? l10n.webDavSyncing
        : failed
        ? sync.status == WebDavSyncStatus.partialFailure
              ? l10n.webDavPartialFailure
              : l10n.webDavSyncFailed
        : l10n.webDavConnected;
    final host = Uri.tryParse(sync.serverUrl ?? '')?.host;
    final lastSync = sync.lastSuccessfulSync;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 12),
              child: Icon(
                failed ? Icons.cloud_off_outlined : Icons.cloud_sync_outlined,
                size: 30,
                color: failed ? scheme.error : scheme.primary,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    configured
                        ? host != null && host.isNotEmpty
                              ? host
                              : 'WebDAV'
                        : l10n.webDavConfigureSubtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (configured) ...[
          Text(
            sync.pendingChanges > 0
                ? l10n.webDavPendingChanges(sync.pendingChanges)
                : lastSync == null
                ? l10n.webDavNeverSynced
                : l10n.webDavLastSync(
                    DateFormat.yMd(
                      Localizations.localeOf(context).toLanguageTag(),
                    ).add_Hm().format(lastSync.toLocal()),
                  ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: busy
              ? null
              : configured
              ? () => performSyncAction(context, () async {
                  await sync.syncNow();
                })
              : () => openSyncPage(context, const WebDavSetupPage()),
          icon: busy && !MediaQuery.disableAnimationsOf(context)
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  configured ? Icons.sync_rounded : Icons.add_rounded,
                  size: 20,
                ),
          label: Text(
            busy
                ? sync.status == WebDavSyncStatus.testing
                      ? l10n.webDavTestingConnection
                      : sync.phase != WebDavSyncPhase.none
                      ? webDavSyncPhaseText(context, sync.phase)
                      : l10n.webDavSyncing
                : configured
                ? l10n.webDavSyncNow
                : l10n.webDavSetUp,
          ),
        ),
      ],
    );
  }
}
