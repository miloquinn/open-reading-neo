import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/utils/localization_extension.dart';

String webDavSyncErrorText(BuildContext context, WebDavSyncErrorCode? code) {
  switch (code) {
    case WebDavSyncErrorCode.invalidConfiguration:
      return context.l10n.webDavErrorInvalidConfiguration;
    case WebDavSyncErrorCode.insecureConnection:
      return context.l10n.webDavErrorInsecureConnection;
    case WebDavSyncErrorCode.authentication:
      return context.l10n.webDavErrorAuthentication;
    case WebDavSyncErrorCode.permissionDenied:
      return context.l10n.webDavErrorPermission;
    case WebDavSyncErrorCode.notFound:
      return context.l10n.webDavErrorNotFound;
    case WebDavSyncErrorCode.conflict:
      return context.l10n.webDavErrorConflict;
    case WebDavSyncErrorCode.timeout:
      return context.l10n.webDavErrorTimeout;
    case WebDavSyncErrorCode.tls:
      return context.l10n.webDavErrorCertificate;
    case WebDavSyncErrorCode.network:
      return context.l10n.webDavErrorNetwork;
    case WebDavSyncErrorCode.serverIncompatible:
      return context.l10n.webDavErrorUnsupported;
    case WebDavSyncErrorCode.serverError:
      return context.l10n.webDavErrorServer;
    case WebDavSyncErrorCode.storageFull:
      return context.l10n.webDavErrorStorageFull;
    case WebDavSyncErrorCode.rateLimited:
      return context.l10n.webDavErrorRateLimited;
    case WebDavSyncErrorCode.corruptRemoteData:
      return context.l10n.webDavErrorCorruptData;
    case WebDavSyncErrorCode.localDataCorrupt:
      return context.l10n.webDavErrorLocalDataCorrupt;
    case WebDavSyncErrorCode.clockSkew:
      return context.l10n.webDavErrorClockSkew;
    case WebDavSyncErrorCode.secureStorage:
      return context.l10n.webDavErrorSecureStorage;
    case WebDavSyncErrorCode.unknown:
    case null:
      return context.l10n.webDavErrorUnknown;
  }
}

class WebDavSyncFailureDetails extends StatelessWidget {
  const WebDavSyncFailureDetails({super.key, required this.failure});

  final WebDavSyncFailure failure;

  @override
  Widget build(BuildContext context) {
    final explanation = _failureExplanation(context, failure.message);
    final details = <String>[
      ?explanation,
      context.l10n.webDavErrorReason(failure.message),
      if (failure.statusCode case final status?)
        context.l10n.webDavErrorHttpStatus(status),
      if (failure.requestMethod?.trim() case final method?
          when method.isNotEmpty)
        context.l10n.webDavErrorRequestMethod(method),
      if (failure.resourcePath?.trim() case final path? when path.isNotEmpty)
        context.l10n.webDavErrorResourcePath(path),
    ];
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: context.l10n.webDavErrorDetails,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border.all(color: scheme.error.withValues(alpha: 0.18)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.webDavErrorDetails,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).copyButtonLabel,
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: details.join('\n')),
                  ),
                  icon: const Icon(Icons.copy_all_outlined, size: 20),
                  color: scheme.onErrorContainer,
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              details.join('\n\n'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _failureExplanation(BuildContext context, String message) {
  if (message.contains('older or unsupported sync protocol')) {
    return context.l10n.cloudSyncProtocolUpgrade;
  }
  if (message ==
          'The WebDAV server did not provide an ETag for a mutable file.' ||
      message == 'Safe editable TXT sync requires a strong WebDAV ETag.') {
    return context.l10n.webDavErrorMissingEtagDetail;
  }
  if (message.contains('should have been rejected by If-Match.')) {
    return context.l10n.webDavErrorIfMatchIgnoredDetail;
  }
  if (message.contains('should have been rejected by If-None-Match.')) {
    return context.l10n.webDavErrorIfNoneMatchIgnoredDetail;
  }
  return null;
}

String webDavSyncFailurePhaseText(
  BuildContext context,
  WebDavSyncPhase phase, {
  bool bookFiles = false,
}) {
  if (bookFiles) {
    return context.l10n.webDavErrorPhase(context.l10n.webDavScopeBookFiles);
  }
  return context.l10n.webDavErrorPhase(webDavSyncPhaseText(context, phase));
}

String webDavSyncPhaseText(BuildContext context, WebDavSyncPhase phase) =>
    switch (phase) {
      WebDavSyncPhase.connecting => context.l10n.webDavPhaseConnecting,
      WebDavSyncPhase.scanningLocal => context.l10n.webDavPhaseScanningLocal,
      WebDavSyncPhase.readingRemote => context.l10n.webDavPhaseReadingRemote,
      WebDavSyncPhase.applyingRemote => context.l10n.webDavPhaseApplyingRemote,
      WebDavSyncPhase.uploadingLocal => context.l10n.webDavPhaseUploadingLocal,
      WebDavSyncPhase.finishing => context.l10n.webDavPhaseFinishing,
      WebDavSyncPhase.none => context.l10n.webDavPhaseUnknown,
    };
