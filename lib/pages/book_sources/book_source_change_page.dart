import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_change_service.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';

import 'widgets/sourced_book_cards.dart';

class BookSourceChangePage extends StatefulWidget {
  const BookSourceChangePage({
    super.key,
    required this.currentSource,
    required this.currentBook,
    this.sources,
    this.sourcesFuture,
    this.shelfBook,
    this.service,
    this.serviceFactory,
  }) : assert(service == null || serviceFactory == null),
       assert(sources != null || sourcesFuture != null);

  final List<RegisteredBookSource>? sources;
  final Future<List<RegisteredBookSource>>? sourcesFuture;
  final RegisteredBookSource currentSource;
  final BookSourceBook currentBook;
  final Book? shelfBook;
  final BookSourceChangeService? service;
  final BookSourceChangeService Function()? serviceFactory;

  @override
  State<BookSourceChangePage> createState() => _BookSourceChangePageState();
}

class _BookSourceChangePageState extends State<BookSourceChangePage> {
  static const int _quickSourceLimit = 60;
  static const int _quickCandidateLimit = 8;

  late final bool _ownsService = widget.service == null;
  late final BookSourceChangeService _service =
      widget.service ??
      (widget.serviceFactory ?? BookSourceChangeService.new)();
  late final TextEditingController _queryController = TextEditingController(
    text: widget.currentBook.title,
  );
  late final Future<BookSourceChangePosition> _positionFuture;
  StreamSubscription<BookSourceChangeSearchEvent>? _searchSubscription;
  Timer? _resultFlushTimer;

