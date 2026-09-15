import 'package:flutter/material.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/utils/localization_extension.dart';

String syncFrequencyLabel(
  BuildContext context,
  WebDavSyncFrequency frequency,
) => switch (frequency) {
  WebDavSyncFrequency.off => context.l10n.cloudSyncFrequencyOff,
  WebDavSyncFrequency.onChange => context.l10n.cloudSyncFrequencyOnChange,
  WebDavSyncFrequency.every15Minutes =>
    context.l10n.cloudSyncFrequency15Minutes,
  WebDavSyncFrequency.hourly => context.l10n.cloudSyncFrequencyHourly,
  WebDavSyncFrequency.daily => context.l10n.cloudSyncFrequencyDaily,
};
