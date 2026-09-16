import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/account/member_account_controller.dart';
import '../../services/reading/reading_cloud_controller.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import '../../widgets/account_avatar_image.dart';
import '../account/account_page.dart';

String readingCopy(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

class ReadingLeaderboardPage extends StatefulWidget {
  const ReadingLeaderboardPage({super.key});

  @override
  State<ReadingLeaderboardPage> createState() => _ReadingLeaderboardPageState();
}

class _ReadingLeaderboardPageState extends State<ReadingLeaderboardPage> {
  String _period = 'week';
  String _copy(String zh, String en) => readingCopy(context, zh, en);
  String _duration(Object? seconds) {
    final minutes = ((seconds as num?)?.toInt() ?? 0) ~/ 60;
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    if (hours == 0) {
      return _copy('$remainder 分钟', '${remainder}m');
    }
    if (remainder == 0) {
      return _copy('$hours 小时', '${hours}h');
    }
    return _copy('$hours 小时 $remainder 分', '${hours}h ${remainder}m');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(context.read<ReadingCloudController>().initialize());
      }
    });
  }

  Future<void> _claim(ReadingCloudController cloud, String accountName) async {
    final owner = cloud.owner;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_copy('合并本机阅读历史', 'Import local reading history')),
        content: Text(
          _copy(
            '将尚未归属账号的 ${_duration(cloud.guestSeconds)} 阅读历史归入“$accountName”？\n\n'
                '合并后只属于此账号，不能再转给其他账号。历史数据不计入排行榜。',
            'Assign ${_duration(cloud.guestSeconds)} of unassigned history to “$accountName”?\n\n'
                'These records will belong only to this account and cannot be transferred. '
                'Imported history does not count toward rankings.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_copy('暂不合并', 'Not now')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_copy('合并到此账号', 'Import')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && cloud.owner == owner) {
      try {
        await cloud.claimGuest();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _copy(
                  '合并失败，原始数据仍保留在本机',
                  'Import failed. Local records are preserved.',
                ),
              ),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloud = context.watch<ReadingCloudController>();
    final account = context.watch<MemberAccountController>();
    final authenticated =
        account.user?.id == cloud.owner && cloud.owner != null;
    final summary = cloud.summary;
    final board = _period == 'week' ? cloud.week : cloud.month;
    final items = (board?['items'] as List?) ?? const [];
    final me = board?['me'] as Map?;
    final scheme = Theme.of(context).colorScheme;

    return FloatingSubpageScaffold(
      title: _copy('阅读排行榜', 'Reading leaderboard'),
      actions: [
        FloatingSubpageAction(
          tooltip: _copy('同步', 'Sync'),
          icon: Icons.sync_rounded,
          onPressed: cloud.busy ? null : () => unawaited(cloud.synchronize()),
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: RefreshIndicator(
            onRefresh: cloud.synchronize,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: floatingSubpagePadding(
                context,
                left: 18,
                right: 18,
                bottom: 36,
              ),
              children: [
                if (cloud.busy)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: const LinearProgressIndicator(minHeight: 2),
                  ),
                if (cloud.busy) const SizedBox(height: 12),
                if (!authenticated) _buildSignInPanel(scheme),
                if (cloud.error != null) ...[
                  const SizedBox(height: 12),
                  _buildErrorPanel(cloud, scheme),
                ],
                if (cloud.rejectedCount > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                    child: Text(
                      _copy(
                        '${cloud.rejectedCount} 条记录因归属冲突或时间异常未计入云端，原始记录仍保留在本机。',
                        '${cloud.rejectedCount} records were excluded for ownership conflicts or invalid times. '
                            'Their local copies are preserved.',
                      ),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ),
                if (authenticated && cloud.guestSeconds > 0) ...[
                  const SizedBox(height: 12),
                  _buildGuestHistory(cloud, account, scheme),
                ],
                if (authenticated) ...[
                  const SizedBox(height: 12),
                  _buildPublicPreference(summary, cloud, scheme),
                ],
                const SizedBox(height: 28),
                _buildBoardHeading(scheme),
                const SizedBox(height: 14),
                if (authenticated) ...[
                  _buildMyRank(me, summary, scheme),
                  const SizedBox(height: 12),
                ],
                _buildLeaderboard(items, cloud, account, scheme),
                const SizedBox(height: 20),
                _buildRulesNote(scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignInPanel(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _panelDecoration(scheme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconTile(Icons.cloud_outlined, scheme),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  _copy('登录后同步阅读记录', 'Sign in to sync reading'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _copy(
              '在不同设备继续累计阅读时长，并参与周榜和月榜。',
              'Keep your reading time across devices and join weekly and monthly rankings.',
            ),
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const AccountPage()),
            ),
            child: Text(_copy('登录账号', 'Sign in')),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorPanel(ReadingCloudController cloud, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 20, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              cloud.error!,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: cloud.busy ? null : cloud.synchronize,
            child: Text(_copy('重试', 'Retry')),
          ),
        ],
      ),
    );
  }

  Widget _buildGuestHistory(
    ReadingCloudController cloud,
    MemberAccountController account,
    ColorScheme scheme,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: _panelDecoration(scheme, radius: 18),
      child: Row(
        children: [
          Icon(Icons.history_rounded, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _copy('本机未归属历史', 'Unassigned local history'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  _duration(cloud.guestSeconds),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: cloud.busy
                ? null
                : () => _claim(cloud, account.user!.effectiveName),
            child: Text(_copy('合并', 'Import')),
          ),
        ],
      ),
    );
  }

  Widget _buildPublicPreference(
    Map<String, dynamic>? summary,
    ReadingCloudController cloud,
    ColorScheme scheme,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 10, 13),
      decoration: _panelDecoration(scheme, radius: 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _copy('参加公开排行榜', 'Join public leaderboard'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  _copy(
                    '仅公开昵称、头像和有效阅读时长',
                    'Only name, avatar and ranked reading time are public',
                  ),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch.adaptive(
            key: const ValueKey('reading-public-switch'),
            value: summary?['public'] == true,
            onChanged: cloud.savingPreference || cloud.busy || summary == null
                ? null
                : cloud.setPublic,
          ),
        ],
      ),
    );
  }

  Widget _buildBoardHeading(ColorScheme scheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Text(
          _period == 'week'
              ? _copy('本周排行', 'This week')
              : _copy('本月排行', 'This month'),
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        );
        final selector = _buildPeriodSelector(scheme);
        if (constraints.maxWidth < 440) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 12), selector],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            selector,
          ],
        );
      },
    );
  }

  Widget _buildPeriodSelector(ColorScheme scheme) {
    return Container(
      height: 40,
      width: 184,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(child: _periodButton('week', _copy('周榜', 'Weekly'), scheme)),
          Expanded(
            child: _periodButton('month', _copy('月榜', 'Monthly'), scheme),
          ),
        ],
      ),
    );
  }

  Widget _periodButton(String value, String label, ColorScheme scheme) {
    final selected = _period == value;
    return Material(
      color: selected ? scheme.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: () => setState(() => _period = value),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMyRank(
    Map? me,
    Map<String, dynamic>? summary,
    ColorScheme scheme,
  ) {
    final ranked = me != null;
    return Container(
      key: const ValueKey('reading-my-rank-card'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.18),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.person_outline_rounded, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _copy('我的名次', 'My rank'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  ranked
                      ? _duration(me['seconds'])
                      : _copy(
                          summary?['public'] == true
                              ? '本期暂无有效阅读记录'
                              : '开启公开上榜后显示名次',
                          summary?['public'] == true
                              ? 'No ranked reading this period'
                              : 'Opt in to see your rank',
                        ),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            ranked ? '#${me['rank']}' : '—',
            key: const ValueKey('reading-my-rank'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeaderboard(
    List items,
    ReadingCloudController cloud,
    MemberAccountController account,
    ColorScheme scheme,
  ) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: _panelDecoration(scheme),
      child: items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
              child: Column(
                children: [
                  Icon(
                    Icons.emoji_events_outlined,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                    size: 32,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _copy('暂无上榜读者', 'No ranked readers yet'),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                for (var index = 0; index < items.length; index++) ...[
                  _buildRankRow(
                    (items[index] as Map).cast<String, dynamic>(),
                    cloud,
                    account,
                    scheme,
                  ),
                  if (index != items.length - 1)
                    Divider(
                      height: 1,
                      indent: 62,
                      color: scheme.outlineVariant.withValues(alpha: 0.6),
                    ),
                ],
              ],
            ),
    );
  }

  Widget _buildRankRow(
    Map<String, dynamic> item,
    ReadingCloudController cloud,
    MemberAccountController account,
    ColorScheme scheme,
  ) {
    final rank = (item['rank'] as num).toInt();
    final isMe = item['user_id'] == cloud.owner;
    final rankColor = switch (rank) {
      1 => const Color(0xFFC48A24),
      2 => const Color(0xFF788593),
      3 => const Color(0xFFA96F4B),
      _ => scheme.onSurfaceVariant,
    };

    return ColoredBox(
      color: isMe
          ? scheme.primary.withValues(alpha: 0.055)
          : Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: rank <= 3
                    ? rankColor.withValues(alpha: 0.13)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                '$rank',
                style: TextStyle(
                  color: rankColor,
                  fontSize: 13,
                  fontWeight: rank <= 3 ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            CircleAvatar(
              radius: 19,
              backgroundColor: scheme.primary.withValues(alpha: 0.10),
              child: item['avatar_url'] == null
                  ? Icon(
                      Icons.person_outline_rounded,
                      size: 20,
                      color: scheme.primary,
                    )
                  : ClipOval(
                      child: AccountAvatarImage(
                        url: account.readingApi.baseUri.resolve(
                          item['avatar_url'] as String,
                        ),
                        fallback: Icon(
                          Icons.person_outline_rounded,
                          size: 20,
                          color: scheme.primary,
                        ),
                        width: 38,
                        height: 38,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      item['name'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: isMe ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        _copy('我', 'You'),
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _duration(item['seconds']),
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRulesNote(ColorScheme scheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 16,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _copy(
              '按北京时间统计，周一开始新一周。仅统计登录后的前台阅读；朗读、游客和导入历史不参与排名。离线记录可在 7 天内补传上榜。',
              'Periods use UTC+8 and weeks start Monday. Rankings count foreground reading while signed in. Listening, guest and imported history are excluded. Offline records can rank when uploaded within 7 days.',
            ),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _iconTile(IconData icon, ColorScheme scheme) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, size: 21, color: scheme.primary),
    );
  }

  BoxDecoration _panelDecoration(
    ColorScheme scheme, {
    bool emphasized = false,
    double radius = 24,
  }) {
    return BoxDecoration(
      color: emphasized
          ? Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.055),
              scheme.surfaceContainerLow,
            )
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: scheme.outlineVariant.withValues(alpha: 0.65),
        width: 0.7,
      ),
      boxShadow: [
        BoxShadow(
          color: scheme.shadow.withValues(
            alpha: scheme.brightness == Brightness.dark ? 0.12 : 0.035,
          ),
          blurRadius: 22,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }
}
