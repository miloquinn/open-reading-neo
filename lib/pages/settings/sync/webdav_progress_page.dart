import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'webdav_sync_widgets.dart';

import 'webdav_transfer_guide_page.dart';

class WebDavProgressPage extends StatelessWidget {
  const WebDavProgressPage({super.key});
  @override
  Widget build(BuildContext context) {
    final sync = context.watch<WebDavSyncController>();
    final l10n = context.l10n;
    return FloatingSubpageScaffold(
      title: l10n.webDavScopeProgress,
      body: SyncPageBody(
        children: [
          Text(
            l10n.cloudSyncProgressExplanation,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          SyncSurface(
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  title: Text(l10n.webDavScopeProgress),
                  subtitle: Text(l10n.cloudSyncProgressOnlyHint),
                  value: sync.scope.progress,
                  onChanged: sync.isConfigured
                      ? (value) => performSyncAction(
                          context,
                          () => sync.setScope(
                            sync.scope.copyWith(progress: value),
                          ),
                        )
                      : null,
                ),
                const SyncDivider(),
                SwitchListTile.adaptive(
                  title: Text(l10n.cloudSyncAutoResume),
                  subtitle: Text(l10n.cloudSyncAutoResumeHint),
                  value: sync.autoResume,
                  onChanged: sync.isConfigured && sync.scope.progress
                      ? (value) => performSyncAction(
                          context,
                          () => sync.setAutoResume(value),
                        )
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
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
