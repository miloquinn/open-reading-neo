import 'package:flutter/material.dart';

import '../../../utils/localization_extension.dart';
import '../../../utils/page_style_helper.dart';

class BookSourceProtocolPanel extends StatelessWidget {
  const BookSourceProtocolPanel({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.onShowDetails,
    required this.onOpenRepository,
    required this.onOpenRightsReport,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onShowDetails;
  final VoidCallback onOpenRepository;
  final VoidCallback onOpenRightsReport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = PageStyleHelper.palette(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: const Key('bookSourcesProtocolCardToggle'),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(Icons.api_rounded, size: 18, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.l10n.bookSourcesProtocolTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.bookSourcesProtocolDescription,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: onShowDetails,
                          icon: const Icon(Icons.schema_outlined, size: 18),
                          label: Text(context.l10n.bookSourcesProtocolDetails),
                        ),
                        TextButton.icon(
                          onPressed: onOpenRepository,
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: Text(
                            context.l10n.bookSourcesProtocolRepository,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: onOpenRightsReport,
                          icon: const Icon(Icons.report_outlined, size: 18),
                          label: Text(context.l10n.bookSourcesRightsReport),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
