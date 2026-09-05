part of 'book_source_reader_page.dart';

extension _BookSourcePersistentPagination on _BookSourceReaderPageState {
  String _onlinePaginationIdentity(int index) =>
      'online:${sha256.convert(utf8.encode(jsonEncode([widget.source.id, widget.source.apiBaseUrl.toString(), widget.source.sourceProtocol.name, widget.source.protocolVersion, widget.source.sourceConfig, widget.book.id, _chapters[index].id])))}';

  void _checkOnlinePaginationEpoch() {
    if (_paginationCacheEpoch == PaginationCacheDao.epoch) return;
    _paginationCacheEpoch = PaginationCacheDao.epoch;
    _persistedOnlinePagination.clear();
    _pagedLayouts.clear();
    _verticalLayouts.clear();
    _paginationKey = null;
  }

  Future<void> _loadOnlinePagination(int index) async {
    _checkOnlinePaginationEpoch();
    // Continuous text does not measure page boundaries or persist layouts.
    if (_pageMode == BookSourcePageMode.verticalScroll) return;
    final generation = PaginationCacheDao.epoch;
    final text = _readableChapterText[index];
    if (text == null) return;
    final revision = sha256.convert(utf8.encode(text)).toString();
    final revisionToken = PaginationCacheDao.revisionEpochFor(
      _onlinePaginationIdentity(index),
      revision,
    );
    Map<String, Uint8List> layouts = {};
    try {
      layouts = await _paginationCacheDao.loadForIdentity(
        _onlinePaginationIdentity(index),
        revision,
      );
    } catch (error) {
      debugPrint('load online pagination cache failed: $error');
    }
    if (!mounted ||
        generation != PaginationCacheDao.epoch ||
        _readableChapterText[index] != text) {
      return;
    }
    _persistedOnlinePagination[index] = (
      revision: revision,
      revisionEpoch: revisionToken,
      text: text,
      layouts: Map.of(layouts),
    );
    while (_persistedOnlinePagination.length >
        _bookSourceReadableChapterTextLimit) {
      _persistedOnlinePagination.remove(_persistedOnlinePagination.keys.first);
    }
  }

  void _persistOnlinePagination(
    int index,
    String revision,
    String fingerprint,
    List<ReaderTextPage> pages,
  ) {
    final generation = PaginationCacheDao.epoch;
    final payload = ReaderPaginationCacheCodec.encodeTextPages(pages);
    final cached = _persistedOnlinePagination[index];
    if (cached?.revision == revision) {
      cached!.layouts[fingerprint] = payload;
      while (cached.layouts.length > PaginationCacheDao.maxLayoutsPerBook) {
        cached.layouts.remove(cached.layouts.keys.first);
      }
    }
    unawaited(
      _paginationCacheDao
          .upsertForIdentity(
            identity: _onlinePaginationIdentity(index),
            bookRevision: revision,
            layoutFingerprint: fingerprint,
            chapterIndex: index,
            payload: payload,
            expectedEpoch: generation,
            expectedRevisionEpoch: cached?.revision == revision
                ? cached?.revisionEpoch
                : null,
          )
          .catchError((Object error) {
            debugPrint('save online pagination cache failed: $error');
          }),
    );
  }
}
