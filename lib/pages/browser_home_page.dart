import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/browser_tab.dart';
import '../providers/read_later_provider.dart' show appReadyProvider;
import '../providers/web_history_provider.dart';
import '../services/browser/browser_tabs_service.dart';
import '../services/browser/browser_url.dart';
import '../services/browser_trust_coordinator.dart';
import '../services/connectivity_service.dart';
import '../services/deep_link_service.dart';
import '../services/network/doh/network_settings_service.dart';
import '../widgets/browser/browser_tabs_sheet.dart';
import 'browser_scope_page.dart';
import 'download_list_page.dart';
import 'my_browser_page.dart';
import 'settings_page.dart';
import 'webview_page.dart';

/// cfbrowser 首页：原生浏览器体验 + 右上角收敛的原生论坛入口。
///
/// 打开 App 直接到这里，不再经过 linux.do 登录/预载页；论坛、书签、下载、
/// 加速范围都收进右上角菜单。linux.do 的代理保持待命，只有站内请求会走
/// MITM/ECH 范围。
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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 浏览器首页现在是启动页：这些原本由 MainPage/OnboardingGate 做的
      // 全局初始化要在这里补上，否则深链、CF 验证弹窗和“应用就绪”都没有上下文。
      ref.read(appReadyProvider.notifier).state = true;
      BrowserTrustCoordinator.instance.setNavigatorContext(context);
      DeepLinkService.instance.initialize(context);
      ConnectivityService().init();
    });
  }

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

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
  }

  Future<void> _openForum() async {
    // 进论坛前先唤醒 linux.do 代理，避免首页 API 直连撞 DNS 污染。
    await NetworkSettingsService.instance.leaveStandby();
    if (mounted) widget.onOpenForum?.call();
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'forum':
        unawaited(_openForum());
        break;
      case 'library':
        _openLibrary();
        break;
      case 'downloads':
        _openDownloads();
        break;
      case 'scope':
        _openScopeSettings();
        break;
      case 'settings':
        _openSettings();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Symbols.more_vert_rounded),
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              if (widget.onOpenForum != null)
                const PopupMenuItem(
                  value: 'forum',
                  child: Row(
                    children: [
                      Icon(Symbols.forum_rounded),
                      SizedBox(width: 10),
                      Text('Linux.do 论坛'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'library',
                child: Row(
                  children: [
                    Icon(Symbols.collections_bookmark_rounded),
                    SizedBox(width: 10),
                    Text('书签与历史'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'downloads',
                child: Row(
                  children: [
                    Icon(Symbols.download_rounded),
                    SizedBox(width: 10),
                    Text('下载'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'scope',
                child: Row(
                  children: [
                    Icon(Symbols.tune_rounded),
                    SizedBox(width: 10),
                    Text('加速范围'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Symbols.settings_rounded),
                    SizedBox(width: 10),
                    Text('设置'),
                  ],
                ),
              ),
            ],
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
              Icon(
                Symbols.bolt_rounded,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  serverIp == null || serverIp.isEmpty
                      ? 'Linux.do 加速：按需启用（仅站内）'
                      : 'Linux.do 固定出口：$serverIp',
                  style: theme.textTheme.bodySmall,
                ),
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
                      Text(
                        '标签页（${tabs.length}）',
                        style: theme.textTheme.titleSmall,
                      ),
                      const Spacer(),
                      TextButton(onPressed: _showTabs, child: const Text('管理')),
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
                        color: tab.isPrivate
                            ? theme.colorScheme.tertiary
                            : null,
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
