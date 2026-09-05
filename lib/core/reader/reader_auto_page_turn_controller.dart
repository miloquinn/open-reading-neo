import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderAutoPageTurnMode { timed, sweep, continuous, interval }

@immutable
class ReaderAutoPageTurnSelection {
  const ReaderAutoPageTurnSelection({
    required this.mode,
    required this.seconds,
  });

  final ReaderAutoPageTurnMode mode;
  final double seconds;
}

class ReaderAutoPageTurnController extends ChangeNotifier {
  ReaderAutoPageTurnController({required Future<bool> Function() onAdvance}) {
    _onAdvance = onAdvance;
  }

  static const String intervalPreferenceKey =
      'reader_auto_page_turn_interval_seconds';
  static const String horizontalModePreferenceKey =
      'reader_auto_page_turn_horizontal_mode';
  static const String verticalModePreferenceKey =
      'reader_auto_page_turn_vertical_mode';
  static const String timedSecondsPreferenceKey =
      'reader_auto_page_turn_timed_seconds';
  static const String sweepSecondsPreferenceKey =
      'reader_auto_page_turn_sweep_seconds';
  static const String continuousSecondsPreferenceKey =
      'reader_auto_page_turn_continuous_seconds';
  static const String intervalSecondsPreferenceKey =
      'reader_auto_page_turn_vertical_interval_seconds';
  static const String shortcutVisiblePreferenceKey =
      'reader_auto_page_turn_shortcut_visible';

  static const int defaultIntervalSeconds = 15;
  static const double defaultTimedSeconds = 15;
  static const double defaultSweepSeconds = 10;
  static const double defaultContinuousSeconds = 30;
  static const double defaultVerticalIntervalSeconds = 15;
  static const int minIntervalSeconds = 5;
  static const int maxIntervalSeconds = 120;

  late final Future<bool> Function() _onAdvance;

  Timer? _timer;
  int _generation = 0;
  bool _vertical = false;
  ReaderAutoPageTurnMode _horizontalMode = ReaderAutoPageTurnMode.timed;
  ReaderAutoPageTurnMode _verticalMode = ReaderAutoPageTurnMode.continuous;
  final Map<ReaderAutoPageTurnMode, double> _seconds =
      <ReaderAutoPageTurnMode, double>{
        ReaderAutoPageTurnMode.timed: defaultTimedSeconds,
        ReaderAutoPageTurnMode.sweep: defaultSweepSeconds,
        ReaderAutoPageTurnMode.continuous: defaultContinuousSeconds,
        ReaderAutoPageTurnMode.interval: defaultVerticalIntervalSeconds,
      };
  bool _isActive = false;
  bool _isRunning = false;
  bool _shortcutVisible = true;
  bool _smoothPauseRequested = false;
  bool _advanceInFlight = false;
  bool _disposed = false;
  int _settingsRevision = 0;
  int _shortcutRevision = 0;

  int get intervalSeconds => secondsFor(mode).round();
  bool get isActive => _isActive;
  bool get isRunning => _isRunning;
  bool get shortcutVisible => _shortcutVisible;
  bool get smoothPauseRequested => _smoothPauseRequested;
  static const smoothPauseDuration = Duration(milliseconds: 280);
  ReaderAutoPageTurnMode get mode => modeFor(_vertical);

  ReaderAutoPageTurnMode modeFor(bool vertical) =>
      vertical ? _verticalMode : _horizontalMode;

  double secondsFor(ReaderAutoPageTurnMode mode) => _seconds[mode]!;

  void setVertical(bool vertical) {
    if (_disposed || vertical == _vertical) return;
    _vertical = vertical;
    if (_isRunning) _restartScheduling();
    notifyListeners();
  }

