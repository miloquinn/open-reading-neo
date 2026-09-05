import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/utils/glass_config.dart';
import 'package:xxread/utils/ui_style.dart';
import 'package:xxread/widgets/glass_control_surface.dart';

void main() {
  setUp(() => GlassEffectConfig.setDisableAllGlassEffects(false));
  tearDown(() => GlassEffectConfig.setDisableAllGlassEffects(false));

  testWidgets('uses one lightweight blur for a glass control', (tester) async {
    await tester.pumpWidget(_host());

    expect(find.byType(BackdropFilter), findsOneWidget);
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.filter, isNotNull);
  });

  testWidgets('supports circular controls and solid fallback styles', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(shape: const CircleBorder(), style: AppUiStyle.material3),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    final clip = tester.widget<ClipPath>(find.byType(ClipPath));
    expect((clip.clipper as ShapeBorderClipper).shape, isA<CircleBorder>());
  });

  testWidgets(
    'controls inside a blurred parent retain glass without filtering twice',
    (tester) async {
      await tester.pumpWidget(_host(blurBackground: false));
      expect(find.byType(BackdropFilter), findsNothing);
      final surface = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect((surface.decoration as ShapeDecoration).gradient, isNotNull);
    },
  );

  testWidgets('explicit glass opt out uses the solid surface', (tester) async {
    await tester.pumpWidget(_host(useGlass: false));

    expect(find.byType(BackdropFilter), findsNothing);
  });
}

Widget _host({
  OutlinedBorder shape = const StadiumBorder(),
  AppUiStyle style = AppUiStyle.glass,
  bool useGlass = true,
  bool blurBackground = true,
}) {
  return MaterialApp(
    theme: ThemeData(extensions: [UiStyleThemeExtension(style: style)]),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 88,
          height: 44,
          child: GlassControlSurface(
            shape: shape,
            color: Colors.teal,
            useGlass: useGlass,
            blurBackground: blurBackground,
            child: const Center(child: Text('Control')),
          ),
        ),
      ),
    ),
  );
}
