import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/ai_settings_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';

class _FakeAiService extends ReaderHttpAIService {
  AIProviderSettings active = AIProviderSettings.defaults(
    AIProviderType.openai,
  );

  @override
  Future<AIProviderSettings> loadSettings([AIProviderType? provider]) async {
    if (provider == null || provider == active.provider) return active;
    return AIProviderSettings.defaults(provider);
  }

  @override
  Future<void> saveSettings(AIProviderSettings settings) async {
    active = settings.normalized();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('custom provider exposes protocol selector and v1 guidance', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AiSettingsPage(aiService: _FakeAiService()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom').last);
    await tester.pumpAndSettle();

    expect(find.text('API protocol'), findsOneWidget);
    expect(find.text('OpenAI Compatible'), findsOneWidget);
    expect(find.textContaining('usually needs to include /v1'), findsOneWidget);

    await tester.tap(find.text('OpenAI Compatible'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('may include /v1 or omit it'), findsOneWidget);
  });
}
