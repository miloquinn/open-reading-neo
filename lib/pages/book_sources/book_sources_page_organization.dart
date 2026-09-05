part of 'book_sources_page.dart';

extension _BookSourcesPageOrganization on _BookSourcesPageState {
  RegisteredBookSource _currentSource(RegisteredBookSource source) =>
      _state.sources.where((s) => s.id == source.id).firstOrNull ?? source;

  Widget _sourceActions(RegisteredBookSource source) =>
      BookSourceOrganizationActions(
        key: ValueKey('discoverOrganization-${source.id}'),
        source: _currentSource(source),
        registry: _registry,
        onShowDetails: () => unawaited(_showSourceActions(source)),
      );

  Future<void> _showSourceActions(RegisteredBookSource source) =>
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final current = _currentSource(source);
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            current.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        BookSourceOrganizationActions(
                          source: current,
                          registry: _registry,
                        ),
                      ],
                    ),
                    Text(
                      current.websiteUrl?.host ?? current.apiBaseUrl.host,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (current.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(current.description),
                    ],
                    if (current.groups.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final group in current.groups)
                            Chip(
                              avatar: const Icon(
                                Icons.folder_outlined,
                                size: 16,
                              ),
                              label: Text(group),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      );

  Future<void> _chooseOrganizationGroup() async {
    final selected = await showBookSourceOrganizationGroupPicker(
      context,
      registry: _registry,
      selected: _state.selectedGroup,
    );
    if (!mounted || selected == null) return;
    _pendingScrollOffset = 0;
    await _controller.changeOrganizationScope(group: selected);
  }

  Widget _organizationFilters() {
    final copy = BookSourceOrganizationCopy.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Row(
          children: [
            Expanded(
              child: BookSourcePill(
                key: const Key('bookSourceOrganizationAll'),
                label: copy.all,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                selected: !_state.hasOrganizationFilter,
                onPressed: () {
                  _pendingScrollOffset = 0;
                  unawaited(_controller.changeOrganizationScope());
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: BookSourcePill(
                key: const Key('bookSourceOrganizationFavorites'),
                label: copy.favorites,
                icon: Icons.star_rounded,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                selected: _state.favoritesOnly,
                onPressed: () {
                  _pendingScrollOffset = 0;
                  unawaited(
                    _controller.changeOrganizationScope(favoritesOnly: true),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: BookSourcePill(
                key: const Key('bookSourceOrganizationGroups'),
                label: _state.selectedGroup ?? copy.groups,
                icon: Icons.folder_outlined,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                selected: _state.selectedGroup != null,
                onPressed: _chooseOrganizationGroup,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
