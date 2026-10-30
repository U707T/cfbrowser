import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/browser_tab.dart';
import '../providers/web_history_provider.dart';
import '../services/browser/browser_scope_service.dart';
import '../services/browser/browser_tabs_service.dart';
import '../services/browser/browser_url.dart';
import '../services/network/doh/network_settings_service.dart';
import '../widgets/browser/browser_tabs_sheet.dart';
import 'browser_scope_page.dart';
import 'download_list_page.dart';
import 'my_browser_page.dart';
import 'webview_page.dart';

/// cfbrowser 首页：地址栏 + 快捷入口 + 标签页 + 最近访问。
///
/// 上游 fluxdo 的首页是论坛话题列表；cfbrowser 把入口换成浏览器，
/// 论坛页仍然保留，通过 [onOpenForum] 由 main.dart 注入（避免反向 import main.dart）。
///
/// 所有页面都经 `WebViewPage` 打开，复用同一套 WebView 适配器与本地网关，
/// 因此「加速范围」（[BrowserScopeService.mitmHosts]）对它自动生效。
class BrowserHomePage extends ConsumerStatefulWidget {
  /// 打开论坛列表的回调；为 null 时不显示入口
  final VoidCallback? onOpenForum;

  const BrowserHomePage({super.key, this.onOpenForum});

  @override
  ConsumerState<BrowserHomePage> createState() => _BrowserHomePageState();
}

class _BrowserHomePageState extends ConsumerState<BrowserHomePage> {
  final _urlController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _urlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _go(String raw) {
    final url = BrowserUrl.normalize(raw);
    if (url.isEmpty) return;
    _focusNode.unfocus();
    // 当前标签还是空白页时直接复用它，避免地址栏每输一次就多一个空标签。
    final active = BrowserTabsService.instance.active;
    if (active != null && active.url.isEmpty) {
      WebViewPage.openTab(context, active, url: url);
    } else {
      WebViewPage.open(context, url);
    }
  }

  Future<void> _openScopeSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BrowserScopePage()),
    );
    if (!mounted) return;
    // 范围可能被改过，刷新快捷入口
    setState(() {});
  }

  void _openTab(BrowserTab tab) {
    WebViewPage.openTab(context, tab);
  }

  Future<void> _showTabs() async {
    await showBrowserTabsSheet(context, onSelect: _openTab);
  }

  void _openLibrary() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MyBrowserPage()),
    );
  }

  void _openDownloads() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DownloadListPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = BrowserScopeService.instance.mitmHosts;
    final serverIp = NetworkSettingsService.instance.current.serverIp;
    final history = ref.watch(webHistoryProvider);
    final tabsService = BrowserTabsService.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('cfbrowser'),
        actions: [
          ValueListenableBuilder<List<BrowserTab>>(
            valueListenable: tabsService.tabs,
            builder: (context, tabs, _) {
              return IconButton(
                tooltip: '标签页',
                onPressed: _showTabs,
                icon: Badge.count(
                  count: tabs.length,
                  isLabelVisible: tabs.length > 1,
                  child: const Icon(Symbols.tab_rounded),
                ),
              );
            },
          ),
          if (widget.onOpenForum != null)
            IconButton(
              tooltip: '论坛',
              icon: const Icon(Symbols.forum_rounded),
              onPressed: widget.onOpenForum,
            ),
          IconButton(
            tooltip: '加速范围',
            icon: const Icon(Icons.tune),
            onPressed: _openScopeSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TextField(
            controller: _urlController,
            focusNode: _focusNode,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            onSubmitted: _go,
            decoration: InputDecoration(
              hintText: '输入网址或搜索词',
              prefixIcon: const Icon(Symbols.search_rounded),
              suffixIcon: IconButton(
                icon: const Icon(Symbols.arrow_forward_rounded),
                onPressed: () => _go(_urlController.text),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Symbols.bolt_rounded, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  serverIp == null || serverIp.isEmpty
                      ? '出口：本地优选（自动竞速）'
                      : '出口：固定 $serverIp',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionChip(
                avatar: const Icon(Symbols.collections_bookmark_rounded, size: 16),
                label: const Text('书签与历史'),
                onPressed: _openLibrary,
              ),
              ActionChip(
                avatar: const Icon(Symbols.download_rounded, size: 16),
                label: const Text('下载'),
                onPressed: _openDownloads,
              ),
              ActionChip(
                avatar: const Icon(Symbols.visibility_off_rounded, size: 16),
                label: const Text('无痕标签页'),
                onPressed: () => WebViewPage.openNewTab(context, private: true),
              ),
            ],
          ),
          ValueListenableBuilder<List<BrowserTab>>(
            valueListenable: tabsService.tabs,
            builder: (context, tabs, _) {
              if (tabs.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Text('标签页（${tabs.length}）',
                          style: theme.textTheme.titleSmall),
                      const Spacer(),
                      TextButton(
                        onPressed: _showTabs,
                        child: const Text('管理'),
                      ),
                    ],
                  ),
                  for (final tab in tabs.take(4))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(
                        tab.isPrivate
                            ? Symbols.visibility_off_rounded
                            : Symbols.public_rounded,
                        color: tab.isPrivate ? theme.colorScheme.tertiary : null,
                      ),
                      title: Text(
                        tab.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        tab.url.isEmpty ? '新标签页' : tab.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Symbols.close_rounded, size: 18),
                        onPressed: () => tabsService.close(tab.id),
                      ),
                      onTap: () => _openTab(tab),
                    ),
                  if (tabs.length > 4)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _showTabs,
                        child: Text('还有 ${tabs.length - 4} 个标签页'),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          Text('加速范围', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final host in scope)
                ActionChip(
                  label: Text(host),
                  onPressed: () => _go('https://$host'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text('最近访问', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('还没有记录', style: theme.textTheme.bodySmall),
            )
          else
            for (final item in history.take(20))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Symbols.public_rounded),
                title: Text(
                  item.title.isEmpty ? item.url : item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  item.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _go(item.url),
              ),
        ],
      ),
    );
  }
}
