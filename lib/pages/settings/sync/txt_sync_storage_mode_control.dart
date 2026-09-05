import 'package:flutter/material.dart';

import '../../../utils/localization_extension.dart';

Future<bool> confirmIncrementalTxtStorage(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(dialogContext.l10n.cloudSyncIncrementalConfirmTitle),
        content: Text(dialogContext.l10n.cloudSyncIncrementalConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.cloudSyncIncrementalConfirm),
          ),
        ],
      ),
    ) ??
    false;

class TxtSyncStorageModeControl extends StatelessWidget {
  const TxtSyncStorageModeControl({
    super.key,
    required this.incremental,
    required this.onEnable,
  });

  final bool incremental;
  final VoidCallback? onEnable;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        incremental
            ? context.l10n.cloudSyncIncrementalMode
            : context.l10n.cloudSyncPlainMode,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      if (incremental)
        Text(context.l10n.cloudSyncIncrementalDescription)
      else
        TextButton.icon(
          onPressed: onEnable == null
              ? null
              : () async {
                  if (await confirmIncrementalTxtStorage(context) &&
                      context.mounted) {
                    onEnable?.call();
                  }
                },
          icon: const Icon(Icons.sync_alt_rounded),
          label: Text(context.l10n.cloudSyncEnableIncremental),
        ),
    ],
  );
}
