import 'package:flutter/material.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'package:xxread/widgets/side_toast.dart';
import 'webdav_sync_translator.dart';

class SyncNavigationTile extends StatelessWidget {
  const SyncNavigationTile({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    minLeadingWidth: 24,
    horizontalTitleGap: 12,
    leading: Icon(icon, size: 22),
    title: Text(title),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        detail,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
      ),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
    enabled: onTap != null,
    onTap: onTap,
  );
}

class SyncSection extends StatelessWidget {
  const SyncSection({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      SyncSurface(child: child),
    ],
  );
}

class SyncSurface extends StatelessWidget {
  const SyncSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: PageStyleHelper.palette(context).card,
    borderRadius: BorderRadius.circular(18),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class SyncDivider extends StatelessWidget {
  const SyncDivider({super.key});
  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 0.5,
    indent: 16,
    endIndent: 16,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.65),
  );
}

Future<void> performSyncAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (!context.mounted) return;
    showSideToast(
      context,
      webDavSyncErrorText(
        context,
        error is WebDavSyncFailure ? error.code : WebDavSyncErrorCode.unknown,
      ),
      kind: SideToastKind.error,
    );
  }
}

class SyncPageBody extends StatelessWidget {
  const SyncPageBody({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView(
    padding: floatingSubpagePadding(context, top: 24, bottom: 40),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ],
  );
}

Future<void> openSyncPage(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
