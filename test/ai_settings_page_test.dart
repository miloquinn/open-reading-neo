import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/ai_model_editor_page.dart';
import 'package:xxread/pages/settings/ai_settings_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';

class _FakeAiService extends ReaderHttpAIService {
  _FakeAiService({this.saveError});

  final Object? saveError;
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
    if (saveError != null) throw saveError!;
    active = settings.normalized();
  }
}

Future<void> _pumpPage(WidgetTester tester, _FakeAiService service) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AiSettingsPage(aiService: service),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openAddModel(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Add model'));
  await tester.pumpAndSettle();
}

Future<void> _pumpEditor(
  WidgetTester tester,
  _FakeAiService service, {
  EdgeInsets viewInsets = EdgeInsets.zero,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          viewInsets: viewInsets,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: AiModelEditorPage(
        initialSettings: AIProviderSettings.defaults(AIProviderType.openai),
        initialIsCustom: false,
        isEditing: false,
        aiService: service,
        knownApiKey: (_, _, _) => '',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('custom provider exposes protocol selector and v1 guidance', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeAiService());
    await _openAddModel(tester);

    expect(find.byKey(const ValueKey('floating-subpage-back')), findsOneWidget);
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

  testWidgets('preset fields stay editable and save from the full page', (
    tester,
  ) async {
    final service = _FakeAiService();
    await _pumpPage(tester, service);
    await _openAddModel(tester);

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'https://gateway.example/v1');
    await tester.enterText(fields.at(1), 'test-key');
    await tester.enterText(fields.at(2), 'reading-model');
    await tester.tap(find.text('Add and enable'));
    await tester.pumpAndSettle();

    expect(service.active.baseUrl, 'https://gateway.example/v1');
    expect(service.active.model, 'reading-model');
    expect(service.active.apiKey, 'test-key');
    expect(find.text('AI Reading Assistant'), findsOneWidget);
  });

  testWidgets('save errors remain inline without dismissing the editor', (
    tester,
  ) async {
    final service = _FakeAiService(saveError: StateError('save unavailable'));
    await _pumpPage(tester, service);
    await _openAddModel(tester);

    await tester.enterText(find.byType(TextFormField).at(1), 'test-key');
    await tester.tap(find.text('Add and enable'));
    await tester.pumpAndSettle();

    expect(find.textContaining('save unavailable'), findsOneWidget);
    expect(find.text('Add model'), findsOneWidget);
    expect(find.byKey(const ValueKey('floating-subpage-back')), findsOneWidget);
  });

  testWidgets('switching presets on the same endpoint retains the typed key', (
    tester,
  ) async {
    final service = _FakeAiService();
    await _pumpEditor(tester, service);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), 'typed-key');
    final presets = AIModelPresets.byProvider(AIProviderType.openai);
    expect(presets.length, greaterThan(1));
    await tester.tap(
      find.text('${presets.first.vendor} · ${presets.first.label}'),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('${presets[1].vendor} · ${presets[1].label}').last,
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextFormField>(fields.at(1)).controller!.text,
      'typed-key',
    );
  });

  testWidgets('save error stays visible above a compact keyboard viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final service = _FakeAiService(saveError: StateError('save unavailable'));
    await _pumpEditor(
      tester,
      service,
      viewInsets: const EdgeInsets.only(bottom: 240),
      textScale: 1.4,
    );

    await tester.enterText(find.byType(TextFormField).at(1), 'test-key');
    expect(find.text('Add and enable').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Add and enable'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('save unavailable').hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Add and enable').hitTestable(), findsOneWidget);
  });
}
