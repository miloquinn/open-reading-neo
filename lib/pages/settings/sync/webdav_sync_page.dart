import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:xxread/services/sync/book_content_sync_service.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'package:xxread/widgets/side_toast.dart';

import 'txt_sync_details_page.dart';
import 'webdav_setup_page.dart';
import 'webdav_sync_content_page.dart';
import 'webdav_sync_translator.dart';

class WebDavSyncPage extends StatelessWidget {
  const WebDavSyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<WebDavSyncController>();
    final l10n = context.l10n;
    final status = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SyncOverview(sync: sync),
        const SizedBox(height: 18),
        _SyncActivity(sync: sync),
        if (sync.lastFailure case final failure?) ...[
          const SizedBox(height: 20),
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
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          WebDavSyncFailureDetails(failure: failure),
        ],
      ],
    );
    final settings = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: l10n.cloudSyncResumeTitle,
          child: _ContinuationSettings(sync: sync),
        ),
        const SizedBox(height: 24),
        _Section(
          title: l10n.webDavSyncContent,
          child: _SyncNavigation(sync: sync),
        ),
        const SizedBox(height: 16),
        _ConnectionFooter(sync: sync),
      ],
    );
    return FloatingSubpageScaffold(
      title: l10n.cloudSyncTitle,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Keep readable controls when accessibility text consumes more width.
          final wide =
              constraints.maxWidth >= 860 &&
              MediaQuery.textScalerOf(context).scale(16) <= 22;
          return ListView(
            padding: floatingSubpagePadding(context, top: 24, bottom: 40),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 4, child: status),
                            const SizedBox(width: 40),
                            Expanded(flex: 5, child: settings),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            status,
                            const SizedBox(height: 24),
                            settings,
                          ],
                        ),
                ),
              ),
            ],
          );
        },
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
              ? () => _perform(context, () async {
                  await sync.syncNow();
                })
              : () => _openSetup(context),
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
    return _Surface(
      child: Column(
        children: [
          _StatusRow(
            icon: Icons.bookmark_border_rounded,
            title: l10n.cloudSyncProgress,
            detail: progress,
            failed: sync.lastError != null && !sync.lastFailureIsFile,
          ),
          const _InsetDivider(),
          _StatusRow(
            icon: Icons.description_outlined,
            title: l10n.cloudSyncText,
            detail: files,
            failed: sync.scope.bookFiles && fileFailed,
            onTap: sync.isConfigured ? () => _openBooks(context) : null,
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

class _ContinuationSettings extends StatelessWidget {
  const _ContinuationSettings({required this.sync});
  final WebDavSyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(l10n.webDavAutomaticSync),
          subtitle: Text(
            sync.isConfigured && !sync.autoSync
                ? l10n.cloudSyncPaused
                : l10n.cloudSyncAutoHint,
          ),
          value: sync.autoSync,
          onChanged: sync.isConfigured
              ? (value) => _perform(context, () => sync.setAutoSync(value))
              : null,
        ),
        const _InsetDivider(),
        SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 2,
          ),
          title: Text(l10n.webDavScopeProgress),
          value: sync.scope.progress,
          onChanged: sync.isConfigured
              ? (value) => _perform(
                  context,
                  () => sync.setScope(sync.scope.copyWith(progress: value)),
                )
              : null,
        ),
        const _InsetDivider(),
        SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(l10n.cloudSyncAutoResume),
          subtitle: Text(l10n.cloudSyncAutoResumeHint),
          value: sync.autoResume,
          onChanged: sync.isConfigured && sync.scope.progress
              ? (value) => _perform(context, () => sync.setAutoResume(value))
              : null,
        ),
      ],
    );
  }
}

class _SyncNavigation extends StatelessWidget {
  const _SyncNavigation({required this.sync});
  final WebDavSyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = <String>[
      if (sync.scope.bookSources) l10n.webDavScopeBookSources,
      if (sync.scope.books) l10n.webDavScopeBooks,
      if (sync.scope.progress) l10n.webDavScopeProgress,
      if (sync.scope.bookmarks) l10n.webDavScopeBookmarks,
      if (sync.scope.notes) l10n.webDavScopeNotes,
      if (sync.scope.readingSessions) l10n.webDavScopeReadingSessions,
      if (sync.scope.readerSettings) l10n.webDavScopeReaderSettings,
      if (sync.scope.replaceRules) l10n.webDavScopeReplaceRules,
      if (sync.scope.bookFiles) l10n.webDavScopeBookFiles,
    ];
    final available = sync.remoteBooks
        .where((book) => book.fileAvailable)
        .length;
    final busy =
        sync.status == WebDavSyncStatus.syncing ||
        sync.status == WebDavSyncStatus.testing ||
        sync.syncingText;
    return Column(
      children: [
        _NavigationRow(
          icon: Icons.menu_book_outlined,
          title: l10n.cloudSyncBooks,
          detail: available == 0
              ? l10n.cloudSyncBooksHint
              : '${l10n.webDavFilesAvailableDownload}：$available',
          onTap: sync.isConfigured ? () => _openBooks(context) : null,
        ),
        const _InsetDivider(),
        _NavigationRow(
          icon: Icons.tune_rounded,
          title: l10n.cloudSyncMoreContent,
          detail: enabled.isEmpty
              ? l10n.cloudSyncLocalOnly
              : enabled.join(' · '),
          onTap: sync.isConfigured
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const WebDavSyncContentPage(),
                  ),
                )
              : null,
        ),
        const _InsetDivider(),
        _NavigationRow(
          icon: Icons.dns_outlined,
          title: l10n.cloudSyncStorage,
          detail: sync.isConfigured
              ? Uri.tryParse(sync.serverUrl ?? '')?.host ?? 'WebDAV'
              : l10n.webDavNotConfigured,
          onTap: busy ? null : () => _openSetup(context),
        ),
      ],
    );
  }
}

class _NavigationRow extends StatelessWidget {
  const _NavigationRow({
    required this.icon,
    required this.title,
    required this.detail,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    minLeadingWidth: 24,
    horizontalTitleGap: 12,
    leading: Icon(icon, size: 22),
    title: Text(title),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        detail,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
      ),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
    enabled: onTap != null,
    onTap: onTap,
  );
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
                : () => _perform(context, () => _clear(context)),
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

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      _Surface(child: child),
    ],
  );
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: PageStyleHelper.palette(context).card,
    borderRadius: BorderRadius.circular(18),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _InsetDivider extends StatelessWidget {
  const _InsetDivider();
  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 0.5,
    indent: 16,
    endIndent: 16,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.65),
  );
}

Future<void> _openBooks(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const TxtSyncDetailsPage()));

Future<void> _openSetup(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const WebDavSetupPage()));

Future<void> _perform(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (!context.mounted) return;
    showSideToast(
      context,
      webDavSyncErrorText(
        context,
        error is WebDavSyncFailure ? error.code : WebDavSyncErrorCode.unknown,
      ),
      kind: SideToastKind.error,
    );
  }
}
