import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/reader_core/ai/ai_service.dart';

void main() {
  test('preset IDs are non-empty and unique', () {
    final ids = AIModelPresets.all.map((preset) => preset.id).toList();

    expect(ids, everyElement(isNotEmpty));
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('every provider has a valid default preset', () {
    for (final provider in AIProviderType.values) {
      final preset = AIModelPresets.defaultForProvider(provider);
      final settings = preset.toSettings(apiKey: 'test-key');

      final expectedProvider = provider == AIProviderType.custom
          ? AIProviderType.openai
          : provider;
      expect(preset.provider, expectedProvider);
      expect(settings.provider, expectedProvider);
      expect(validateAIProviderSettings(settings), isNull);
    }
  });

  test('provider filtering returns only matching presets', () {
    for (final provider in AIProviderType.values) {
      final presets = AIModelPresets.byProvider(provider);

      if (provider == AIProviderType.custom) {
        expect(presets, isEmpty);
        continue;
      }
      expect(presets, isNotEmpty);
      expect(
        presets,
        everyElement(
          predicate<AIModelPreset>((preset) => preset.provider == provider),
        ),
      );
    }
  });

  test('settings created from presets match the same preset', () {
    for (final preset in AIModelPresets.all) {
      final settings = preset.toSettings(apiKey: 'test-key').normalized();

      expect(AIModelPresets.match(settings), preset);
    }
  });
}