  Future<void> loadInterval() async {
    final revision = _settingsRevision;
    SharedPreferences preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    if (_disposed || revision != _settingsRevision) return;

    final legacy = _readSeconds(preferences, intervalPreferenceKey);
    final loadedHorizontal = _readMode(
      preferences.getString(horizontalModePreferenceKey),
      vertical: false,
    );
    final loadedVertical = _readMode(
      preferences.getString(verticalModePreferenceKey),
      vertical: true,
    );
    final loadedSeconds = <ReaderAutoPageTurnMode, double>{
      ReaderAutoPageTurnMode.timed: _readSeconds(
        preferences,
        timedSecondsPreferenceKey,
        fallback: legacy ?? defaultTimedSeconds,
      )!,
      ReaderAutoPageTurnMode.sweep: _readSeconds(
        preferences,
        sweepSecondsPreferenceKey,
        fallback: defaultSweepSeconds,
      )!,
      ReaderAutoPageTurnMode.continuous: _readSeconds(
        preferences,
        continuousSecondsPreferenceKey,
        fallback: defaultContinuousSeconds,
      )!,
      ReaderAutoPageTurnMode.interval: _readSeconds(
        preferences,
        intervalSecondsPreferenceKey,
        fallback: legacy ?? defaultVerticalIntervalSeconds,
      )!,
    };
    final storedShortcutVisible = preferences.get(shortcutVisiblePreferenceKey);
    final loadedShortcutVisible = storedShortcutVisible is bool
        ? storedShortcutVisible
        : true;

    final changed =
        loadedHorizontal != _horizontalMode ||
        loadedVertical != _verticalMode ||
        loadedShortcutVisible != _shortcutVisible ||
        !mapEquals(loadedSeconds, _seconds);
    _horizontalMode = loadedHorizontal;
    _verticalMode = loadedVertical;
    _shortcutVisible = loadedShortcutVisible;
    _seconds
      ..clear()
      ..addAll(loadedSeconds);
    if (changed) notifyListeners();

    if (legacy != null) {
      try {
        if (!preferences.containsKey(timedSecondsPreferenceKey)) {
          await preferences.setDouble(
            timedSecondsPreferenceKey,
            loadedSeconds[ReaderAutoPageTurnMode.timed]!,
          );
        }
        if (!preferences.containsKey(intervalSecondsPreferenceKey)) {
          await preferences.setDouble(
            intervalSecondsPreferenceKey,
            loadedSeconds[ReaderAutoPageTurnMode.interval]!,
          );
        }
      } catch (_) {
        // Migration is best effort; loaded values still apply to this session.
      }
    }
  }

