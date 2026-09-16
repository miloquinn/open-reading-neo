import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_summary_cache.dart';

/// Reading ownership survives expired credentials and offline restarts. Only
/// an explicit logout or a fully authenticated account switch changes it.
class ReadingAccountScope extends ChangeNotifier {
  static final instance = ReadingAccountScope();
  static const storageKey = 'reading_account_owner_v1';
  String? _owner;
  String? get owner => _owner;
  Future<void>? _saving;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(storageKey)) {
      final value = prefs.getString(storageKey);
      _owner = value == null || value.isEmpty ? null : value;
      return;
    }
    // First upgrade while offline: preserve the last known account identity.
    // This is ownership only; it never grants authentication or premium access.
    final previous = await const MemberAccountSummaryCache().load();
    await setOwner(previous?.userId);
  }

  Future<void> setOwner(String? value) {
    if (_owner == value) return _saving ?? Future<void>.value();
    _owner = value;
    notifyListeners();
    Future<void> persist() async {
      final prefs = await SharedPreferences.getInstance();
      // An explicit guest marker prevents stale legacy summary caches from
      // resurrecting an account after logout or interrupted token cleanup.
      await prefs.setString(storageKey, value ?? '');
    }

    final previous = _saving;
    late final Future<void> operation;
    operation = (previous == null ? persist() : previous.then((_) => persist()))
        .catchError((Object error) {
          debugPrint('Persist reading account failed: $error');
        })
        .whenComplete(() {
          if (identical(_saving, operation)) _saving = null;
        });
    _saving = operation;
    return operation;
  }
}
