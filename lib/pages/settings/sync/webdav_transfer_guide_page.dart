import 'package:flutter/material.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'webdav_sync_widgets.dart';

class WebDavTransferGuidePage extends StatelessWidget {
  const WebDavTransferGuidePage({super.key});
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FloatingSubpageScaffold(
      title: l10n.cloudSyncTransferGuide,
      body: SyncPageBody(
        children: [
          Text(
            l10n.cloudSyncTransferIntro,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          SyncSection(
            title: l10n.cloudSyncTransferOldPhone,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(l10n.cloudSyncTransferOldPhoneBody),
            ),
          ),
          const SizedBox(height: 24),
          SyncSection(
            title: l10n.cloudSyncTransferHasBook,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(l10n.cloudSyncTransferHasBookBody),
            ),
          ),
          const SizedBox(height: 24),
          SyncSection(
            title: l10n.cloudSyncTransferNeedsBook,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(l10n.cloudSyncTransferNeedsBookBody),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            l10n.cloudSyncTransferEditedBook,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
