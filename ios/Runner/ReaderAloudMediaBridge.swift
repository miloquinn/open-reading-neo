import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// Connects the app-scoped Flutter read-aloud session to iOS media controls.
///
/// Speech/audio playback still belongs to Flutter. This bridge owns the shared
/// audio-session policy and mirrors the current chapter into Control Center so
/// that playback can continue and be controlled while the app is backgrounded.
final class ReaderAloudMediaBridge {
  private static let channelName = "com.niki.xxread/reader_aloud"
  private let channel: FlutterMethodChannel
  private let audioSession = AVAudioSession.sharedInstance()
  private let commandCenter = MPRemoteCommandCenter.shared()
  private let nowPlayingCenter = MPNowPlayingInfoCenter.default()

  private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
  private var notificationTokens: [NSObjectProtocol] = []
  private var audioSessionActive = false
  private var sessionVisible = false
  private var playbackState = "idle"
  private var interruptionInProgress = false
  private var resumeAfterInterruption = false
  private var latestNowPlayingInfo: [String: Any]?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    installRemoteCommands()
    observeAudioSession()
    updateRemoteCommandAvailability()
  }

  deinit {
    channel.setMethodCallHandler(nil)
    for entry in commandTargets {
      entry.command.removeTarget(entry.target)
    }
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestNotificationPermission":
      // iOS media controls do not require notification permission.
      result(true)
    case "show":
      show(call.arguments, result: result)
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func show(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = rawArguments as? [String: Any],
          let bookTitle = arguments["bookTitle"] as? String,
          let chapterTitle = arguments["chapterTitle"] as? String,
          let state = arguments["state"] as? String,
          let chapterIndex = integer(arguments["chapterIndex"]),
          let chapterCount = integer(arguments["chapterCount"]),
          let progressValue = number(arguments["progress"]) else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "bookTitle, chapterTitle, state, and chapter progress are required",
          details: nil
        )
      )
      return
    }

    guard ["loading", "playing", "paused", "error"].contains(state),
          chapterIndex >= 0,
          chapterCount >= 0,
          progressValue.isFinite else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "invalid playback state or chapter progress",
          details: nil
        )
      )
      return
    }

    if !interruptionInProgress {
      do {
        try activateAudioSessionIfNeeded()
      } catch {
        result(
          FlutterError(
            code: "audio_session_failed",
            message: "Unable to activate the iOS spoken-audio session: \(error.localizedDescription)",
            details: nil
          )
        )
        return
      }
    }

    sessionVisible = true
    playbackState = state

    let isPlaying = state == "playing"
    let safeChapterCount = max(0, chapterCount)
    let displayChapterIndex = safeChapterCount > 0
      ? min(max(chapterIndex + 1, 1), safeChapterCount)
      : max(chapterIndex + 1, 1)

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: chapterTitle.isEmpty ? bookTitle : chapterTitle,
      MPMediaItemPropertyArtist: bookTitle,
      MPMediaItemPropertyAlbumTitle: bookTitle,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPMediaItemPropertyAlbumTrackNumber: displayChapterIndex,
    ]
    if safeChapterCount > 0 {
      info[MPMediaItemPropertyAlbumTrackCount] = safeChapterCount
    }
    latestNowPlayingInfo = info
    nowPlayingCenter.nowPlayingInfo = info

    // Reader progress is a normalized character offset, not a media time, so
    // the first version deliberately omits a misleading time-based scrubber.

    UIApplication.shared.beginReceivingRemoteControlEvents()
    updateRemoteCommandAvailability()
    result(nil)
  }

  private func stop() {
    sessionVisible = false
    playbackState = "idle"
    interruptionInProgress = false
    resumeAfterInterruption = false
    latestNowPlayingInfo = nil
    nowPlayingCenter.nowPlayingInfo = nil
    updateRemoteCommandAvailability()
    UIApplication.shared.endReceivingRemoteControlEvents()

    guard audioSessionActive else { return }
    do {
      try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    } catch {
      NSLog("Reader aloud audio-session deactivation failed: %@", error.localizedDescription)
    }
    audioSessionActive = false
  }

  private func activateAudioSessionIfNeeded() throws {
    guard !audioSessionActive else { return }
    try audioSession.setCategory(
      .playback,
      mode: .spokenAudio,
      options: []
    )
    try audioSession.setActive(true)
    audioSessionActive = true
  }

  private func installRemoteCommands() {
    commandCenter.changePlaybackPositionCommand.isEnabled = false
    commandCenter.skipForwardCommand.isEnabled = false
    commandCenter.skipBackwardCommand.isEnabled = false

    addTarget(to: commandCenter.playCommand, action: "play")
    addTarget(to: commandCenter.pauseCommand, action: "pause")
    addTarget(to: commandCenter.togglePlayPauseCommand, action: "playPause")
    addTarget(to: commandCenter.previousTrackCommand, action: "previous")
    addTarget(to: commandCenter.nextTrackCommand, action: "next")
    addTarget(to: commandCenter.stopCommand, action: "stop")
  }

  private func addTarget(to command: MPRemoteCommand, action: String) {
    let target = command.addTarget { [weak self] _ in
      guard let self, self.sessionVisible else { return .commandFailed }
      self.sendControl(action)
      return .success
    }
    commandTargets.append((command, target))
  }

  private func updateRemoteCommandAvailability() {
    let isPlaying = playbackState == "playing"
    let isTransitioning = playbackState == "loading"
    commandCenter.playCommand.isEnabled = sessionVisible && !isPlaying && !isTransitioning
    commandCenter.pauseCommand.isEnabled = sessionVisible && isPlaying
    commandCenter.togglePlayPauseCommand.isEnabled = sessionVisible && !isTransitioning
    commandCenter.previousTrackCommand.isEnabled = sessionVisible && !isTransitioning
    commandCenter.nextTrackCommand.isEnabled = sessionVisible && !isTransitioning
    commandCenter.stopCommand.isEnabled = sessionVisible
  }

  private func observeAudioSession() {
    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: audioSession,
        queue: .main
      ) { [weak self] notification in
        self?.handleInterruption(notification)
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: audioSession,
        queue: .main
      ) { [weak self] notification in
        self?.handleRouteChange(notification)
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: audioSession,
        queue: .main
      ) { [weak self] _ in
        self?.handleMediaServicesReset()
      }
    )
  }

  private func handleInterruption(_ notification: Notification) {
    guard sessionVisible,
          let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
          let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

    switch type {
    case .began:
      resumeAfterInterruption = playbackState == "playing"
      interruptionInProgress = true
      audioSessionActive = false
      if resumeAfterInterruption {
        setDisplayedPlaybackState("paused")
        sendControl("pause")
      }
    case .ended:
      interruptionInProgress = false
      let rawOptions =
        (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
      guard resumeAfterInterruption, options.contains(.shouldResume) else {
        resumeAfterInterruption = false
        return
      }
      resumeAfterInterruption = false
      do {
        try activateAudioSessionIfNeeded()
        sendControl("play")
      } catch {
        NSLog("Reader aloud audio-session resume failed: %@", error.localizedDescription)
      }
    @unknown default:
      break
    }
  }

  private func handleRouteChange(_ notification: Notification) {
    guard sessionVisible,
          playbackState == "playing",
          let rawReason =
            (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
          let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
          reason == .oldDeviceUnavailable else { return }
    setDisplayedPlaybackState("paused")
    sendControl("pause")
  }

  private func handleMediaServicesReset() {
    audioSessionActive = false
    guard sessionVisible else { return }
    do {
      try activateAudioSessionIfNeeded()
      nowPlayingCenter.nowPlayingInfo = latestNowPlayingInfo
      updateRemoteCommandAvailability()
      if playbackState == "playing" {
        sendControl("refresh")
      }
    } catch {
      NSLog("Reader aloud media-services recovery failed: %@", error.localizedDescription)
    }
  }

  private func sendControl(_ action: String) {
    if Thread.isMainThread {
      channel.invokeMethod("control", arguments: action)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.channel.invokeMethod("control", arguments: action)
      }
    }
  }

  private func setDisplayedPlaybackState(_ state: String) {
    playbackState = state
    if var info = latestNowPlayingInfo {
      info[MPNowPlayingInfoPropertyPlaybackRate] = state == "playing" ? 1.0 : 0.0
      latestNowPlayingInfo = info
      nowPlayingCenter.nowPlayingInfo = info
    }
    updateRemoteCommandAvailability()
  }

  private func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    return (value as? NSNumber)?.intValue
  }

  private func number(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    return (value as? NSNumber)?.doubleValue
  }
}
