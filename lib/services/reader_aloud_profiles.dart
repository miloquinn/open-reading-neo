part of 'reader_aloud_service.dart';

enum ReaderAloudPresentation { player, controls }

@immutable
class ReaderAloudCloudProfile {
  const ReaderAloudCloudProfile({
    required this.id,
    required this.name,
    required this.settings,
  });

  final String id;
  final String name;
  final ReaderAloudCloudSettings settings;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': settings.baseUrl,
    'model': settings.model,
    'voice': settings.voice,
    'format': settings.responseFormat,
    'fallback': settings.fallbackToSystem,
  };

  factory ReaderAloudCloudProfile.fromJson(Map<String, dynamic> json) =>
      ReaderAloudCloudProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        settings: ReaderAloudCloudSettings(
          baseUrl: json['baseUrl'] as String,
          model: json['model'] as String,
          voice: json['voice'] as String,
          responseFormat: json['format'] as String,
          fallbackToSystem: json['fallback'] as bool,
        ),
      );
}

/// Optional capability for stores that support multiple named configurations.
abstract interface class ReaderAloudProfileStore {
  Future<List<ReaderAloudCloudProfile>> loadProfiles();
  Future<String> loadActiveProfileId();
  Future<void> saveProfiles(
    List<ReaderAloudCloudProfile> profiles,
    String activeId,
  );
  Future<String?> readProfileKey(String id);
  Future<void> writeProfileKey(String id, String? key);
}
