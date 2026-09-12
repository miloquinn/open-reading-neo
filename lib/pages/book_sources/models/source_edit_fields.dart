import 'package:flutter/widgets.dart';

class SourceEditField {
  const SourceEditField(this.key, {this.group, this.multiline = true});

  final String key;
  final String? group;
  final bool multiline;

  String get id => group == null ? key : '$group.$key';

  String label(BuildContext context) => SourceEditCopy.of(context).field(id);
}

class SourceEditSection {
  const SourceEditSection(this.key, this.fields);

  final String key;
  final List<SourceEditField> fields;

  String label(BuildContext context) => SourceEditCopy.of(context).section(key);
}

const sourceEditSections = <SourceEditSection>[
  SourceEditSection('basic', [
    SourceEditField('bookSourceUrl', multiline: false),
    SourceEditField('bookSourceName', multiline: false),
    SourceEditField('bookSourceGroup', multiline: false),
    SourceEditField('bookSourceComment'),
    SourceEditField('loginUrl'),
    SourceEditField('loginUi'),
    SourceEditField('loginCheckJs'),
    SourceEditField('header'),
    SourceEditField('jsLib'),
    SourceEditField('concurrentRate', multiline: false),
  ]),
  SourceEditSection('search', [
    SourceEditField('searchUrl'),
    SourceEditField('checkKeyWord', group: 'ruleSearch'),
    SourceEditField('bookList', group: 'ruleSearch'),
    SourceEditField('name', group: 'ruleSearch'),
    SourceEditField('author', group: 'ruleSearch'),
    SourceEditField('kind', group: 'ruleSearch'),
    SourceEditField('wordCount', group: 'ruleSearch'),
    SourceEditField('lastChapter', group: 'ruleSearch'),
    SourceEditField('intro', group: 'ruleSearch'),
    SourceEditField('coverUrl', group: 'ruleSearch'),
    SourceEditField('bookUrl', group: 'ruleSearch'),
  ]),
  SourceEditSection('exploreSection', [
    SourceEditField('exploreUrl'),
    SourceEditField('bookList', group: 'ruleExplore'),
    SourceEditField('name', group: 'ruleExplore'),
    SourceEditField('author', group: 'ruleExplore'),
    SourceEditField('kind', group: 'ruleExplore'),
    SourceEditField('wordCount', group: 'ruleExplore'),
    SourceEditField('lastChapter', group: 'ruleExplore'),
    SourceEditField('intro', group: 'ruleExplore'),
    SourceEditField('coverUrl', group: 'ruleExplore'),
    SourceEditField('bookUrl', group: 'ruleExplore'),
  ]),
  SourceEditSection('bookInfo', [
    SourceEditField('init', group: 'ruleBookInfo'),
    SourceEditField('name', group: 'ruleBookInfo'),
    SourceEditField('author', group: 'ruleBookInfo'),
    SourceEditField('kind', group: 'ruleBookInfo'),
    SourceEditField('wordCount', group: 'ruleBookInfo'),
    SourceEditField('lastChapter', group: 'ruleBookInfo'),
    SourceEditField('intro', group: 'ruleBookInfo'),
    SourceEditField('coverUrl', group: 'ruleBookInfo'),
    SourceEditField('tocUrl', group: 'ruleBookInfo'),
  ]),
  SourceEditSection('toc', [
    SourceEditField('preUpdateJs', group: 'ruleToc'),
    SourceEditField('chapterList', group: 'ruleToc'),
    SourceEditField('chapterName', group: 'ruleToc'),
    SourceEditField('chapterUrl', group: 'ruleToc'),
    SourceEditField('formatJs', group: 'ruleToc'),
    SourceEditField('isVolume', group: 'ruleToc'),
    SourceEditField('isVip', group: 'ruleToc'),
    SourceEditField('isPay', group: 'ruleToc'),
    SourceEditField('updateTime', group: 'ruleToc'),
    SourceEditField('nextTocUrl', group: 'ruleToc'),
  ]),
  SourceEditSection('contentSection', [
    SourceEditField('content', group: 'ruleContent'),
    SourceEditField('nextContentUrl', group: 'ruleContent'),
    SourceEditField('webJs', group: 'ruleContent'),
    SourceEditField('sourceRegex', group: 'ruleContent'),
    SourceEditField('replaceRegex', group: 'ruleContent'),
    SourceEditField('imageStyle', group: 'ruleContent'),
    SourceEditField('payAction', group: 'ruleContent'),
  ]),
];

