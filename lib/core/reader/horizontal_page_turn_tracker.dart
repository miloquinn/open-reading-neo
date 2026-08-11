class ReaderPagePosition {
  const ReaderPagePosition({
    required this.chapterIndex,
    required this.pageIndex,
  });

  final int chapterIndex;
  final int pageIndex;

  bool isAfter(ReaderPagePosition other) {
    return chapterIndex > other.chapterIndex ||
        (chapterIndex == other.chapterIndex && pageIndex > other.pageIndex);
  }

  @override
  bool operator ==(Object other) {
    return other is ReaderPagePosition &&
        chapterIndex == other.chapterIndex &&
        pageIndex == other.pageIndex;
  }

  @override
  int get hashCode => Object.hash(chapterIndex, pageIndex);
}

class PendingHorizontalPage<T> {
  const PendingHorizontalPage({
    required this.page,
    required this.position,
    required this.pagesReadDelta,
  });

  final T page;
  final ReaderPagePosition position;
  final int pagesReadDelta;
}

class HorizontalPageTurnTracker<T> {
  PendingHorizontalPage<T>? _pending;

  PendingHorizontalPage<T>? get pending => _pending;

  bool get hasPending => _pending != null;

  PendingHorizontalPage<T> record({
    required T page,
    required ReaderPagePosition position,
    required ReaderPagePosition committedPosition,
  }) {
    final referencePosition = _pending?.position ?? committedPosition;
    _pending = PendingHorizontalPage<T>(
      page: page,
      position: position,
      pagesReadDelta:
          (_pending?.pagesReadDelta ?? 0) +
          (position.isAfter(referencePosition) ? 1 : 0),
    );
    return _pending!;
  }

  PendingHorizontalPage<T>? take() {
    final pending = _pending;
    _pending = null;
    return pending;
  }

  void clear() {
    _pending = null;
  }
}
