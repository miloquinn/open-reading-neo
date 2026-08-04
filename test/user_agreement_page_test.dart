import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/legal/user_agreement_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'updated terms require the current version and source acknowledgment',
    () async {
      expect(UserAgreementService.currentAgreementVersion, '2026-07-19.2');

      SharedPreferences.setMockInitialValues({
        'userAgreementAccepted': true,
        'agreementAcceptedVersion': '2026-07-13.1',
        'thirdPartySourceBoundaryAccepted': true,
      });

      expect(await UserAgreementService.hasUserAcceptedAgreement(), isFalse);

      await UserAgreementService.acceptAgreement(locale: 'en');

      expect(await UserAgreementService.hasUserAcceptedAgreement(), isTrue);
    },
  );

  testWidgets('welcome flow separates terms, source, and privacy consent', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 844);
    addTearDown(tester.view.reset);
    var agreed = false;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: UserAgreementPage(onAgreed: () => agreed = true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agreementIntroductionPage')), findsOneWidget);
    expect(find.byKey(const Key('agreementStepDot0')), findsOneWidget);
    expect(find.byKey(const Key('agreementStepDot1')), findsOneWidget);
    expect(find.byKey(const Key('agreementStepDot2')), findsOneWidget);
    expect(find.byKey(const Key('agreementStepDot3')), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsNothing);
    expect(find.text('4'), findsNothing);
    expect(find.byKey(const Key('agreementTermsPage')), findsNothing);
    expect(find.byKey(const Key('agreementSourcePage')), findsNothing);
    expect(find.byKey(const Key('agreementPrivacyPage')), findsNothing);
    expect(find.byKey(const Key('agreementSourceBoundaryCard')), findsNothing);

    await tester.tap(find.byKey(const Key('agreementIntroductionNextButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agreementTermsPage')), findsOneWidget);
    expect(find.byKey(const Key('agreementSourcePage')), findsNothing);
    expect(find.byKey(const Key('agreementSourceBoundaryCard')), findsNothing);

    FilledButton termsNextButton() => tester.widget<FilledButton>(
      find.byKey(const Key('agreementTermsNextButton')),
    );

    expect(termsNextButton().onPressed, isNull);

    await tester.tap(find.byKey(const Key('agreementTermsConsent')));
    await tester.pump();
    expect(termsNextButton().onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('agreementTermsNextButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agreementSourcePage')), findsOneWidget);
    expect(
      find.byKey(const Key('agreementSourceBoundaryCard')),
      findsOneWidget,
    );
    expect(find.textContaining('provides no source addresses'), findsOneWidget);

    FilledButton sourceNextButton() => tester.widget<FilledButton>(
      find.byKey(const Key('agreementSourceNextButton')),
    );
    expect(sourceNextButton().onPressed, isNull);

    await tester.tap(find.byKey(const Key('agreementSourceConsent')));
    await tester.pump();
    expect(sourceNextButton().onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('agreementSourceNextButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agreementPrivacyPage')), findsOneWidget);
    expect(
      find.textContaining('retained for no more than 30 days'),
      findsWidgets,
    );

    FilledButton continueButton() => tester.widget<FilledButton>(
      find.byKey(const Key('agreementContinueButton')),
    );

    expect(continueButton().onPressed, isNull);

    await tester.tap(find.byKey(const Key('agreementPrivacyConsent')));
    await tester.pump();
    expect(continueButton().onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('agreementContinueButton')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(agreed, isTrue);
    expect(await UserAgreementService.hasUserAcceptedAgreement(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agreement flow respects reduced motion', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: UserAgreementPage(onAgreed: () {}),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('agreementIntroductionNextButton')));
    await tester.pump();

    expect(find.byKey(const Key('agreementTermsPage')), findsOneWidget);
    expect(find.byKey(const Key('agreementIntroductionPage')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('agreement flow fits a narrow screen in $locale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 720);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: UserAgreementPage(onAgreed: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'introduction in $locale');

      await tester.tap(
        find.byKey(const Key('agreementIntroductionNextButton')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'terms in $locale');
      await tester.tap(find.byKey(const Key('agreementTermsConsent')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('agreementTermsNextButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('agreementSourcePage')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'source in $locale');
      await tester.tap(find.byKey(const Key('agreementSourceConsent')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('agreementSourceNextButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('agreementPrivacyPage')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'privacy in $locale');
    });
  }
}