  BookSourceChangePosition? _position;
  List<RegisteredBookSource> _sources = const [];
  List<BookSourceChangeCandidate> _candidates = <BookSourceChangeCandidate>[];
  final List<BookSourceChangeCandidate> _pendingCandidates = [];
  final Set<String> _candidateKeys = {};
  final Map<String, int> _candidateArrivalOrder = {};
  int _nextCandidateArrivalOrder = 0;
  final Set<String> _searchedSourceIds = {};
  BookSourceChangeCandidate? _selected;
  ValidatedBookSourceChange? _validated;
  Object? _validationError;
  int _generation = 0;
  int _completed = 0;
  int _failed = 0;
  int _total = 0;
  int _pendingCompleted = 0;
  int _pendingFailed = 0;
  bool _checkAuthor = true;
  bool _preparing = true;
  bool _searching = false;
  bool _hasMoreSources = false;
  bool _validating = false;
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    _positionFuture = _loadPosition();
    unawaited(_positionFuture.then<void>((_) {}, onError: (_, _) {}));
    unawaited(_loadSourcesAndSearch());
  }

  @override
  void dispose() {
    final searchSubscription = _searchSubscription;
    _searchSubscription = null;
    _generation++;
    _resultFlushTimer?.cancel();
    _queryController.dispose();
    unawaited(_closeOwnedService(searchSubscription));
    super.dispose();
  }

  Future<void> _closeOwnedService(
    StreamSubscription<BookSourceChangeSearchEvent>? searchSubscription,
  ) async {
    await searchSubscription?.cancel();
    if (_ownsService) _service.close();
  }

  Future<BookSourceChangePosition> _loadPosition() async {
    final position = await _service.loadPosition(
      source: widget.currentSource,
      book: widget.currentBook,
      shelfBook: widget.shelfBook,
    );
    if (mounted) setState(() => _position = position);
    return position;
  }

  Future<void> _loadSourcesAndSearch() async {
    final sources =
        await (widget.sourcesFuture ??
            Future<List<RegisteredBookSource>>.value(widget.sources!));
    if (!mounted) return;
    final total = _searchTargetCount(sources);
    setState(() {
      _sources = sources;
      _preparing = false;
      _total = total;
      _searching = total > 0;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _startSearch();
  }

  Future<void> _startSearch({bool continueSearch = false}) async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _preparing) return;
    final generation = ++_generation;
    final previousSearch = _searchSubscription;
    _searchSubscription = null;
    if (previousSearch != null) unawaited(previousSearch.cancel());
    _resultFlushTimer?.cancel();
    _resultFlushTimer = null;
    _pendingCandidates.clear();
    if (!continueSearch) {
      _candidateKeys.clear();
      _candidateArrivalOrder.clear();
      _nextCandidateArrivalOrder = 0;
      _searchedSourceIds.clear();
    }
    _pendingCompleted = _searchedSourceIds.length;
    _pendingFailed = 0;
    final targetCount = _searchTargetCount(_sources);
    setState(() {
      if (!continueSearch) {
        _candidates = <BookSourceChangeCandidate>[];
        _selected = null;
        _validated = null;
        _validationError = null;
        _validating = false;
        _completed = 0;
        _failed = 0;
      }
      _total = targetCount;
      _searching = targetCount > _searchedSourceIds.length;
      _hasMoreSources = false;
    });
    final completedOffset = _searchedSourceIds.length;
    _searchSubscription = _service
        .search(
          sources: _sources,
          title: query,
          author: widget.currentBook.author,
          checkAuthor: _checkAuthor,
          currentSourceId: widget.currentSource.id,
          excludedSourceIds: _searchedSourceIds,
          sourceLimit: continueSearch ? null : _quickSourceLimit,
          candidateLimit: continueSearch ? null : _quickCandidateLimit,
        )
        .listen((event) {
          if (!mounted || generation != _generation) return;
          _searchedSourceIds.add(event.source.id);
          for (final item in event.candidates) {
            final key = '${item.source.id}\u0000${item.book.id}';
            if (!_candidateKeys.add(key)) continue;
            _candidateArrivalOrder[key] = _nextCandidateArrivalOrder++;
            _pendingCandidates.add(item);
          }
          _pendingCompleted = completedOffset + event.completed;
          if (event.error != null) _pendingFailed++;
          _scheduleResultFlush(generation);
        }, onDone: () => _flushSearchResults(generation, done: true));
  }

  void _scheduleResultFlush(int generation) {
    if (_resultFlushTimer?.isActive ?? false) return;
    _resultFlushTimer = Timer(
      const Duration(milliseconds: 120),
      () => _flushSearchResults(generation),
    );
  }

  void _flushSearchResults(int generation, {bool done = false}) {
    _resultFlushTimer?.cancel();
    _resultFlushTimer = null;
    if (!mounted || generation != _generation) return;
    final added = List<BookSourceChangeCandidate>.of(_pendingCandidates);
    final completed = _pendingCompleted;
    final failed = _pendingFailed;
    _pendingCandidates.clear();
    _pendingFailed = 0;
    setState(() {
      _candidates.addAll(added);
      // Candidates whose author matches the current book move to the front,
      // even if they arrived later; ties keep arrival order.
      _candidates.sort(_compareCandidateRelevance);
      _completed = completed;
      _failed += failed;
      if (done) {
        _searching = false;
        _hasMoreSources = _searchedSourceIds.length < _total;
      }
    });
  }

  int _compareCandidateRelevance(
    BookSourceChangeCandidate a,
    BookSourceChangeCandidate b,
  ) {
    final authorRank = (b.authorMatches ? 1 : 0).compareTo(
      a.authorMatches ? 1 : 0,
    );
    if (authorRank != 0) return authorRank;
    final orderA =
        _candidateArrivalOrder['${a.source.id}\u0000${a.book.id}'] ?? 0;
    final orderB =
        _candidateArrivalOrder['${b.source.id}\u0000${b.book.id}'] ?? 0;
    return orderA.compareTo(orderB);
  }

  Future<void> _selectCandidate(BookSourceChangeCandidate candidate) async {
    if (_validating || _committing) return;
    setState(() {
      _selected = candidate;
      _validated = null;
      _validationError = null;
      _validating = true;
    });
    try {
      final position = _position ?? await _positionFuture;
      if (!mounted || _selected != candidate) return;
      final validated = await _service.validate(
        candidate: candidate,
        position: position,
      );
      if (!mounted || _selected != candidate) return;
      setState(() => _validated = validated);
    } catch (error) {
      if (!mounted || _selected != candidate) return;
      setState(() => _validationError = error);
    } finally {
      if (mounted && _selected == candidate) {
        setState(() => _validating = false);
      }
    }
  }

  Future<void> _commit() async {
    final validated = _validated;
    if (validated == null || _committing) return;
    setState(() => _committing = true);
    try {
      final result = await _service.commit(
        validated: validated,
        shelfBook: widget.shelfBook,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _committing = false;
        _validationError = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FloatingSubpageScaffold(
      title: context.l10n.bookSourceChangeSourceTitle,
      body: Padding(
        padding: EdgeInsets.only(
          top: FloatingSubpageScaffold.headerExtentOf(context),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: _buildMigrationHeader(context),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: _buildSearchControls(context),
                ),
                Expanded(child: _buildBody(context)),
                _buildBottomAction(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMigrationHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedName = _selected?.source.name;
    return Container(
      key: const Key('bookSourceChangeHeader'),
      padding: const EdgeInsets.all(16),
      decoration: bookSourcePanelDecoration(
        context,
        radius: 20,
        stronger: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.currentBook.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SourceRailStop(
                  label: context.l10n.bookSourceChangeCurrentSource,
                  value: widget.currentSource.name,
                  active: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.arrow_forward_rounded, color: scheme.primary),
              ),
              Expanded(
                child: _SourceRailStop(
                  label: context.l10n.bookSourceChangeTargetSource,
                  value:
                      selectedName ?? context.l10n.bookSourceChangeNotSelected,
                  active: selectedName != null,
                ),
              ),
            ],
          ),
          if (_position != null && _position!.chapterCount > 0) ...[
            const SizedBox(height: 12),
            Text(
              context.l10n.bookSourceChangeCurrentChapter(
                _position!.chapterIndex + 1,
              ),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchControls(BuildContext context) {
    return Column(
      children: [
        TextField(
          key: const Key('bookSourceChangeQuery'),
          controller: _queryController,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _startSearch(),
          decoration: InputDecoration(
            labelText: context.l10n.bookSourceChangeSearchLabel,
            prefixIcon: const Icon(Icons.manage_search_rounded),
            suffixIcon: IconButton(
              tooltip: context.l10n.bookSourceChangeSearchAgain,
              onPressed: _preparing ? null : _startSearch,
              icon: const Icon(Icons.refresh_rounded),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChip(
              key: const Key('bookSourceChangeAuthorFilter'),
              selected: _checkAuthor,
              avatar: const Icon(Icons.person_search_outlined, size: 18),
              label: Text(context.l10n.bookSourceChangeCheckAuthor),
              onSelected: (selected) {
                setState(() => _checkAuthor = selected);
                unawaited(_startSearch());
              },
            ),
            if (_searching || _completed > 0)
              Text(
                context.l10n.bookSourceChangeSearchProgress(_completed, _total),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            if (_hasMoreSources && !_searching)
              TextButton.icon(
                key: const Key('bookSourceChangeSearchRemaining'),
                onPressed: () => _startSearch(continueSearch: true),
                icon: const Icon(Icons.travel_explore_rounded, size: 18),
                label: Text(context.l10n.bookSourceChangeSearchRemaining),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_preparing) {
      return _EmptyChangeState(
        icon: Icons.radar_rounded,
        title: context.l10n.bookSourceChangeSearching,
        message: context.l10n.bookSourceChangeSearchingHint,
        loading: true,
      );
    }
    if (_total == 0) {
      return _EmptyChangeState(
        icon: Icons.travel_explore_outlined,
        title: context.l10n.bookSourceChangeNoOtherSources,
        message: context.l10n.bookSourceChangeNoOtherSourcesHint,
      );
    }
    if (_candidates.isEmpty && _searching) {
      return _EmptyChangeState(
        icon: Icons.radar_rounded,
        title: context.l10n.bookSourceChangeSearching,
        message: context.l10n.bookSourceChangeSearchingHint,
        loading: true,
      );
    }
    if (_candidates.isEmpty) {
      return _EmptyChangeState(
        icon: Icons.search_off_rounded,
        title: context.l10n.bookSourceChangeNoMatches,
        message: _failed > 0
            ? context.l10n.bookSourceChangeFailedSources(_failed)
            : context.l10n.bookSourceChangeNoMatchesHint,
      );
    }
    return ListView.separated(
      key: const Key('bookSourceChangeCandidates'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: _candidates.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final candidate = _candidates[index];
        return _buildCandidate(context, candidate);
      },
    );
  }

  int _searchTargetCount(Iterable<RegisteredBookSource> sources) => sources
      .where(
        (source) =>
            source.enabled &&
            source.id != widget.currentSource.id &&
            source.capabilities.contains('search'),
      )
      .length;

  Widget _buildCandidate(
    BuildContext context,
    BookSourceChangeCandidate candidate,
  ) {
    final selected = identical(_selected, candidate);
    final validated = selected ? _validated : null;
    final scheme = Theme.of(context).colorScheme;
    final subtitleParts = <String>[
      if (candidate.book.author.isNotEmpty) candidate.book.author,
      if (candidate.book.latestChapter?.isNotEmpty ?? false)
        candidate.book.latestChapter!,
    ];
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('bookSourceChangeCandidate-${candidate.source.id}'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => _selectCandidate(candidate),
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: bookSourcePanelDecoration(context, radius: 18).copyWith(
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.outline.withValues(alpha: 0.16),
              width: selected ? 1.6 : 0.8,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  validated != null
                      ? Icons.verified_rounded
                      : Icons.public_rounded,
                  color: validated != null
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            candidate.source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (!candidate.authorMatches)
                          _StatusPill(
                            label: context.l10n.bookSourceChangeAuthorDifferent,
                            color: scheme.tertiary,
                          ),
                      ],
                    ),
                    if (subtitleParts.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitleParts.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    if (selected) ...[
                      const SizedBox(height: 9),
                      _buildCandidateStatus(context, validated),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCandidateStatus(
    BuildContext context,
    ValidatedBookSourceChange? validated,
  ) {
    final scheme = Theme.of(context).colorScheme;
    if (_validating) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(context.l10n.bookSourceChangeValidating)),
        ],
      );
    }
    if (_validationError != null) {
      return Text(
        _validationError is BookSourceChangeConflict
            ? context.l10n.bookSourceChangeAlreadyOnShelf
            : context.l10n.bookSourceChangeValidationFailed(
                '$_validationError',
              ),
        style: TextStyle(color: scheme.error, fontSize: 12),
      );
    }
    if (validated != null) {
      return Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          _StatusPill(
            label: context.l10n.bookSourceChangeReadable,
            color: scheme.primary,
          ),
          _StatusPill(
            label: context.l10n.bookSourceChangeChapterCount(
              validated.chapters.length,
            ),
            color: scheme.secondary,
          ),
          _StatusPill(
            label: context.l10n.bookSourceChangeResponseTime(
              validated.responseTime.inMilliseconds,
            ),
            color: scheme.tertiary,
          ),
        ],
      );
    }
    return Text(context.l10n.bookSourceChangeTapToValidate);
  }

  Widget _buildBottomAction(BuildContext context) {
    if (_candidates.isEmpty && !_committing) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
        border: Border(
          top: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outline.withValues(alpha: 0.14),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: FilledButton.icon(
          key: const Key('bookSourceChangeCommit'),
          onPressed: _validated == null || _committing ? null : _commit,
          icon: _committing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.swap_horiz_rounded),
          label: Text(
            _committing
                ? context.l10n.bookSourceChangeSwitching
                : context.l10n.bookSourceChangeSwitchAction,
          ),
        ),
      ),
    );
  }
}

class _SourceRailStop extends StatelessWidget {
  const _SourceRailStop({
    required this.label,
    required this.value,
    required this.active,
  });

  final String label;
  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyChangeState extends StatelessWidget {
  const _EmptyChangeState({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
