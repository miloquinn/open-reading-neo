import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/source_engine/source_browser_session.dart';
import 'package:xxread/book_sources/source_engine/source_login_ui.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/source_login_page.dart';

void main() {
  testWidgets('web login shows resolved website and saves browser session', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final client = _LoginClient();
    await _pumpPage(tester, source: _webSource, client: client);

    expect(find.text('Sign in on the original website'), findsOneWidget);
    expect(
      find.text('https://reader.example.test/account/login'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Cookies and website local storage'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('source-login-clear')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('source-login-browser-open')));
    await tester.pumpAndSettle();

    expect(client.loginCount, 1);
    expect(client.lastValues, isEmpty);
    expect(find.text('Source sign-in session updated'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('unsupported platforms explain and disable website login', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final client = _LoginClient();
    await _pumpPage(tester, source: _webSource, client: client);

    expect(
      find.text(
        'Website sign-in is available on Android, iPhone, iPad, and Mac.',
      ),
      findsOneWidget,
    );
    final browserButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('source-login-browser-open')),
    );
    expect(browserButton.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('source-login-clear')));
    await tester.pumpAndSettle();
    expect(client.clearCount, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('form login remains available and submits entered values', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final client = _LoginClient(
      fields: const [
        SourceLoginField(name: 'account', type: 'text', viewName: 'Account'),
        SourceLoginField(
          name: 'password',
          type: 'password',
          viewName: 'Password',
        ),
      ],
    );
    await _pumpPage(tester, source: _formSource, client: client);

    expect(
      find.byKey(const ValueKey('source-login-browser-open')),
      findsNothing,
    );
    await tester.enterText(find.widgetWithText(TextField, 'Account'), 'reader');
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'secret',
    );
    await tester.tap(find.text('Sign in and save session'));
    await tester.pumpAndSettle();

    expect(client.lastValues, {'account': 'reader', 'password': 'secret'});
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('closing website login leaves the page without an error', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final client = _LoginClient(cancelLogin: true);
    await _pumpPage(tester, source: _webSource, client: client);

    await tester.tap(find.byKey(const ValueKey('source-login-browser-open')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not update'), findsNothing);
    final browserButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('source-login-browser-open')),
    );
    expect(browserButton.onPressed, isNotNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required RegisteredBookSource source,
  required BookSourceClient client,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SourceLoginPage(source: source, client: client),
    ),
  );
  await tester.pumpAndSettle();
}

class _LoginClient extends BookSourceClient {
  _LoginClient({this.fields = const [], this.cancelLogin = false});

  final List<SourceLoginField> fields;
  final bool cancelLogin;
  int loginCount = 0;
  int clearCount = 0;
  Map<String, String>? lastValues;

  @override
  Future<List<SourceLoginField>> loadLoginFields(
    RegisteredBookSource source,
  ) async => fields;

  @override
  Future<void> loginSource(
    RegisteredBookSource source,
    Map<String, String> values,
  ) async {
    loginCount++;
    if (cancelLogin) throw const SourceBrowserCancelled();
    lastValues = Map.of(values);
  }

  @override
  Future<void> clearSourceLogin(RegisteredBookSource source) async {
    clearCount++;
  }
}

final _webSource = _source({
  'bookSourceUrl': 'https://reader.example.test/base/',
  'loginUrl': '/account/login',
});

final _formSource = _source({
  'bookSourceUrl': 'https://reader.example.test',
  'loginUrl': 'function login() { return true; }',
});

RegisteredBookSource _source(Map<String, dynamic> config) =>
    RegisteredBookSource(
      id: 'login-source',
      name: 'Login source',
      description: '',
      manifestUrl: Uri.parse('https://reader.example.test/source.json'),
      apiBaseUrl: Uri.parse('https://reader.example.test'),
      protocolVersion: '1',
      languages: const ['en'],
      capabilities: const {},
      enabled: true,
      addedAt: DateTime(2026),
      sourceProtocol: BookSourceProtocolKind.readingSource,
      sourceConfig: config,
    );
