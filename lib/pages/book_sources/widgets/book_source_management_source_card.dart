import 'package:flutter/material.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/source_engine/source_health_checker.dart';
import '../../../utils/localization_extension.dart';
import '../../../utils/page_style_helper.dart';
import '../../../widgets/app_menu.dart';
import '../../../widgets/source_cover_image.dart';
import '../controllers/book_source_management_controller.dart';
import '../models/source_edit_fields.dart';
import 'book_source_organization_copy.dart';

enum BookSourceManagementSourceAction {
  edit,
  groups,
  favorite,
  refresh,
  rights,
  login,
  debug,
  health,
  remove,
}

class BookSourceManagementEmptyCard extends StatelessWidget {
  const BookSourceManagementEmptyCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = PageStyleHelper.palette(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(palette.card, palette.border, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.travel_explore_rounded, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.bookSourcesNoSourcesTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                Text(
                  context.l10n.bookSourcesNoSourcesDescription,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class BookSourceManagementNoMatchesCard extends StatelessWidget {
  const BookSourceManagementNoMatchesCard({super.key, required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final palette = PageStyleHelper.palette(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(palette.card, palette.border, 20),
      child: Row(
        children: [
          const Icon(Icons.filter_alt_off_outlined),
          const SizedBox(width: 12),
          Expanded(child: Text(context.l10n.bookSourcesNoMatchingSources)),
          TextButton(
            onPressed: onReset,
            child: Text(context.l10n.bookSourcesResetFilters),
          ),
        ],
      ),
    );
  }
}

String sourceHealthCapabilityLabel(
  BuildContext context,
  SourceHealthCapability capability,
) => switch (capability) {
  SourceHealthCapability.search => context.l10n.sourceHealthCapabilitySearch,
  SourceHealthCapability.discover =>
    context.l10n.sourceHealthCapabilityDiscover,
  SourceHealthCapability.info => context.l10n.sourceHealthCapabilityInfo,
  SourceHealthCapability.catalog => context.l10n.sourceHealthCapabilityCatalog,
  SourceHealthCapability.content => context.l10n.sourceHealthCapabilityContent,
};

BoxDecoration _cardDecoration(Color color, Color border, double radius) {
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: border),
  );
}

class BookSourceManagementSourceCard extends StatelessWidget {
  const BookSourceManagementSourceCard({
    super.key,
    required this.source,
    required this.selectionMode,
    required this.selected,
    required this.additionalProtocolsEnabled,
    required this.onToggleSelection,
    required this.onEnabledChanged,
    required this.onAction,
  });

  final RegisteredBookSource source;
  final bool selectionMode;
  final bool selected;
  final bool additionalProtocolsEnabled;
  final VoidCallback onToggleSelection;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<BookSourceManagementSourceAction> onAction;

  @override
  Widget build(BuildContext context) {
    final palette = PageStyleHelper.palette(context);
    final canEnable =
        source.capabilities.isNotEmpty &&
        (source.sourceProtocol == BookSourceProtocolKind.orsp ||
            additionalProtocolsEnabled);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        key: ValueKey('bookSourceCard-${source.id}'),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
        decoration: _cardDecoration(palette.card, palette.border, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox.square(
                  dimension: 40,
                  child: selectionMode
                      ? Center(
                          child: Checkbox(
                            value: selected,
                            onChanged: (_) => onToggleSelection(),
                          ),
                        )
                      : _SourceIcon(source: source, size: 40),
                ),
                const SizedBox(width: 12),
                Expanded(child: _SourceSummary(source: source)),
                if (!selectionMode) ...[
                  const SizedBox(width: 4),
                  _SourceMenu(source: source, onAction: onAction),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _SourceMetadata(source: source),
            ),
            if (!selectionMode) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    key: ValueKey('bookSourceFavorite-${source.id}'),
                    tooltip: source.isFavorite
                        ? BookSourceOrganizationCopy.of(context).unfavorite
                        : BookSourceOrganizationCopy.of(context).favorite,
                    onPressed: () =>
                        onAction(BookSourceManagementSourceAction.favorite),
                    icon: Icon(
                      source.isFavorite
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      color: source.isFavorite
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  Tooltip(
                    message: source.enabled
                        ? context.l10n.bookSourcesEnabled
                        : context.l10n.bookSourcesDisabled,
                    child: Switch.adaptive(
                      value: source.enabled,
                      onChanged: !canEnable ? null : onEnabledChanged,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourceSummary extends StatelessWidget {
  const _SourceSummary({required this.source});

  final RegisteredBookSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          source.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          source.description.isEmpty
              ? source.apiBaseUrl.host
              : source.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
        ),
      ],
    );
  }
}

class _SourceMetadata extends StatelessWidget {
  const _SourceMetadata({required this.source});

  final RegisteredBookSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final runnable = source.capabilities.isNotEmpty;
    final health = sourceHealthCheckResultOf(source);
    final badges = <Widget>[
      if (sourceRequiresLogin(source))
        _MetaPill(
          label: context.l10n.sourceLoginTitle,
          icon: Icons.key_rounded,
          color: scheme.primary,
        ),
      if (source.sourceProtocol == BookSourceProtocolKind.readingSource &&
          !runnable)
        _MetaPill(
          label: context.l10n.bookSourcesPendingCompatibility,
          icon: Icons.extension_off,
          color: scheme.error,
        ),
      if (health != null && !health.healthy)
        _MetaPill(
          label: health.timedOut
              ? context.l10n.sourceHealthTimedOut
              : context.l10n.sourceHealthPartial,
          icon: Icons.warning_amber_rounded,
          color: scheme.error,
        ),
      if (health?.fullyAvailable == true)
        _MetaPill(
          label: context.l10n.bookSourcesFullyAvailable,
          icon: Icons.verified_rounded,
          color: scheme.tertiary,
        ),
      for (final group in bookSourceGroups(source).take(2))
        _MetaPill(
          label: group,
          icon: Icons.folder_outlined,
          color: scheme.onSurfaceVariant,
        ),
    ];
    if (badges.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 8,
        runSpacing: 5,
        children: [
          for (final badge in badges)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: badge,
            ),
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceMenu extends StatelessWidget {
  const _SourceMenu({required this.source, required this.onAction});

  final RegisteredBookSource source;
  final ValueChanged<BookSourceManagementSourceAction> onAction;

  @override
  Widget build(BuildContext context) {
    return AppPopupMenuButton<String>(
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      onSelected: (value) =>
          onAction(BookSourceManagementSourceAction.values.byName(value)),
      itemBuilder: (context) => [
        if (source.sourceProtocol == BookSourceProtocolKind.readingSource)
          PopupMenuItem(
            value: BookSourceManagementSourceAction.edit.name,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.edit_outlined),
              title: Text(SourceEditCopy.of(context).edit),
            ),
          ),
        PopupMenuItem(
          value: BookSourceManagementSourceAction.groups.name,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(BookSourceOrganizationCopy.of(context).editGroups),
          ),
        ),
        if (source.sourceProtocol == BookSourceProtocolKind.orsp)
          PopupMenuItem(
            value: BookSourceManagementSourceAction.refresh.name,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.refresh_rounded),
              title: Text(context.l10n.bookSourcesRefresh),
            ),
          ),
        if (source.sourceProtocol == BookSourceProtocolKind.orsp)
          PopupMenuItem(
            value: BookSourceManagementSourceAction.rights.name,
            child: Text(context.l10n.bookSourcesRightsDetails),
          ),
        if (sourceRequiresLogin(source))
          PopupMenuItem(
            value: BookSourceManagementSourceAction.login.name,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.key_rounded),
              title: Text(context.l10n.sourceLoginTitle),
            ),
          ),
        if (source.sourceProtocol == BookSourceProtocolKind.readingSource)
          PopupMenuItem(
            value: BookSourceManagementSourceAction.debug.name,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bug_report_outlined),
              title: Text(context.l10n.sourceDebugMenuLabel),
            ),
          ),
        if (source.sourceProtocol == BookSourceProtocolKind.readingSource)
          PopupMenuItem(
            value: BookSourceManagementSourceAction.health.name,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.health_and_safety_outlined),
              title: Text(context.l10n.sourceHealthMenuLabel),
            ),
          ),
        PopupMenuItem(
          value: BookSourceManagementSourceAction.remove.name,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_outline_rounded),
            title: Text(context.l10n.bookSourcesRemove),
          ),
        ),
      ],
    );
  }
}

class _SourceIcon extends StatelessWidget {
  const _SourceIcon({required this.source, required this.size});

  final RegisteredBookSource source;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = source.name.characters.firstOrNull?.toUpperCase() ?? '?';
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(size * 0.29),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    if (source.iconUrl == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.29),
      child: SourceCoverImage(
        url: source.iconUrl!,
        fallback: fallback,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}
