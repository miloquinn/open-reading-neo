// 用户首次启动时展示的软件介绍、使用条款与隐私说明。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/app_brand_icon.dart';
import 'package:xxread/widgets/side_toast.dart';

class UserAgreementPage extends StatefulWidget {
  final VoidCallback onAgreed;
  final VoidCallback? onDisagreed;

  const UserAgreementPage({
    super.key,
    required this.onAgreed,
    this.onDisagreed,
  });

  @override
  State<UserAgreementPage> createState() => _UserAgreementPageState();
}

enum _AgreementStep { introduction, terms, source, privacy }

class _UserAgreementPageState extends State<UserAgreementPage> {
  _AgreementStep _step = _AgreementStep.introduction;
  int _transitionDirection = 1;
  bool _termsConfirmed = false;
  bool _sourceBoundaryConfirmed = false;
  bool _privacyConfirmed = false;
  bool _saving = false;
  bool _exiting = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final content = SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 840;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1160),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 48 : 20,
                  wide ? 30 : 18,
                  wide ? 48 : 20,
                  wide ? 28 : 18,
                ),
                child: Column(
                  children: [
                    _buildTopBar(scheme, wide: wide),
                    SizedBox(height: wide ? 24 : 18),
                    _buildStepIndicator(scheme),
                    SizedBox(height: wide ? 22 : 16),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 520),
                        reverseDuration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 390),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        layoutBuilder: (currentChild, previousChildren) =>
                            Stack(
                              alignment: Alignment.center,
                              children: [...previousChildren, ?currentChild],
                            ),
                        transitionBuilder: (child, animation) {
                          if (reduceMotion) return child;
                          final childStep =
                              (child.key as ValueKey<_AgreementStep>).value;
                          final incoming = childStep == _step;
                          final horizontalOffset = incoming
                              ? _transitionDirection * 0.075
                              : -_transitionDirection * 0.045;
                          final slide = Tween<Offset>(
                            begin: Offset(horizontalOffset, 0),
                            end: Offset.zero,
                          ).animate(animation);
                          final scale = Tween<double>(
                            begin: incoming ? 0.985 : 0.995,
                            end: 1,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: slide,
                              child: ScaleTransition(
                                scale: scale,
                                child: child,
                              ),
                            ),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(_step),
                          child: switch (_step) {
                            _AgreementStep.introduction => _buildIntroduction(
                              scheme,
                              wide: wide,
                            ),
                            _AgreementStep.terms => _buildTermsPage(scheme),
                            _AgreementStep.source => _buildSourcePage(scheme),
                            _AgreementStep.privacy => _buildPrivacyPage(scheme),
                          },
                        ),
                      ),
                    ),
                    SizedBox(height: wide ? 18 : 14),
                    _buildNavigation(scheme, wide: wide),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF11110F)
          : const Color(0xFFF4F1EA),
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _PaperGrainPainter(isDark)),
          ),
          AnimatedOpacity(
            opacity: _exiting ? 0 : 1,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 280),
            curve: Curves.easeInOutCubic,
            child: AnimatedScale(
              scale: _exiting ? 0.985 : 1,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 280),
              curve: Curves.easeInOutCubic,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 620),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, (1 - value) * 12),
                    child: child,
                  ),
                ),
                child: content,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(ColorScheme scheme, {required bool wide}) {
    return Row(
      children: [
        _buildBrand(scheme, compact: !wide),
        const Spacer(),
        if (wide)
          Text(
            context.l10n.agreementV2VersionLabel(
              UserAgreementService.currentAgreementVersion,
            ),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.44),
              letterSpacing: 0.4,
            ),
          ),
      ],
    );
  }

  Widget _buildBrand(ColorScheme scheme, {required bool compact}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Hero(
          tag: 'agreementBrandIcon',
          child: AppBrandIcon(
            size: compact ? 42 : 48,
            borderRadius: compact ? 11 : 13,
            border: Border.all(color: scheme.outline.withValues(alpha: 0.18)),
          ),
        ),
        SizedBox(width: compact ? 12 : 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.appTitle,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
            if (!compact)
              Text(
                'OPEN READING',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.46),
                  letterSpacing: 2.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildStepIndicator(ColorScheme scheme) {
    final labels = [
      context.l10n.agreementFlowStepIntroduction,
      context.l10n.agreementFlowStepTerms,
      context.l10n.agreementFlowStepSource,
      context.l10n.agreementFlowStepPrivacy,
    ];
    return Semantics(
      key: const Key('agreementStepIndicator'),
      label: labels[_step.index],
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < labels.length; index++)
              _buildStepItem(scheme, index: index),
          ],
        ),
      ),
    );
  }

  Widget _buildStepItem(ColorScheme scheme, {required int index}) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final active = index == _step.index;
    final label = switch (index) {
      0 => context.l10n.agreementFlowStepIntroduction,
      1 => context.l10n.agreementFlowStepTerms,
      2 => context.l10n.agreementFlowStepSource,
      _ => context.l10n.agreementFlowStepPrivacy,
    };
    return Semantics(
      label: label,
      selected: active,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: AnimatedContainer(
          key: Key('agreementStepDot$index'),
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
          width: active ? 12 : 8,
          height: active ? 12 : 8,
          decoration: BoxDecoration(
            color: active
                ? scheme.primary
                : scheme.outline.withValues(alpha: 0.25),
            shape: BoxShape.circle,
            boxShadow: active
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.24),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildIntroduction(ColorScheme scheme, {required bool wide}) {
    final text = _buildIntroductionText(scheme);
    final visual = _buildReadingVisual(scheme);
    return SingleChildScrollView(
      key: const Key('agreementIntroductionPage'),
      physics: const BouncingScrollPhysics(),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 430),
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(flex: 6, child: text),
                  const SizedBox(width: 56),
                  Expanded(flex: 5, child: visual),
                ],
              )
            : Column(children: [text, const SizedBox(height: 28), visual]),
      ),
    );
  }

  Widget _buildIntroductionText(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.54),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            context.l10n.agreementFlowStepIntroduction,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          context.l10n.agreementV2HeroTitle,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
            height: 1.08,
            letterSpacing: -1.4,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          context.l10n.agreementV2HeroBody,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            height: 1.72,
            color: scheme.onSurface.withValues(alpha: 0.68),
          ),
        ),
        const SizedBox(height: 28),
        _buildPrinciple(
          scheme,
          Icons.folder_outlined,
          context.l10n.agreementV2LocalTitle,
          context.l10n.agreementV2LocalBody,
        ),
        const SizedBox(height: 14),
        _buildPrinciple(
          scheme,
          Icons.code_rounded,
          context.l10n.agreementV2OpenSourceTitle,
          context.l10n.agreementV2OpenSourceBody,
        ),
      ],
    );
  }

  Widget _buildReadingVisual(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AspectRatio(
      aspectRatio: 1.15,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 900),
        curve: Curves.easeOutBack,
        builder: (context, value, child) => Transform.scale(
          scale: 0.9 + value * 0.1,
          child: Opacity(opacity: value.clamp(0, 1), child: child),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1A1A17) : const Color(0xFFFBF9F3),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.07),
                blurRadius: 34,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _ReadingOrbitPainter(scheme)),
                ),
                Transform.translate(
                  offset: const Offset(-52, 4),
                  child: Transform.rotate(
                    angle: -0.12,
                    child: _buildBookShape(
                      scheme,
                      color: scheme.secondaryContainer,
                      width: 116,
                      height: 158,
                    ),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(52, 4),
                  child: Transform.rotate(
                    angle: 0.12,
                    child: _buildBookShape(
                      scheme,
                      color: scheme.tertiaryContainer,
                      width: 116,
                      height: 158,
                    ),
                  ),
                ),
                _buildBookShape(
                  scheme,
                  color: scheme.surface,
                  width: 126,
                  height: 174,
                  child: AppBrandIcon(size: 64, borderRadius: 17),
                ),
                Positioned(
                  bottom: 24,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Text(
                      'EPUB  ·  PDF  ·  TXT  ·  MOBI',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.58),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBookShape(
    ColorScheme scheme, {
    required Color color,
    required double width,
    required double height,
    Widget? child,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(8),
          topRight: Radius.circular(18),
          bottomLeft: Radius.circular(8),
          bottomRight: Radius.circular(18),
        ),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 10,
            top: 0,
            bottom: 0,
            child: Container(
              width: 1,
              color: scheme.outline.withValues(alpha: 0.13),
            ),
          ),
          ?child,
        ],
      ),
    );
  }

  Widget _buildPrinciple(
    ColorScheme scheme,
    IconData icon,
    String title,
    String body,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.055),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            icon,
            size: 19,
            color: scheme.onSurface.withValues(alpha: 0.72),
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(
                body,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  height: 1.55,
                  color: scheme.onSurface.withValues(alpha: 0.58),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTermsPage(ColorScheme scheme) {
    final sections = <(int, String, String)>[
      (
        1,
        context.l10n.agreementV2Section1Title,
        context.l10n.agreementV2Section1Body,
      ),
      (
        2,
        context.l10n.agreementV2Section2Title,
        context.l10n.agreementV2Section2Body,
      ),
      (
        3,
        context.l10n.agreementV2Section3Title,
        context.l10n.agreementV2Section3Body,
      ),
      (
        4,
        context.l10n.agreementV2Section4Title,
        context.l10n.agreementV2Section4Body,
      ),
      (
        7,
        context.l10n.agreementV2Section7Title,
        context.l10n.agreementV2Section7Body,
      ),
      (
        8,
        context.l10n.agreementV2Section8Title,
        context.l10n.agreementV2Section8Body,
      ),
      (
        9,
        context.l10n.agreementV2Section9Title,
        context.l10n.agreementV2Section9Body,
      ),
      (
        10,
        context.l10n.agreementV2Section10Title,
        context.l10n.agreementV2Section10Body,
      ),
      (
        11,
        context.l10n.agreementV2Section11Title,
        context.l10n.agreementV2Section11Body,
      ),
    ];
    return _buildDocumentPanel(
      key: const Key('agreementTermsPage'),
      scheme: scheme,
      icon: Icons.article_outlined,
      title: context.l10n.agreementFlowTermsTitle,
      subtitle: context.l10n.agreementFlowTermsSubtitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildImportantNotice(scheme),
          const SizedBox(height: 26),
          for (var i = 0; i < sections.length; i++) ...[
            _buildLegalSection(
              scheme,
              sections[i].$1,
              sections[i].$2,
              sections[i].$3,
            ),
            if (i != sections.length - 1) const SizedBox(height: 24),
          ],
        ],
      ),
      footer: _buildConsentCheckbox(
        key: const Key('agreementTermsConsent'),
        scheme: scheme,
        value: _termsConfirmed,
        label: context.l10n.agreementFlowTermsConsent,
        onChanged: (value) => setState(() => _termsConfirmed = value),
      ),
    );
  }

  Widget _buildSourcePage(ColorScheme scheme) {
    return _buildDocumentPanel(
      key: const Key('agreementSourcePage'),
      scheme: scheme,
      icon: Icons.hub_outlined,
      title: context.l10n.agreementFlowSourceTitle,
      subtitle: context.l10n.agreementFlowSourceSubtitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSourceBoundary(scheme),
          const SizedBox(height: 22),
          _buildLegalSection(
            scheme,
            5,
            context.l10n.agreementV2Section5Title,
            context.l10n.agreementV2Section5Body,
          ),
        ],
      ),
      footer: _buildConsentCheckbox(
        key: const Key('agreementSourceConsent'),
        scheme: scheme,
        value: _sourceBoundaryConfirmed,
        label: context.l10n.agreementFlowSourceConsent,
        emphasized: true,
        onChanged: (value) => setState(() => _sourceBoundaryConfirmed = value),
      ),
    );
  }

  Widget _buildPrivacyPage(ColorScheme scheme) {
    return _buildDocumentPanel(
      key: const Key('agreementPrivacyPage'),
      scheme: scheme,
      icon: Icons.shield_outlined,
      title: context.l10n.agreementFlowPrivacyTitle,
      subtitle: context.l10n.agreementFlowPrivacySubtitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPrivacySummary(
            scheme,
            icon: Icons.devices_outlined,
            title: context.l10n.agreementFlowPrivacyLocalTitle,
            body: context.l10n.agreementFlowPrivacyLocalBody,
          ),
          const SizedBox(height: 12),
          _buildPrivacySummary(
            scheme,
            icon: Icons.wifi_outlined,
            title: context.l10n.agreementFlowPrivacyNetworkTitle,
            body: context.l10n.agreementFlowPrivacyNetworkBody,
          ),
          const SizedBox(height: 12),
          _buildPrivacySummary(
            scheme,
            icon: Icons.schedule_outlined,
            title: context.l10n.agreementFlowPrivacyRetentionTitle,
            body: context.l10n.agreementFlowPrivacyRetentionBody,
          ),
          const SizedBox(height: 26),
          _buildLegalSection(
            scheme,
            6,
            context.l10n.agreementV2Section6Title,
            context.l10n.agreementV2Section6Body,
          ),
        ],
      ),
      footer: _buildConsentCheckbox(
        key: const Key('agreementPrivacyConsent'),
        scheme: scheme,
        value: _privacyConfirmed,
        label: context.l10n.agreementFlowPrivacyConsent,
        emphasized: true,
        onChanged: (value) => setState(() => _privacyConfirmed = value),
      ),
    );
  }

  Widget _buildDocumentPanel({
    required Key key,
    required ColorScheme scheme,
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget body,
    required Widget footer,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Container(
          key: key,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1B1B18) : const Color(0xFFFCFBF7),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.16)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.07),
                blurRadius: 34,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 17),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withValues(alpha: 0.52),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, size: 21, color: scheme.primary),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.4,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  height: 1.45,
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.54,
                                  ),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outline.withValues(alpha: 0.13)),
              Expanded(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
                    child: body,
                  ),
                ),
              ),
              Divider(height: 1, color: scheme.outline.withValues(alpha: 0.13)),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
                child: footer,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImportantNotice(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.13)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 20,
            color: scheme.onSurface.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.agreementV2ImportantNotice,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.65,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.78),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceBoundary(ColorScheme scheme) {
    final points = <String>[
      context.l10n.agreementV2SourceBoundaryPoint1,
      context.l10n.agreementV2SourceBoundaryPoint2,
      context.l10n.agreementV2SourceBoundaryPoint3,
    ];
    return Container(
      key: const Key('agreementSourceBoundaryCard'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.l10n.agreementV2SourceBoundaryTitle,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final point in points) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    point,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      height: 1.55,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.84),
                    ),
                  ),
                ),
              ],
            ),
            if (point != points.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildPrivacySummary(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.11)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    height: 1.55,
                    color: scheme.onSurface.withValues(alpha: 0.64),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegalSection(
    ColorScheme scheme,
    int index,
    String title,
    String body,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              child: Text(
                index.toString().padLeft(2, '0'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.34),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Expanded(
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Padding(
          padding: const EdgeInsets.only(left: 32),
          child: Text(
            body,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              height: 1.72,
              color: scheme.onSurface.withValues(alpha: 0.68),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConsentCheckbox({
    required Key key,
    required ColorScheme scheme,
    required bool value,
    required String label,
    required ValueChanged<bool> onChanged,
    bool emphasized = false,
  }) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 240),
      decoration: BoxDecoration(
        color: emphasized || value
            ? scheme.primaryContainer.withValues(alpha: value ? 0.4 : 0.22)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          key: key,
          onTap: _saving ? null : () => onChanged(!value),
          borderRadius: BorderRadius.circular(11),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Checkbox(
                  value: value,
                  onChanged: _saving
                      ? null
                      : (nextValue) => onChanged(nextValue ?? false),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      height: 1.45,
                      fontWeight: emphasized
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: scheme.onSurface.withValues(alpha: 0.78),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavigation(ColorScheme scheme, {required bool wide}) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final canAdvance = switch (_step) {
      _AgreementStep.introduction => true,
      _AgreementStep.terms => _termsConfirmed && !_saving,
      _AgreementStep.source => _sourceBoundaryConfirmed && !_saving,
      _AgreementStep.privacy => _privacyConfirmed && !_saving,
    };
    final primaryLabel = switch (_step) {
      _AgreementStep.introduction => context.l10n.agreementFlowNext,
      _AgreementStep.terms => context.l10n.agreementFlowNext,
      _AgreementStep.source => context.l10n.agreementFlowNext,
      _AgreementStep.privacy => context.l10n.agreementFlowEnterApp,
    };
    final primaryKey = switch (_step) {
      _AgreementStep.introduction => const Key(
        'agreementIntroductionNextButton',
      ),
      _AgreementStep.terms => const Key('agreementTermsNextButton'),
      _AgreementStep.source => const Key('agreementSourceNextButton'),
      _AgreementStep.privacy => const Key('agreementContinueButton'),
    };

    return Row(
      children: [
        if (_step == _AgreementStep.introduction)
          TextButton(
            onPressed: _saving ? null : _onDisagreePressed,
            child: Text(context.l10n.agreementV2ExitLabel),
          )
        else
          TextButton.icon(
            key: const Key('agreementBackButton'),
            onPressed: _saving ? null : _goBack,
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: Text(context.l10n.agreementFlowBack),
          ),
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: wide ? 224 : double.infinity,
              child: FilledButton(
                key: primaryKey,
                onPressed: canAdvance ? _goForward : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                child: AnimatedSwitcher(
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  child: _saving
                      ? const SizedBox(
                          key: ValueKey('saving'),
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Row(
                          key: ValueKey(primaryLabel),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                primaryLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              _step == _AgreementStep.privacy
                                  ? Icons.check_rounded
                                  : Icons.arrow_forward_rounded,
                              size: 18,
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _goForward() {
    switch (_step) {
      case _AgreementStep.introduction:
        _setStep(_AgreementStep.terms);
      case _AgreementStep.terms:
        if (_termsConfirmed) {
          _setStep(_AgreementStep.source);
        }
      case _AgreementStep.source:
        if (_sourceBoundaryConfirmed) {
          _setStep(_AgreementStep.privacy);
        }
      case _AgreementStep.privacy:
        if (_privacyConfirmed) _onAgreePressed();
    }
  }

  void _goBack() {
    switch (_step) {
      case _AgreementStep.introduction:
        return;
      case _AgreementStep.terms:
        _setStep(_AgreementStep.introduction);
      case _AgreementStep.source:
        _setStep(_AgreementStep.terms);
      case _AgreementStep.privacy:
        _setStep(_AgreementStep.source);
    }
  }

  void _setStep(_AgreementStep nextStep) {
    if (_saving || nextStep == _step) return;
    setState(() {
      _transitionDirection = nextStep.index > _step.index ? 1 : -1;
      _step = nextStep;
    });
  }

  Future<void> _onAgreePressed() async {
    if (!_termsConfirmed ||
        !_sourceBoundaryConfirmed ||
        !_privacyConfirmed ||
        _saving) {
      return;
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    setState(() => _saving = true);
    try {
      await UserAgreementService.acceptAgreement(
        locale: Localizations.localeOf(context).toLanguageTag(),
      );
      if (!mounted) return;
      setState(() => _exiting = true);
      if (!reduceMotion) {
        await Future<void>.delayed(const Duration(milliseconds: 260));
      }
      if (mounted) widget.onAgreed();
    } catch (error) {
      debugPrint('保存用户协议状态失败: $error');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _exiting = false;
      });
      showSideToast(
        context,
        context.l10n.agreementV2SaveFailed,
        kind: SideToastKind.error,
      );
    }
  }

  void _onDisagreePressed() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.agreementV2ExitDialogTitle),
        content: Text(context.l10n.agreementV2ExitDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.agreementV2CancelLabel),
          ),
          FilledButton.tonal(
            onPressed: () {
              Navigator.pop(dialogContext);
              widget.onDisagreed?.call();
            },
            child: Text(context.l10n.agreementV2ConfirmExitLabel),
          ),
        ],
      ),
    );
  }
}

class _PaperGrainPainter extends CustomPainter {
  final bool isDark;
  const _PaperGrainPainter(this.isDark);

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.018)
      ..strokeWidth = 0.6;
    for (double y = 18; y < size.height; y += 22) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    final accentPaint = Paint()
      ..color = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.032)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width * 0.08, 0),
      Offset(size.width * 0.08, size.height),
      accentPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _PaperGrainPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}

class _ReadingOrbitPainter extends CustomPainter {
  final ColorScheme scheme;
  const _ReadingOrbitPainter(this.scheme);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 8);
    final orbitPaint = Paint()
      ..color = scheme.primary.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.78,
        height: size.height * 0.52,
      ),
      orbitPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.54,
        height: size.height * 0.78,
      ),
      orbitPaint,
    );

    final dotPaint = Paint()..color = scheme.primary.withValues(alpha: 0.52);
    for (final angle in [-0.28, 2.42, 4.8]) {
      final point = Offset(
        center.dx + math.cos(angle) * size.width * 0.39,
        center.dy + math.sin(angle) * size.height * 0.26,
      );
      canvas.drawCircle(point, 3.2, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ReadingOrbitPainter oldDelegate) =>
      oldDelegate.scheme != scheme;
}

