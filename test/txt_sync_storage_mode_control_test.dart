import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/sync/txt_sync_storage_mode_control.dart';

void main() {
  testWidgets('switching storage requires accepting the cloud format change', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var switches = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: TxtSyncStorageModeControl(
            incremental: false,
            onEnable: () => switches++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(switches, 0);
    await tester.tap(find.text('Use incremental storage'));
    await tester.pumpAndSettle();
    expect(find.textContaining('will stop receiving updates'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(switches, 0);
    await tester.tap(find.text('Use incremental storage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch and sync'));
    await tester.pumpAndSettle();
    expect(switches, 1);
    expect(tester.takeException(), isNull);
  });
}
