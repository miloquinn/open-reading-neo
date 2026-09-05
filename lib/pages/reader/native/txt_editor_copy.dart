import 'package:flutter/widgets.dart';

class TxtEditorCopy {
  const TxtEditorCopy._(this._language);

  factory TxtEditorCopy.of(BuildContext context) => TxtEditorCopy._(
    Localizations.maybeLocaleOf(context)?.languageCode ?? 'en',
  );

  final String _language;

  bool get _zh => _language == 'zh';
  bool get _ja => _language == 'ja';

  String get editChapter => _zh ? '编辑本章' : (_ja ? 'この章を編集' : 'Edit chapter');
  String get versionHistory =>
      _zh ? '版本历史' : (_ja ? 'バージョン履歴' : 'Version history');
  String get cancel => _zh ? '取消' : (_ja ? 'キャンセル' : 'Cancel');
  String get save => _zh ? '保存' : (_ja ? '保存' : 'Save');
  String get discardChanges =>
      _zh ? '放弃未保存的修改？' : (_ja ? '未保存の変更を破棄しますか？' : 'Discard unsaved changes?');
  String get keepEditing => _zh ? '继续编辑' : (_ja ? '編集を続ける' : 'Keep editing');
  String get discard => _zh ? '放弃修改' : (_ja ? '変更を破棄' : 'Discard changes');
  String get restore =>
      _zh ? '恢复此版本' : (_ja ? 'この版を復元' : 'Restore this version');
  String get noVersions =>
      _zh ? '还没有可恢复的版本' : (_ja ? '復元できる版はありません' : 'No versions to restore yet');
  String get conversionTitle => _zh
      ? '转换为 UTF-8 后编辑？'
      : (_ja ? 'UTF-8 に変換して編集しますか？' : 'Convert to UTF-8 to edit?');
  String get conversionBody => _zh
      ? '这本书不是 UTF-8。保存时会转换编码，并在版本历史中保留原始字节副本。'
      : (_ja
            ? 'この本は UTF-8 ではありません。保存時に変換し、元のバイト列を履歴に保存します。'
            : 'This book is not UTF-8. Saving will convert it and preserve the original bytes in version history.');
  String get convertAndSave =>
      _zh ? '转换并保存' : (_ja ? '変換して保存' : 'Convert and save');
  String get structureChanged => _zh
      ? '本次修改会改变章节标题或目录结构。第一版暂时只支持修改正文。'
      : (_ja
            ? 'この変更は章構造を変えます。現在は本文だけ編集できます。'
            : 'This change would alter chapter structure. This version edits body text only.');
  String get sourceChanged => _zh
      ? '文件已在别处改变，请重新打开编辑器。'
      : (_ja
            ? 'ファイルが変更されました。編集画面を開き直してください。'
            : 'The file changed elsewhere. Reopen the editor.');
  String get saveFailed => _zh
      ? '保存失败，原文件已保留。'
      : (_ja
            ? '保存できませんでした。元のファイルは保持されています。'
            : 'Save failed. The original file was preserved.');
  String get sectionTooLarge => _zh
      ? '单次编辑的内容过长，请分段修改；整本书的大小不受此限制。'
      : (_ja
            ? '一度に編集する内容が長すぎます。分けて編集してください。本全体のサイズ制限ではありません。'
            : 'This edit is too large. Make it in smaller sections; this is not a whole-book size limit.');
  String get saved => _zh ? '正文已保存' : (_ja ? '本文を保存しました' : 'Text saved');
  String get locationUnavailable =>
      _zh ? '原位置已失效' : (_ja ? '元の位置は無効です' : 'Original location unavailable');
  String get restoreConfirm => _zh
      ? '恢复后会生成一个新的版本，当前内容仍可从历史中找回。'
      : (_ja
            ? '復元は新しい版として保存され、現在の内容も履歴に残ります。'
            : 'Restoring creates a new version; the current content remains in history.');
  String get remoteProgressVersionMismatch => _zh
      ? '另一台设备的阅读位置属于不同正文版本，请先完成正文同步。'
      : (_ja
            ? '別の端末の読書位置は異なる本文版です。先に本文を同期してください。'
            : 'That reading position belongs to a different text revision. Sync the text first.');
  String get remoteProgressAvailable => _zh
      ? '另一台设备有新的阅读位置'
      : (_ja
            ? '別の端末に新しい読書位置があります'
            : 'Another device has a newer reading position');
  String get remoteProgressApplied => _zh
      ? '已接续另一台设备的阅读位置'
      : (_ja ? '別の端末の読書位置から再開しました' : 'Continued from another device');
  String get later => _zh ? '稍后' : (_ja ? '後で' : 'Later');
  String get continueReading => _zh ? '接着读' : (_ja ? '続きを読む' : 'Continue');
  String get returnToLocalPosition =>
      _zh ? '返回原位置' : (_ja ? '元の位置に戻る' : 'Return to original position');
  String get remoteProgressChoiceTitle => _zh
      ? '发现另一台设备的阅读位置'
      : (_ja ? '別の端末の読書位置' : 'Reading position from another device');
  String remoteProgressChoiceBody(String position) => _zh
      ? '云端位置：$position。要从这里继续吗？'
      : (_ja
            ? 'クラウドの位置：$position。ここから再開しますか？'
            : 'Cloud position: $position. Continue from there?');
  String get keepLocalProgress =>
      _zh ? '保留本机位置' : (_ja ? 'この端末の位置を使う' : 'Keep local position');
  String get useRemoteProgress =>
      _zh ? '使用云端位置' : (_ja ? 'クラウドの位置を使う' : 'Use cloud position');
  String chapterProgress(String chapter, int percent) => _zh
      ? '$chapter，$percent%'
      : (_ja ? '$chapter、$percent%' : '$chapter, $percent%');
  String pageProgress(int page) =>
      _zh ? '第 ${page + 1} 页' : (_ja ? '${page + 1} ページ' : 'Page ${page + 1}');
}
