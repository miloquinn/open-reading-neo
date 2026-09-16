class BackupSelection {
  const BackupSelection({
    this.reading = true,
    this.statistics = true,
    this.sources = true,
    this.settings = true,
    this.bookIds = const {},
  });
  final bool reading, statistics, sources, settings;
  final Set<int> bookIds;
  bool get isEmpty =>
      !reading && !statistics && !sources && !settings && bookIds.isEmpty;
  Map<String, Object> toJson() => {
    'reading': reading || bookIds.isNotEmpty,
    'statistics': statistics,
    'sources': sources,
    'settings': settings,
  };
}

class BackupBook {
  const BackupBook(this.id, this.title, this.bytes, this.available);
  final int id;
  final String title;
  final int bytes;
  final bool available;
}

String backupBytes(num bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${bytes.round()} B';
}

class RestoreSelection {
  const RestoreSelection({
    this.reading = true,
    this.files = true,
    this.statistics = true,
    this.sources = true,
    this.settings = true,
    this.overwrite = false,
  });
  final bool reading, files, statistics, sources, settings, overwrite;
  bool get isEmpty => !reading && !statistics && !sources && !settings;
}
