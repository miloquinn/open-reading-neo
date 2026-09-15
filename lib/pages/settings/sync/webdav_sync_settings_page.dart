import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'webdav_sync_widgets.dart';
import 'webdav_sync_frequency.dart';

import 'webdav_setup_page.dart';
import 'webdav_sync_content_page.dart';
import 'webdav_sync_activity_page.dart';

class WebDavSyncSettingsPage extends StatelessWidget {
  const WebDavSyncSettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final sync = context.watch<WebDavSyncController>();
    final l10n = context.l10n;
    final busy =
        sync.status == WebDavSyncStatus.syncing ||
        sync.status == WebDavSyncStatus.testing ||
        sync.syncingText;
    return FloatingSubpageScaffold(
      title: l10n.cloudSyncSettings,
      body: SyncPageBody(
        children: [
          SyncSurface(
            child: SyncNavigationTile(
              icon: Icons.schedule_outlined,
              title: l10n.cloudSyncFrequency,
              detail: syncFrequencyLabel(context, sync.syncFrequency),
              onTap: sync.isConfigured
                  ? () => _pickFrequency(context, sync)
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.cloudSyncFrequencyHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          SyncSurface(
            child: Column(
              children: [
                SyncNavigationTile(
                  icon: Icons.checklist_rounded,
                  title: l10n.cloudSyncMoreContent,
                  detail: l10n.cloudSyncOtherDataHint,
                  onTap: sync.isConfigured
                      ? () =>
                            openSyncPage(context, const WebDavSyncContentPage())
                      : null,
                ),
                const SyncDivider(),
                SyncNavigationTile(
                  icon: Icons.dns_outlined,
                  title: l10n.cloudSyncStorage,
                  detail: sync.isConfigured
                      ? Uri.tryParse(sync.serverUrl ?? '')?.host ?? 'WebDAV'
                      : l10n.webDavNotConfigured,
                  onTap: busy
                      ? null
                      : () => openSyncPage(context, const WebDavSetupPage()),
                ),
                const SyncDivider(),
                SyncNavigationTile(
                  icon: Icons.receipt_long_outlined,
                  title: l10n.cloudSyncActivity,
                  detail: l10n.cloudSyncActivityHint,
                  onTap: sync.isConfigured
                      ? () => openSyncPage(
                          context,
                          const WebDavSyncActivityPage(),
                        )
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _ConnectionFooter(sync: sync),
        ],
      ),
    );
  }
}

Future<void> _pickFrequency(
  BuildContext context,
  WebDavSyncController sync,
) async {
  final selected = await showModalBottomSheet<WebDavSyncFrequency>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  context.l10n.cloudSyncFrequency,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final frequency in const [
                WebDavSyncFrequency.onChange,
                WebDavSyncFrequency.every15Minutes,
                WebDavSyncFrequency.hourly,
                WebDavSyncFrequency.daily,
                WebDavSyncFrequency.off,
              ])
                ListTile(
                  title: Text(syncFrequencyLabel(context, frequency)),
                  subtitle: frequency == WebDavSyncFrequency.onChange
                      ? Text(context.l10n.cloudSyncAutoHint)
                      : null,
                  selected: sync.syncFrequency == frequency,
                  trailing: sync.syncFrequency == frequency
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(context, frequency),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  await performSyncAction(context, () => sync.setSyncFrequency(selected));
}

class _ConnectionFooter extends StatelessWidget {
  const _ConnectionFooter({required this.sync});
  final WebDavSyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final busy =
        sync.status == WebDavSyncStatus.syncing ||
        sync.status == WebDavSyncStatus.testing ||
        sync.syncingText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sync.isConfigured)
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: busy
                ? null
                : () => performSyncAction(context, () => _clear(context)),
            icon: const Icon(Icons.link_off_rounded, size: 18),
            label: Text(l10n.webDavClearConfiguration),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            '${l10n.cloudSyncCheckHint}\n${l10n.webDavSecurityNotice}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.webDavClearConfigurationTitle),
        content: Text(context.l10n.webDavClearConfigurationMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.webDavClearConfigurationConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true) await sync.clearConfiguration();
  }
}