class SourceEditCopy {
  const SourceEditCopy._(this._language);

  final String _language;

  static SourceEditCopy of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final language = locale.languageCode == 'zh'
        ? (locale.countryCode == 'TW' || locale.scriptCode == 'Hant'
              ? 'zh_TW'
              : 'zh')
        : locale.languageCode;
    return SourceEditCopy._(language);
  }

  String _pick({
    required String en,
    required String zh,
    required String zhTw,
    required String ja,
  }) => switch (_language) {
    'zh' => zh,
    'zh_TW' => zhTw,
    'ja' => ja,
    _ => en,
  };

  String get edit =>
      _pick(en: 'Edit source', zh: '编辑书源', zhTw: '編輯書源', ja: 'ソースを編集');
  String get save => _pick(en: 'Save', zh: '保存', zhTw: '儲存', ja: '保存');
  String get saved =>
      _pick(en: 'Source saved', zh: '书源已保存', zhTw: '書源已儲存', ja: 'ソースを保存しました');
  String get saveFailed => _pick(
    en: 'Could not save the source. Try again.',
    zh: '保存书源失败，请重试。',
    zhTw: '儲存書源失敗，請重試。',
    ja: 'ソースを保存できませんでした。もう一度お試しください。',
  );
  String get duplicateUrl => _pick(
    en: 'Another installed source uses this URL. Enter a different URL.',
    zh: '已有书源使用这个 URL，请修改后再保存。',
    zhTw: '已有書源使用這個 URL，請修改後再儲存。',
    ja: 'この URL のソースは既にあります。別の URL を入力してください。',
  );
  String get discardTitle => _pick(
    en: 'Discard changes?',
    zh: '放弃更改？',
    zhTw: '放棄變更？',
    ja: '変更を破棄しますか？',
  );
  String get discardMessage => _pick(
    en: 'Your changes have not been saved.',
    zh: '你的更改尚未保存。',
    zhTw: '你的變更尚未儲存。',
    ja: '変更はまだ保存されていません。',
  );
  String get discard => _pick(en: 'Discard', zh: '放弃', zhTw: '放棄', ja: '破棄');
  String get keepEditing =>
      _pick(en: 'Keep editing', zh: '继续编辑', zhTw: '繼續編輯', ja: '編集を続ける');
  String get requiredName => _pick(
    en: 'Enter a source name',
    zh: '请输入书源名称',
    zhTw: '請輸入書源名稱',
    ja: 'ソース名を入力してください',
  );
  String get requiredUrl => _pick(
    en: 'Enter a source URL',
    zh: '请输入书源 URL',
    zhTw: '請輸入書源 URL',
    ja: 'ソース URL を入力してください',
  );
  String get invalidConfig => _pick(
    en: 'Invalid configuration. Check the source URL and JSON fields.',
    zh: '书源配置无效，请检查源 URL 和 JSON 字段格式。',
    zhTw: '書源設定無效，請檢查來源 URL 和 JSON 欄位格式。',
    ja: 'ソース設定が無効です。URL と JSON 項目を確認してください。',
  );
  String get basicHint => _pick(
    en: 'Basic settings and shared scripts',
    zh: '基础设置与共用脚本',
    zhTw: '基本設定與共用腳本',
    ja: '基本設定と共有スクリプト',
  );
  String get enabled => _pick(en: 'Enabled', zh: '启用', zhTw: '啟用', ja: '有効');
  String get explore => _pick(en: 'Explore', zh: '发现', zhTw: '探索', ja: '探索');
  String get cookies =>
      _pick(en: 'Cookies', zh: 'Cookie 管理', zhTw: 'Cookie 管理', ja: 'Cookie');
  String get type => _pick(en: 'Type', zh: '类型', zhTw: '類型', ja: '種類');
  String get debug =>
      _pick(en: 'Debug source', zh: '调试书源', zhTw: '偵錯書源', ja: 'ソースをデバッグ');

  String typeLabel(int type) => switch (type) {
    1 => _pick(en: 'Audio', zh: '音频', zhTw: '音訊', ja: 'オーディオ'),
    2 => _pick(en: 'Comic', zh: '漫画', zhTw: '漫畫', ja: 'マンガ'),
    3 => _pick(en: 'File', zh: '文件', zhTw: '檔案', ja: 'ファイル'),
    4 => _pick(en: 'Video', zh: '视频', zhTw: '影片', ja: '動画'),
    _ => _pick(en: 'Novel', zh: '小说', zhTw: '小說', ja: '小説'),
  };

  String section(String key) => switch (key) {
    'search' => _pick(en: 'Search', zh: '搜索', zhTw: '搜尋', ja: '検索'),
    'exploreSection' => explore,
    'bookInfo' => _pick(en: 'Book info', zh: '详情', zhTw: '詳細', ja: '詳細'),
    'toc' => _pick(en: 'Table of contents', zh: '目录', zhTw: '目錄', ja: '目次'),
    'contentSection' => _pick(en: 'Content', zh: '正文', zhTw: '本文', ja: '本文'),
    _ => _pick(en: 'Basic', zh: '基本', zhTw: '基本', ja: '基本'),
  };

  String field(String id) {
    final key = id.split('.').last;
    final names = <String, ({String en, String zh, String zhTw, String ja})>{
      'bookSourceUrl': (
        en: 'Source URL',
        zh: '源 URL',
        zhTw: '來源 URL',
        ja: 'ソース URL',
      ),
      'bookSourceName': (
        en: 'Source name',
        zh: '源名称',
        zhTw: '來源名稱',
        ja: 'ソース名',
      ),
      'bookSourceGroup': (
        en: 'Source groups',
        zh: '源分组',
        zhTw: '來源分組',
        ja: 'ソースグループ',
      ),
      'bookSourceComment': (
        en: 'Source comment',
        zh: '源注释',
        zhTw: '來源註解',
        ja: 'ソースのメモ',
      ),
      'loginUrl': (
        en: 'Login URL',
        zh: '登录 URL',
        zhTw: '登入 URL',
        ja: 'ログイン URL',
      ),
      'loginUi': (en: 'Login UI', zh: '登录界面', zhTw: '登入介面', ja: 'ログイン UI'),
      'loginCheckJs': (
        en: 'Login check JS',
        zh: '登录检测 JS',
        zhTw: '登入檢查 JS',
        ja: 'ログイン確認 JS',
      ),
      'header': (
        en: 'Request headers',
        zh: '请求头',
        zhTw: '請求標頭',
        ja: 'リクエストヘッダー',
      ),
      'jsLib': (
        en: 'Shared JS library',
        zh: '共用 JS 库',
        zhTw: '共用 JS 函式庫',
        ja: '共有 JS ライブラリ',
      ),
      'concurrentRate': (
        en: 'Concurrent rate',
        zh: '并发率',
        zhTw: '並行率',
        ja: '同時実行率',
      ),
      'searchUrl': (en: 'Search URL', zh: '搜索地址', zhTw: '搜尋網址', ja: '検索 URL'),
      'exploreUrl': (
        en: 'Explore URL rules',
        zh: '发现地址规则',
        zhTw: '探索網址規則',
        ja: '探索 URL ルール',
      ),
      'checkKeyWord': (
        en: 'Keyword check',
        zh: '校验关键字',
        zhTw: '檢查關鍵字',
        ja: 'キーワード確認',
      ),
      'bookList': (
        en: 'Book list rule',
        zh: '书籍列表规则',
        zhTw: '書籍列表規則',
        ja: '書籍一覧ルール',
      ),
      'name': (en: 'Book name rule', zh: '书名规则', zhTw: '書名規則', ja: '書名ルール'),
      'author': (en: 'Author rule', zh: '作者规则', zhTw: '作者規則', ja: '著者ルール'),
      'kind': (en: 'Category rule', zh: '分类规则', zhTw: '分類規則', ja: 'カテゴリルール'),
      'wordCount': (
        en: 'Word count rule',
        zh: '字数规则',
        zhTw: '字數規則',
        ja: '文字数ルール',
      ),
      'lastChapter': (
        en: 'Latest chapter rule',
        zh: '最新章节规则',
        zhTw: '最新章節規則',
        ja: '最新章ルール',
      ),
      'intro': (
        en: 'Introduction rule',
        zh: '简介规则',
        zhTw: '簡介規則',
        ja: '紹介文ルール',
      ),
      'coverUrl': (
        en: 'Cover URL rule',
        zh: '封面 URL 规则',
        zhTw: '封面 URL 規則',
        ja: '表紙 URL ルール',
      ),
      'bookUrl': (
        en: 'Book URL rule',
        zh: '书籍 URL 规则',
        zhTw: '書籍 URL 規則',
        ja: '書籍 URL ルール',
      ),
      'init': (
        en: 'Preprocessing rule',
        zh: '预处理规则',
        zhTw: '預處理規則',
        ja: '前処理ルール',
      ),
      'tocUrl': (
        en: 'TOC URL rule',
        zh: '目录 URL 规则',
        zhTw: '目錄 URL 規則',
        ja: '目次 URL ルール',
      ),
      'preUpdateJs': (
        en: 'Before update JS',
        zh: '更新之前 JS',
        zhTw: '更新之前 JS',
        ja: '更新前 JS',
      ),
      'chapterList': (
        en: 'Chapter list rule',
        zh: '目录列表规则',
        zhTw: '目錄列表規則',
        ja: '章一覧ルール',
      ),
      'chapterName': (
        en: 'Chapter name rule',
        zh: '章节名称规则',
        zhTw: '章節名稱規則',
        ja: '章名ルール',
      ),
      'chapterUrl': (
        en: 'Chapter URL rule',
        zh: '章节 URL 规则',
        zhTw: '章節 URL 規則',
        ja: '章 URL ルール',
      ),
      'formatJs': (
        en: 'Formatting rule',
        zh: '格式化规则',
        zhTw: '格式化規則',
        ja: '整形ルール',
      ),
      'isVolume': (en: 'Volume rule', zh: '卷名规则', zhTw: '卷名規則', ja: '巻ルール'),
      'isVip': (en: 'VIP rule', zh: 'VIP 规则', zhTw: 'VIP 規則', ja: 'VIP ルール'),
      'isPay': (
        en: 'Paid chapter rule',
        zh: '付费章节规则',
        zhTw: '付費章節規則',
        ja: '有料章ルール',
      ),
      'updateTime': (
        en: 'Update time rule',
        zh: '更新时间规则',
        zhTw: '更新時間規則',
        ja: '更新日時ルール',
      ),
      'nextTocUrl': (
        en: 'Next TOC URL rule',
        zh: '目录下一页 URL 规则',
        zhTw: '目錄下一頁 URL 規則',
        ja: '次の目次 URL ルール',
      ),
      'content': (en: 'Content rule', zh: '正文规则', zhTw: '本文規則', ja: '本文ルール'),
      'nextContentUrl': (
        en: 'Next content URL rule',
        zh: '正文下一页 URL 规则',
        zhTw: '本文下一頁 URL 規則',
        ja: '次の本文 URL ルール',
      ),
      'webJs': (
        en: 'WebView JS',
        zh: 'WebView JS',
        zhTw: 'WebView JS',
        ja: 'WebView JS',
      ),
      'sourceRegex': (
        en: 'Source regex',
        zh: '资源正则',
        zhTw: '資源正則表達式',
        ja: 'リソース正規表現',
      ),
      'replaceRegex': (
        en: 'Replacement rule',
        zh: '替换规则',
        zhTw: '替換規則',
        ja: '置換ルール',
      ),
      'imageStyle': (en: 'Image style', zh: '图片样式', zhTw: '圖片樣式', ja: '画像スタイル'),
      'payAction': (
        en: 'Paid content action',
        zh: '付费内容操作',
        zhTw: '付費內容操作',
        ja: '有料コンテンツ操作',
      ),
    };
    final name = names[key];
    if (name == null) return key;
    return _pick(en: name.en, zh: name.zh, zhTw: name.zhTw, ja: name.ja);
  }
}
