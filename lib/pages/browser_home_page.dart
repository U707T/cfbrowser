import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/web_history_provider.dart';
import '../services/browser/browser_scope_service.dart';
import '../services/network/doh/network_settings_service.dart';
import 'browser_scope_page.dart';
import 'webview_page.dart';

/// cfbrowser 首页：地址栏 + 加速范围快捷入口 + 最近访问。
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
    final url = _normalizeInput(raw);
    if (url.isEmpty) return;
    _focusNode.unfocus();
    WebViewPage.open(context, url);
  }

  /// 用户可能只输入 `example.com`，补成 https
  static String _normalizeInput(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    if (value.contains('://')) return value;
    if (RegExp(r'^[a-zA-Z0-9.-]+(:\d+)?(/.*)?$').hasMatch(value)) {
      return 'https://$value';
    }
    return value;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = BrowserScopeService.instance.mitmHosts;
    final serverIp = NetworkSettingsService.instance.current.serverIp;
    final history = ref.watch(webHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('cfbrowser'),
        actions: [
          if (widget.onOpenForum != null)
            IconButton(
              tooltip: '论坛',
              icon: const Icon(Icons.forum_outlined),
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
              hintText: 'https://',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
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
              Icon(Icons.bolt, size: 16, color: theme.colorScheme.primary),
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
                leading: const Icon(Icons.public),
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
