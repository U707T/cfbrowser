import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_model_manager/ai_model_manager.dart'
    show SwipeActionCell, SwipeAction, SwipeActionScope;
import 'package:share_plus/share_plus.dart';

import '../l10n/s.dart';
import '../models/web_bookmark.dart';
import '../providers/web_bookmark_provider.dart';
import '../services/browser/bookmark_transfer.dart';
import '../services/browser/browser_url.dart';
import '../services/toast_service.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../utils/dialog_utils.dart';
import '../utils/share_utils.dart';
import '../utils/time_utils.dart';
import 'webview_page.dart';

/// 书签页：列表 + 搜索 + 手动添加 + 导入 / 导出。
class BookmarkListPage extends ConsumerStatefulWidget {
  const BookmarkListPage({super.key});

  @override
  ConsumerState<BookmarkListPage> createState() => _BookmarkListPageState();
}

class _BookmarkListPageState extends ConsumerState<BookmarkListPage> {
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bookmarks = ref.watch(webBookmarkProvider);
    final theme = Theme.of(context);
    final visible = _filter(bookmarks);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.myBrowser_bookmarks),
        actions: [
          IconButton(
            icon: Icon(
              _searching ? Symbols.close_rounded : Symbols.search_rounded,
            ),
            tooltip: _searching ? '退出搜索' : '搜索书签',
            onPressed: _toggleSearch,
          ),
          IconButton(
            icon: const Icon(Symbols.add_rounded),
            tooltip: context.l10n.myBrowser_addManually,
            onPressed: () => _showAddDialog(context),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Symbols.more_vert_rounded),
            onSelected: _handleMenu,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'import',
                child: Row(
                  children: [
                    Icon(Symbols.file_open_rounded),
                    SizedBox(width: 8),
                    Text('导入书签'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'export_html',
                child: Row(
                  children: [
                    Icon(Symbols.ios_share_rounded),
                    SizedBox(width: 8),
                    Text('导出为书签 HTML'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'export_json',
                child: Row(
                  children: [
                    Icon(Symbols.save_rounded),
                    SizedBox(width: 8),
                    Text('导出为备份 JSON'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索标题或网址',
                  prefixIcon: const Icon(Symbols.search_rounded),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Symbols.clear_rounded, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
            ),
          Expanded(
            child: bookmarks.isEmpty
                ? _emptyState(theme, context.l10n.myBrowser_empty)
                : visible.isEmpty
                ? _emptyState(theme, '没有匹配“$_query”的书签')
                : SwipeActionScope(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final item = visible[index];
                        return Padding(
                          padding: EdgeInsets.only(
                            bottom: index < visible.length - 1 ? 12 : 0,
                          ),
                          child: SwipeActionCell(
                            key: ValueKey(item.url),
                            trailingActions: [
                              SwipeAction(
                                icon: Symbols.edit_rounded,
                                color: Colors.blue,
                                label: S.current.myBrowser_edit,
                                onPressed: () => _showEditDialog(item),
                              ),
                              SwipeAction(
                                icon: Symbols.share_rounded,
                                color: Colors.teal,
                                label: '分享',
                                onPressed: () => _share(item),
                              ),
                              SwipeAction(
                                icon: Symbols.delete_rounded,
                                color: Colors.red,
                                label: S.current.myBrowser_delete,
                                onPressed: () => _confirmDelete(item),
                              ),
                            ],
                            child: _BookmarkCard(
                              item: item,
                              onTap: () => WebViewPage.open(
                                context,
                                item.url,
                                title: item.title,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 标题、网址、域名任一命中即可；不区分大小写。
  List<WebBookmark> _filter(List<WebBookmark> items) {
    if (_query.isEmpty) return items;
    final needle = _query.toLowerCase();
    return [
      for (final item in items)
        if (item.title.toLowerCase().contains(needle) ||
            item.url.toLowerCase().contains(needle))
          item,
    ];
  }

  Widget _emptyState(ThemeData theme, String message) {
    final custom = mojianEmptyState(context, Symbols.star_rounded, message);
    if (custom != null) return custom;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.star_rounded,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _search.clear();
        _query = '';
      }
    });
  }

  Future<void> _handleMenu(String action) async {
    switch (action) {
      case 'import':
        await _importBookmarks();
        break;
      case 'export_html':
        await _export(asJson: false);
        break;
      case 'export_json':
        await _export(asJson: true);
        break;
    }
  }

  void _showAddDialog(BuildContext context) {
    final urlController = TextEditingController();
    final titleController = TextEditingController();

    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.myBrowser_addManually),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: S.current.myBrowser_inputUrl,
                hintText: 'https://',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                labelText: S.current.myBrowser_inputTitle,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () async {
              final url = _normalizeInput(urlController.text);
              if (url == null) {
                ToastService.showError('请输入有效的 HTTP 或 HTTPS 网页地址');
                return;
              }
              await _saveDialog(
                ctx,
                () => ref.read(webBookmarkProvider.notifier).add(
                  WebBookmark(
                    url: url,
                    title: titleController.text.trim(),
                    createdAt: DateTime.now(),
                  ),
                ),
              );
            },
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(WebBookmark item) {
    final titleController = TextEditingController(text: item.title);

    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.myBrowser_editTitle),
        content: TextField(
          controller: titleController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: S.current.myBrowser_inputTitle,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () => _saveDialog(
              ctx,
              () => ref
                  .read(webBookmarkProvider.notifier)
                  .rename(item.url, titleController.text.trim()),
            ),
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(WebBookmark item) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.myBrowser_delete),
        content: Text(S.current.myBrowser_confirmDelete),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () => _saveDialog(
              ctx,
              () => ref.read(webBookmarkProvider.notifier).removeByUrl(item.url),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(S.current.myBrowser_delete),
          ),
        ],
      ),
    );
  }

  /// 写入成功才关闭对话框；失败保持在对话框里并提示。
  Future<void> _saveDialog(
    BuildContext dialogContext,
    Future<void> Function() write,
  ) async {
    final route = ModalRoute.of(dialogContext);
    try {
      await write();
      if (dialogContext.mounted && route?.isCurrent == true) {
        Navigator.pop(dialogContext);
      }
    } catch (_) {
      if (dialogContext.mounted) {
        ToastService.showError('未能保存书签更改，请重试');
      }
    }
  }

  Future<void> _share(WebBookmark item) async {
    try {
      await SharePlus.instance.share(
        ShareParams(text: item.url, subject: item.title),
      );
    } catch (e) {
      if (mounted) ToastService.showError('分享失败：$e');
    }
  }

  /// 导出到用户选择的位置（桌面另存为 / Android 公共下载目录）。
  Future<void> _export({required bool asJson}) async {
    final bookmarks = ref.read(webBookmarkProvider);
    if (bookmarks.isEmpty) {
      ToastService.showInfo('还没有书签可导出');
      return;
    }
    final content = asJson
        ? BookmarkTransfer.exportJson(bookmarks)
        : BookmarkTransfer.exportHtml(bookmarks);
    final stamp = DateTime.now();
    final name =
        'cfbrowser-bookmarks-${stamp.year}'
        '${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}'
        '.${asJson ? 'json' : 'html'}';
    try {
      final file = await ShareUtils.createOutboxFile(name);
      await file.writeAsString(content);
      final outcome = await ShareUtils.saveFile(
        XFile(
          file.path,
          mimeType: asJson ? 'application/json' : 'text/html',
        ),
      );
      if (!mounted) return;
      if (outcome.shared) {
        ToastService.showSuccess('已导出 ${bookmarks.length} 个书签');
      }
    } catch (e) {
      if (mounted) ToastService.showError('导出失败：$e');
    }
  }

  Future<void> _importBookmarks() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['html', 'htm', 'json'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    final List<WebBookmark> parsed;
    try {
      parsed = BookmarkTransfer.parse(
        await File(path).readAsString(),
        fileName: path,
      );
    } catch (e) {
      if (mounted) ToastService.showError('读取文件失败：$e');
      return;
    }
    if (parsed.isEmpty) {
      if (mounted) ToastService.showError('文件里没有可导入的网页书签');
      return;
    }
    if (!mounted) return;

    final replace = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入书签'),
        content: Text(
          '文件中有 ${parsed.length} 个网页书签。\n\n'
          '合并：保留现有书签，只追加不重复的。\n'
          '替换：清空现有书签后再导入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('替换'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('合并'),
          ),
        ],
      ),
    );
    if (replace == null || !mounted) return;

    try {
      if (replace) {
        await ref.read(webBookmarkProvider.notifier).replaceAll(parsed);
        if (!mounted) return;
        ToastService.showSuccess('已导入 ${parsed.length} 个书签');
      } else {
        final added = await ref
            .read(webBookmarkProvider.notifier)
            .importBookmarks(parsed);
        if (!mounted) return;
        ToastService.showSuccess(
          added == 0 ? '没有新书签可导入（都已存在）' : '新增 $added 个书签',
        );
      }
    } catch (_) {
      if (mounted) ToastService.showError('导入失败，未能写入书签');
    }
  }

  String? _normalizeInput(String input) {
    final value = input.trim();
    if (value.isEmpty) return null;
    final url = value.contains('://') ? value : 'https://$value';
    return BrowserUrl.isWebUrl(url) ? url : null;
  }
}

/// 书签卡片 — 不包 Card，由外层 SwipeActionCell 提供容器
class _BookmarkCard extends StatelessWidget {
  final WebBookmark item;
  final VoidCallback onTap;

  const _BookmarkCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = BrowserUrl.hostOf(item.url);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Symbols.language_rounded,
                color: theme.colorScheme.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title.isNotEmpty ? item.title : host,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        TimeUtils.formatRelativeTime(item.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              Symbols.chevron_right_rounded,
              color: theme.colorScheme.outline.withValues(alpha: 0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
