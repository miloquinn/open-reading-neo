import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String additionalSourceProtocolsPreferenceKey =
    'additional_source_protocols_v1';
const String privateBookSourceNetworkPreferenceKey =
    'private_book_source_network_v1';

/// Shared runtime gate for consumers outside the widget/provider tree.
/// AppSettingsNotifier keeps this in sync with verified account membership.
/// Persistence is owned by the account controller and restored only after the
/// cached membership is matched to the authenticated account.
class AdvancedFeatureAccess {
  static final ValueNotifier<bool> _premiumUnlocked = ValueNotifier(false);

  static ValueListenable<bool> get premiumAccessChanges => _premiumUnlocked;

  static bool get premiumUnlocked => _premiumUnlocked.value;

  static set premiumUnlocked(bool value) => _premiumUnlocked.value = value;

  static Future<bool> additionalProtocolsEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return premiumUnlocked &&
        preferences.getBool(additionalSourceProtocolsPreferenceKey) == true;
  }
}