class UserAgreementService {
  static const String currentAgreementVersion = '2026-07-19.2';
  static const String _keyAgreementAccepted = 'userAgreementAccepted';
  static const String _keyAcceptedDate = 'agreementAcceptedDate';
  static const String _keyAcceptedVersion = 'agreementAcceptedVersion';
  static const String _keyAcceptedLocale = 'agreementAcceptedLocale';
  static const String _keySourceBoundaryAccepted =
      'thirdPartySourceBoundaryAccepted';

  static Future<bool> hasUserAcceptedAgreement() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getBool(_keyAgreementAccepted) ?? false) &&
          prefs.getString(_keyAcceptedVersion) == currentAgreementVersion &&
          (prefs.getBool(_keySourceBoundaryAccepted) ?? false);
    } catch (error) {
      debugPrint('检查用户协议状态失败: $error');
      return false;
    }
  }

  static Future<void> acceptAgreement({required String locale}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAgreementAccepted, true);
    await prefs.setString(
      _keyAcceptedDate,
      DateTime.now().toUtc().toIso8601String(),
    );
    await prefs.setString(_keyAcceptedVersion, currentAgreementVersion);
    await prefs.setString(_keyAcceptedLocale, locale);
    await prefs.setBool(_keySourceBoundaryAccepted, true);
  }

  static Future<DateTime?> getAgreementAcceptedDate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_keyAcceptedDate);
      return value == null ? null : DateTime.tryParse(value);
    } catch (error) {
      debugPrint('读取用户协议同意时间失败: $error');
      return null;
    }
  }

  static Future<void> resetAgreementStatus() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAgreementAccepted);
    await prefs.remove(_keyAcceptedDate);
    await prefs.remove(_keyAcceptedVersion);
    await prefs.remove(_keyAcceptedLocale);
    await prefs.remove(_keySourceBoundaryAccepted);
  }
}
