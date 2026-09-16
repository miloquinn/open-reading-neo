import 'package:flutter/widgets.dart';

class BackupCopy {
  BackupCopy(this.zh);
  factory BackupCopy.of(BuildContext context) =>
      BackupCopy(Localizations.localeOf(context).languageCode == 'zh');
  final bool zh;
  String get waitForTasks => zh
      ? '请等待书籍下载或书源整理完成，再备份或恢复。'
      : 'Wait for downloads or source maintenance to finish before backing up or restoring.';
  String get title => zh ? 'WebDAV 备份' : 'WebDAV backups';
  String get summary => zh ? '一键备份，按时间恢复' : 'Back up now, restore a snapshot';
  String get description => zh
      ? '每次备份生成一份独立 ZIP，旧备份会保留。可选择数据类别和书籍正文，正文默认不备份。'
      : 'Each backup is a separate ZIP. Choose data categories and book files; book files are excluded by default. Earlier backups are kept.';
  String get privacy => zh
      ? '备份未加密，包含书源配置；请使用你信任的 WebDAV。账号登录和 WebDAV 密码不在备份中。'
      : 'Backups are not encrypted and include source configurations. Use a trusted WebDAV server. Account sessions and WebDAV passwords are excluded.';
  String get backup => zh ? '立即备份' : 'Back up now';
  String get restore => zh ? '恢复' : 'Restore';
  String get history => zh ? '备份记录' : 'Backup history';
  String get empty => zh
      ? '还没有备份，点击“立即备份”创建第一份。'
      : 'No backups yet. Choose Back up now to create one.';
  String get refresh => zh ? '刷新备份列表' : 'Refresh backups';
  String get configure => zh ? '连接设置' : 'Connection settings';
  String get working => zh ? '正在处理，请勿关闭应用…' : 'Working. Keep the app open…';
  String get done => zh ? '备份已上传' : 'Backup uploaded';
  String get restored => zh ? '恢复完成' : 'Restore complete';
  String get restart => zh ? '重新载入应用' : 'Reload app';
  String get restartHint => zh
      ? '重新载入后使用恢复的数据。恢复前的数据已保存为本地 ZIP（不含正文，原正文文件仍保留）。'
      : 'Reload to use the restored data. A local ZIP of the previous data was saved without book files. Original files remain on disk.';
  String get confirm => zh
      ? '恢复会覆盖备份中包含的数据类别及同一本书的进度和笔记，未备份的类别和现有正文会保留。旧版完整备份会替换整个书架。恢复前会保存一份不含正文的本地数据备份。确定恢复？'
      : 'Included categories and matching book data will be restored. Omitted categories and existing book files are kept. Legacy full backups replace the library. A local data backup without book files is saved first. Restore?';
  String get cancel => zh ? '取消' : 'Cancel';
  String get failed => zh
      ? '操作失败，请检查连接、存储空间或备份文件后重试。'
      : 'Operation failed. Check your connection, storage space or backup file and retry.';
  String stage(String value) => switch (value) {
    'packing' => zh ? '正在快速打包' : 'Packing',
    'verifying' => zh ? '正在校验备份' : 'Verifying backup',
    'uploading' => zh ? '正在上传' : 'Uploading',
    'downloading' => zh ? '正在下载' : 'Downloading',
    'safety' => zh ? '正在保存恢复前的数据' : 'Saving previous data',
    'restoring' => zh ? '正在恢复' : 'Restoring',
    'finishing' => zh ? '正在确认上传完成' : 'Finalizing upload',
    _ => zh ? '正在准备' : 'Preparing',
  };
  String get disconnect => zh ? '断开连接' : 'Disconnect';
}
