part of '../settings_page.dart';

extension _SettingsLayoutPart on _SettingsPageState {
  Widget _buildSettingsTopRow(AppLocalizations l10n, bool useRailNavigation) {
    final palette = PageStyleHelper.palette(context);
    return Row(
      children: [
        Text(
          l10n.settings,
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.05,
          ),
        ),
        const Spacer(),
        InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () =>
              showSideToast(context, context.l10n.settingsHelpPlaceholder),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              Icons.question_mark_rounded,
              size: 20,
              color: palette.iconMuted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: [
              Icon(icon, color: scheme.primary, size: 18),
              const SizedBox(width: 9),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }
}
