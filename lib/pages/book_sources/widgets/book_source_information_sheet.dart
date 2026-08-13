import 'package:flutter/material.dart';

import '../../../utils/localization_extension.dart';

enum BookSourceInformationAction { protocol, repository, rightsReport }

class BookSourceInformationSheet extends StatelessWidget {
  const BookSourceInformationSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.bookSourcesInformationTitle,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.bookSourcesInformationSubtitle,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 16),
            _InformationTile(
              icon: Icons.api_rounded,
              title: context.l10n.bookSourcesProtocolTitle,
              subtitle: context.l10n.bookSourcesInformationProtocolSubtitle,
              onTap: () =>
                  Navigator.pop(context, BookSourceInformationAction.protocol),
            ),
            const SizedBox(height: 8),
            _InformationTile(
              icon: Icons.open_in_new_rounded,
              title: context.l10n.bookSourcesProtocolRepository,
              subtitle: context.l10n.bookSourcesInformationRepositorySubtitle,
              onTap: () => Navigator.pop(
                context,
                BookSourceInformationAction.repository,
              ),
            ),
            const SizedBox(height: 8),
            _InformationTile(
              icon: Icons.report_outlined,
              title: context.l10n.bookSourcesRightsReport,
              subtitle: context.l10n.bookSourcesInformationRightsSubtitle,
              onTap: () => Navigator.pop(
                context,
                BookSourceInformationAction.rightsReport,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InformationTile extends StatelessWidget {
  const _InformationTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: scheme.primary, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
