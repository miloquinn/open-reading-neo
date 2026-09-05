import 'package:flutter/material.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';

class BookSourceCategoryPicker extends StatefulWidget {
  final List<SourcedBookCategory> categories;
  final SourcedBookCategory? selectedCategory;
  final String title;
  final String searchLabel;
  final String noResultsLabel;

  const BookSourceCategoryPicker({
    super.key,
    required this.categories,
    required this.selectedCategory,
    required this.title,
    required this.searchLabel,
    required this.noResultsLabel,
  });

  @override
  State<BookSourceCategoryPicker> createState() =>
      _BookSourceCategoryPickerState();
}

class _BookSourceCategoryPickerState extends State<BookSourceCategoryPicker> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<_PickerEntry> _entries() {
    final query = _query.trim().toLowerCase();
    final entries = <_PickerEntry>[];
    String? sourceId;
    for (final category in widget.categories) {
      if (query.isNotEmpty &&
          !category.name.toLowerCase().contains(query) &&
          !category.source.name.toLowerCase().contains(query)) {
        continue;
      }
      if (category.source.id != sourceId) {
        sourceId = category.source.id;
        entries.add(_PickerEntry.header(category.source.name));
      }
      entries.add(_PickerEntry.category(category));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              key: const Key('bookSourceCategorySearchField'),
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: widget.searchLabel,
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.clear_rounded),
                      ),
                filled: true,
                fillColor: scheme.surfaceContainerLow,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: scheme.primary, width: 1.5),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      widget.noResultsLabel,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    key: const Key('bookSourceCategoryLazyList'),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final category = entry.category;
                      if (category == null) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                          child: Text(
                            entry.header!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        );
                      }
                      final selected = category == widget.selectedCategory;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 3,
                        ),
                        child: AnimatedContainer(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          decoration: ShapeDecoration(
                            color: selected
                                ? scheme.primaryContainer
                                : Colors.transparent,
                            shape: const StadiumBorder(),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            shape: const StadiumBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: ListTile(
                              key: Key(
                                'bookSourceCategory-${category.source.id}-${category.id}',
                              ),
                              selected: selected,
                              selectedColor: scheme.onPrimaryContainer,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 2,
                              ),
                              minTileHeight: 48,
                              shape: const StadiumBorder(),
                              title: Text(
                                category.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: selected
                                  ? Icon(
                                      Icons.check_rounded,
                                      color: scheme.onPrimaryContainer,
                                    )
                                  : null,
                              onTap: () => Navigator.of(context).pop(category),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _PickerEntry {
  final String? header;
  final SourcedBookCategory? category;

  const _PickerEntry.header(this.header) : category = null;

  const _PickerEntry.category(this.category) : header = null;
}
