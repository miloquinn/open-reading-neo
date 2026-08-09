import 'package:flutter/material.dart';

import '../../../utils/localization_extension.dart';

class BookSourceGroupPicker extends StatefulWidget {
  const BookSourceGroupPicker({
    super.key,
    required this.groups,
    required this.selected,
  });

  final List<String> groups;
  final String? selected;

  @override
  State<BookSourceGroupPicker> createState() => _BookSourceGroupPickerState();
}

class _BookSourceGroupPickerState extends State<BookSourceGroupPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final groups = widget.groups
        .where((group) => query.isEmpty || group.toLowerCase().contains(query))
        .toList(growable: false);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              context.l10n.bookSourcesChooseGroup,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('bookSourceGroupSearchField'),
              decoration: InputDecoration(
                hintText: context.l10n.bookSourcesSearchGroups,
                prefixIcon: const Icon(Icons.search_rounded),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: groups.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ListTile(
                    leading: Icon(
                      widget.selected == null
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Text(context.l10n.bookSourcesAllGroups),
                    onTap: () => Navigator.pop(context, ''),
                  );
                }
                final group = groups[index - 1];
                return ListTile(
                  leading: Icon(
                    widget.selected == group
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(group),
                  onTap: () => Navigator.pop(context, group),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
