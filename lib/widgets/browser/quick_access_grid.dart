import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../services/browser/browser_quick_links_service.dart';
import '../../services/browser/browser_url.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';

/// Via 风格的快捷访问网格：站点图标 + 名称，末尾一个添加入口。
class QuickAccessGrid extends StatelessWidget {
  const QuickAccessGrid({super.key, required this.onOpen});

  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = BrowserQuickLinksService.instance;

    return ValueListenableBuilder<List<BrowserQuickLink>>(
      valueListenable: service.links,
      builder: (context, links, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('快捷访问', style: theme.textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: '添加快捷访问',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Symbols.add_rounded, size: 20),
                  onPressed: () => _showEditor(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 10,
                crossAxisSpacing: 8,
                mainAxisExtent: 80,
              ),
              itemCount: links.length + 1,
              itemBuilder: (context, index) {
                if (index == links.length) {
                  return _AddTile(onTap: () => _showEditor(context));
                }
                final link = links[index];
                return _QuickLinkTile(
                  link: link,
                  onTap: () => onOpen(link.url),
                  onLongPress: () => _showActions(context, link),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showActions(
    BuildContext context,
    BrowserQuickLink link,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Symbols.open_in_new_rounded),
            title: const Text('打开'),
            subtitle: Text(link.url, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(ctx, 'open'),
          ),
          ListTile(
            leading: const Icon(Symbols.edit_rounded),
            title: const Text('编辑'),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: const Icon(Symbols.delete_rounded),
            title: const Text('删除'),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'open':
        onOpen(link.url);
        break;
      case 'edit':
        await _showEditor(context, link: link);
        break;
      case 'delete':
        BrowserQuickLinksService.instance.remove(link.id);
        break;
    }
  }

  Future<void> _showEditor(
    BuildContext context, {
    BrowserQuickLink? link,
  }) async {
    final titleController = TextEditingController(text: link?.title ?? '');
    final urlController = TextEditingController(text: link?.url ?? '');
    final result = await showAppDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(link == null ? '添加快捷访问' : '编辑快捷访问'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                autofocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '网址',
                  hintText: 'https://example.com',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleController,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: '名称（可选）',
                  hintText: '留空则使用域名',
                ),
                onSubmitted: (_) => _submitEditor(ctx, urlController, titleController),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                _submitEditor(ctx, urlController, titleController),
            child: Text(link == null ? '添加' : '保存'),
          ),
        ],
      ),
    );
    titleController.dispose();
    urlController.dispose();
    if (result == null || !context.mounted) return;

    final service = BrowserQuickLinksService.instance;
    if (link == null) {
      final added = service.add(url: result.$2, title: result.$1);
      if (added == null) {
        ToastService.showError('最多只能添加 ${BrowserQuickLinksService.maxLinks} 个快捷访问');
      }
    } else {
      service.update(link.id, url: result.$2, title: result.$1);
    }
  }

  static void _submitEditor(
    BuildContext ctx,
    TextEditingController urlController,
    TextEditingController titleController,
  ) {
    final url = BrowserUrl.normalize(urlController.text);
    if (url.isEmpty) {
      ToastService.showError('请输入有效网址');
      return;
    }
    Navigator.pop(ctx, (titleController.text, url));
  }
}

class _QuickLinkTile extends StatelessWidget {
  const _QuickLinkTile({
    required this.link,
    required this.onTap,
    required this.onLongPress,
  });

  final BrowserQuickLink link;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '${link.displayTitle}，${link.url}',
      button: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SiteIcon(link: link),
            const SizedBox(height: 7),
            Text(
              link.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SiteIcon extends StatelessWidget {
  const _SiteIcon({required this.link});

  final BrowserQuickLink link;

  static const _palette = <Color>[
    Color(0xFF3B82F6),
    Color(0xFFF59E0B),
    Color(0xFF10B981),
    Color(0xFF8B5CF6),
    Color(0xFFEF4444),
    Color(0xFF06B6D4),
  ];

  @override
  Widget build(BuildContext context) {
    final host = link.host;
    final title = link.displayTitle;
    final letter = title.isEmpty
        ? '?'
        : String.fromCharCode(title.runes.first).toUpperCase();
    var hash = 0;
    for (final unit in host.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final color = _palette[hash % _palette.length];
    final faviconUrl = host.isEmpty ? null : 'https://$host/favicon.ico';

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Text(
              letter,
              style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (faviconUrl != null)
            Padding(
              padding: const EdgeInsets.all(9),
              child: Image.network(
                faviconUrl,
                fit: BoxFit.contain,
                cacheWidth: 96,
                cacheHeight: 96,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.45,
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Icon(
              Symbols.add_rounded,
              color: theme.colorScheme.onSurfaceVariant,
              size: 22,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '添加',
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
