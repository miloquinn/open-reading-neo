import 'platform_reader_aloud_media_session.dart';

/// Compatibility facade for integrations that still use the former Android-
/// specific name. New code should use [PlatformReaderAloudMediaSession].
@Deprecated('Use PlatformReaderAloudMediaSession instead.')
abstract final class AndroidReaderAloudNotification {
  static PlatformReaderAloudMediaSession get instance =>
      PlatformReaderAloudMediaSession.instance;
}
