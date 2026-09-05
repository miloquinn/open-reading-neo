import 'package:flutter/widgets.dart';

/// Localized copy shared by book-source organization controls and their hosts.
///
/// This small, feature-scoped copy object keeps the reusable widgets independent
/// from generated localization changes while still covering every app locale.
class BookSourceOrganizationCopy {
  const BookSourceOrganizationCopy._(this._language);

  final String _language;

  static BookSourceOrganizationCopy of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final language = locale.languageCode == 'zh'
        ? (locale.countryCode == 'TW' || locale.scriptCode == 'Hant'
              ? 'zh_TW'
              : 'zh')
        : locale.languageCode;
    return BookSourceOrganizationCopy._(language);
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

  String get all => _pick(en: 'All', zh: '全部', zhTw: '全部', ja: 'すべて');
  String get favorites =>
      _pick(en: 'Favorites', zh: '收藏', zhTw: '收藏', ja: 'お気に入り');
  String get groups => _pick(en: 'Groups', zh: '分组', zhTw: '分組', ja: 'グループ');
  String get manageGroups =>
      _pick(en: 'Manage groups', zh: '管理分组', zhTw: '管理分組', ja: 'グループを管理');
  String get noFavorites => _pick(
    en: 'No favorite sources available to browse',
    zh: '暂无可浏览的收藏书源',
    zhTw: '暫無可瀏覽的收藏書源',
    ja: '閲覧できるお気に入りのソースがありません',
  );
  String get noGroupSources => _pick(
    en: 'No sources available to browse in this group',
    zh: '这个分组里暂无可浏览的书源',
    zhTw: '這個分組裡暫無可瀏覽的書源',
    ja: 'このグループに閲覧できるソースがありません',
  );

  String get favorite => _pick(
    en: 'Favorite source',
    zh: '收藏书源',
    zhTw: '收藏書源',
    ja: 'ソースをお気に入りに追加',
  );
  String get unfavorite => _pick(
    en: 'Remove from favorites',
    zh: '取消收藏',
    zhTw: '取消收藏',
    ja: 'お気に入りから削除',
  );
  String get favorited => _pick(
    en: 'Source added to favorites',
    zh: '已收藏书源',
    zhTw: '已收藏書源',
    ja: 'ソースをお気に入りに追加しました',
  );
  String get unfavorited => _pick(
    en: 'Source removed from favorites',
    zh: '已取消收藏',
    zhTw: '已取消收藏',
    ja: 'お気に入りから削除しました',
  );
  String get undo => _pick(en: 'Undo', zh: '撤销', zhTw: '復原', ja: '元に戻す');
  String get saveFailed => _pick(
    en: 'Could not save the change. Try again.',
    zh: '保存失败，请重试。',
    zhTw: '儲存失敗，請重試。',
    ja: '変更を保存できませんでした。もう一度お試しください。',
  );
  String get retry => _pick(en: 'Try again', zh: '重试', zhTw: '重試', ja: '再試行');
  String get moreActions => _pick(
    en: 'More source actions',
    zh: '更多书源操作',
    zhTw: '更多書源操作',
    ja: 'その他のソース操作',
  );
  String get addToGroups =>
      _pick(en: 'Add to groups', zh: '加入分组', zhTw: '加入分組', ja: 'グループに追加');
  String get editGroups =>
      _pick(en: 'Edit groups', zh: '编辑分组', zhTw: '編輯分組', ja: 'グループを編集');
  String get sourceDetails =>
      _pick(en: 'Source details', zh: '书源详情', zhTw: '書源詳細', ja: 'ソースの詳細');
  String get done => _pick(en: 'Done', zh: '完成', zhTw: '完成', ja: '完了');
  String get cancel => _pick(en: 'Cancel', zh: '取消', zhTw: '取消', ja: 'キャンセル');
  String get newGroup =>
      _pick(en: 'New group', zh: '新建分组', zhTw: '新增分組', ja: '新しいグループ');
  String get groupName =>
      _pick(en: 'Group name', zh: '分组名称', zhTw: '分組名稱', ja: 'グループ名');
  String get searchGroups =>
      _pick(en: 'Search groups', zh: '搜索分组', zhTw: '搜尋分組', ja: 'グループを検索');
  String get noGroups => _pick(
    en: 'No groups yet',
    zh: '还没有分组',
    zhTw: '還沒有分組',
    ja: 'グループはまだありません',
  );
  String get mixedSelection => _pick(
    en: 'Some selected sources',
    zh: '部分所选书源',
    zhTw: '部分所選書源',
    ja: '選択した一部のソース',
  );
  String selectedSourceCount(int count) => _pick(
    en: '$count sources selected',
    zh: '已选择 $count 个书源',
    zhTw: '已選擇 $count 個書源',
    ja: '$count 件のソースを選択中',
  );
  String get rename =>
      _pick(en: 'Rename', zh: '重命名', zhTw: '重新命名', ja: '名前を変更');
  String get delete => _pick(en: 'Delete', zh: '删除', zhTw: '刪除', ja: '削除');
  String get create => _pick(en: 'Create', zh: '创建', zhTw: '建立', ja: '作成');
  String get groupNameRequired => _pick(
    en: 'Enter a group name',
    zh: '请输入分组名称',
    zhTw: '請輸入分組名稱',
    ja: 'グループ名を入力してください',
  );
  String get groupAlreadyExists => _pick(
    en: 'A group with this name already exists',
    zh: '已存在同名分组',
    zhTw: '已存在同名分組',
    ja: '同じ名前のグループがすでにあります',
  );
  String get deleteGroupTitle => _pick(
    en: 'Delete group?',
    zh: '删除分组？',
    zhTw: '刪除分組？',
    ja: 'グループを削除しますか？',
  );
  String deleteGroupMessage(String name) => _pick(
    en: 'Delete "$name"? Sources in it will be kept.',
    zh: '删除“$name”？其中的书源会保留。',
    zhTw: '刪除「$name」？其中的書源會保留。',
    ja: '「$name」を削除しますか？ソースは削除されません。',
  );
  String get dragToReorder =>
      _pick(en: 'Drag to reorder', zh: '拖动排序', zhTw: '拖曳排序', ja: 'ドラッグして並べ替え');
}
