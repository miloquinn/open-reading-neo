import 'package:xxread/services/export/reading_data_export_models.dart';

ReadingDataExportBackend createDefaultReadingDataExportBackend({
  ReadingDataOverwriteConfirmation? overwriteConfirmation,
}) => const UnsupportedReadingDataExportBackend();

class UnsupportedReadingDataExportBackend implements ReadingDataExportBackend {
  const UnsupportedReadingDataExportBackend();

  @override
  Future<ReadingDataExportBackendResult> export(
    ReadingDataExportRequest request,
  ) async => const ReadingDataExportBackendResult.unsupported();
}