  Future<void> setShortcutVisible(bool visible) async {
    if (_disposed) return;
    _settingsRevision++;
    final shortcutRevision = ++_shortcutRevision;
    if (_shortcutVisible != visible) {
      _shortcutVisible = visible;
      notifyListeners();
    }

    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed || shortcutRevision != _shortcutRevision) return;
      await preferences.setBool(shortcutVisiblePreferenceKey, visible);
    } catch (_) {
      // Storage should not prevent changing the shortcut for this session.
    }
  }

  Future<void> setInterval(int seconds) async {
    if (_disposed) return;
    _settingsRevision++;
    final value = _clampSeconds(seconds.toDouble());
    final changed =
        _seconds[ReaderAutoPageTurnMode.timed] != value ||
        _seconds[ReaderAutoPageTurnMode.interval] != value;
    _seconds[ReaderAutoPageTurnMode.timed] = value;
    _seconds[ReaderAutoPageTurnMode.interval] = value;
    if (changed) notifyListeners();
    if (changed && _isRunning && _usesTimer(mode)) _restartScheduling();

    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      await Future.wait(<Future<bool>>[
        preferences.setInt(intervalPreferenceKey, value.round()),
        preferences.setDouble(timedSecondsPreferenceKey, value),
        preferences.setDouble(intervalSecondsPreferenceKey, value),
      ]);
    } catch (_) {
      // Storage should not prevent automatic paging for the current session.
    }
  }

  Future<void> applySelection(ReaderAutoPageTurnSelection selection) async {
    if (_disposed) return;
    _settingsRevision++;
    final selectedMode = selection.mode;
    final seconds = _clampSeconds(selection.seconds);
    final vertical = _isVerticalMode(selectedMode);
    final changed =
        modeFor(vertical) != selectedMode || _seconds[selectedMode] != seconds;
    if (vertical) {
      _verticalMode = selectedMode;
    } else {
      _horizontalMode = selectedMode;
    }
    _seconds[selectedMode] = seconds;
    if (changed) notifyListeners();
    if (changed && _isRunning && vertical == _vertical) _restartScheduling();

    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      await preferences.setString(
        vertical ? verticalModePreferenceKey : horizontalModePreferenceKey,
        selectedMode.name,
      );
      await preferences.setDouble(_secondsPreferenceKey(selectedMode), seconds);
    } catch (_) {
      // Storage should not prevent automatic reading for the current session.
    }
  }

  void start() {
    if (_disposed || _isRunning) return;
    _isActive = true;
    _isRunning = true;
    _smoothPauseRequested = false;
    final generation = ++_generation;
    _cancelTimer(incrementGeneration: false);
    notifyListeners();
    if (_usesTimer(mode) && !_advanceInFlight) _scheduleNext(generation);
  }

  void pause({bool smooth = false}) {
    if (_disposed || !_isActive) return;
    if (!_isRunning) {
      if (!smooth && _smoothPauseRequested) {
        _smoothPauseRequested = false;
        notifyListeners();
      }
      return;
    }
    _isRunning = false;
    _smoothPauseRequested = smooth;
    _cancelTimer();
    notifyListeners();
  }

  void stop() {
    if (_disposed) return;
    final changed = _isActive || _isRunning;
    _isActive = false;
    _isRunning = false;
    _smoothPauseRequested = false;
    _cancelTimer();
    if (changed) notifyListeners();
  }

  void _restartScheduling() {
    _cancelTimer();
    if (_usesTimer(mode) && !_advanceInFlight) _scheduleNext(_generation);
  }

  void _scheduleNext(int generation) {
    if (!_canContinue(generation) || !_usesTimer(mode)) return;
    _timer = Timer(
      Duration(milliseconds: (secondsFor(mode) * 1000).round()),
      () async {
        _timer = null;
        if (!_canContinue(generation)) return;
        await _advance(generation);
      },
    );
  }

  Future<void> _advance(int generation) async {
    if (!_canContinue(generation) || _advanceInFlight) return;
    _advanceInFlight = true;
    bool? advanced;
    Object? error;
    try {
      advanced = await _onAdvance();
    } catch (caught) {
      error = caught;
    } finally {
      _advanceInFlight = false;
    }

    if (!_canContinue(generation)) {
      if (!_disposed && _isRunning && _timer == null && _usesTimer(mode)) {
        _scheduleNext(_generation);
      }
      return;
    }
    if (error != null) {
      pause();
    } else if (advanced == false) {
      stop();
    } else {
      _scheduleNext(generation);
    }
  }

  bool _canContinue(int generation) =>
      !_disposed && _isRunning && generation == _generation;

  void _cancelTimer({bool incrementGeneration = true}) {
    if (incrementGeneration) _generation++;
    _timer?.cancel();
    _timer = null;
  }

  static bool _usesTimer(ReaderAutoPageTurnMode mode) =>
      mode == ReaderAutoPageTurnMode.timed ||
      mode == ReaderAutoPageTurnMode.interval;

  static bool _isVerticalMode(ReaderAutoPageTurnMode mode) =>
      mode == ReaderAutoPageTurnMode.continuous ||
      mode == ReaderAutoPageTurnMode.interval;

  static ReaderAutoPageTurnMode _readMode(
    String? value, {
    required bool vertical,
  }) {
    final fallback = vertical
        ? ReaderAutoPageTurnMode.continuous
        : ReaderAutoPageTurnMode.timed;
    ReaderAutoPageTurnMode? parsed;
    for (final mode in ReaderAutoPageTurnMode.values) {
      if (mode.name == value) parsed = mode;
    }
    if (parsed == null || _isVerticalMode(parsed) != vertical) return fallback;
    return parsed;
  }

  static double? _readSeconds(
    SharedPreferences preferences,
    String key, {
    double? fallback,
  }) {
    final stored = preferences.get(key);
    final value = stored is num ? stored.toDouble() : fallback;
    return value == null ? null : _clampSeconds(value);
  }

  static String _secondsPreferenceKey(ReaderAutoPageTurnMode mode) =>
      switch (mode) {
        ReaderAutoPageTurnMode.timed => timedSecondsPreferenceKey,
        ReaderAutoPageTurnMode.sweep => sweepSecondsPreferenceKey,
        ReaderAutoPageTurnMode.continuous => continuousSecondsPreferenceKey,
        ReaderAutoPageTurnMode.interval => intervalSecondsPreferenceKey,
      };

  static double _clampSeconds(double seconds) => seconds.clamp(
    minIntervalSeconds.toDouble(),
    maxIntervalSeconds.toDouble(),
  );

  @override
  void dispose() {
    _disposed = true;
    _isActive = false;
    _isRunning = false;
    _cancelTimer();
    super.dispose();
  }
}
