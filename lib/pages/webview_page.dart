import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../constants.dart';
import '../models/browser_tab.dart';
import '../services/browser/browser_scope_service.dart';
import '../services/browser/browser_tabs_service.dart';
import '../services/browser/browser_url.dart';
import '../utils/frame_jank_monitor.dart';
import '../utils/link_launcher.dart';
import '../services/deep_link_service.dart';
import '../services/toast_service.dart';
import '../services/app_link_service.dart';
import '../services/network/cookie/cookie_store_observer.dart';
import '../services/session/webview_use.dart';
import '../services/webview_settings.dart';
import '../services/windows_webview_environment_service.dart';
import '../widgets/browser/browser_tabs_sheet.dart';
import '../widgets/common/app_link_confirm_dialog.dart';
import '../providers/web_bookmark_provider.dart';
import '../providers/web_history_provider.dart';
import '../providers/download_provider.dart';
import 'package:common_ui/common_ui.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'my_browser_page.dart';

/// 通用内置浏览器页面。
///
/// 一个 WebViewPage 对应一个标签页；标签的地址与 URL 级历史由
/// [BrowserTabsService] 统一保存，切换标签时用保存的地址重建 WebView。
/// 这样标签列表可以跨页面/跨重启存在，代价是切换标签会丢页面滚动位置。
class WebViewPage extends ConsumerStatefulWidget {
  final String url;
  final String? title;
  final String? injectCss;

  /// 已存在的标签 id；为空时本页会新建一个标签。
  final String? tabId;

  /// 新建标签时是否使用无痕模式（仅在 [tabId] 为空时生效）。
  final bool private;

  const WebViewPage({
    super.key,
    required this.url,
    this.title,
    this.injectCss,
    this.tabId,
    this.private = false,
  });

  /// 打开浏览器，url 为空字符串时显示新标签页。
  static Future<T?> open<T extends Object?>(
    BuildContext context,
    String url, {
    String? title,
    String? injectCss,
  }) {
    return Navigator.push<T>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            WebViewPage(url: url, title: title, injectCss: injectCss),
      ),
    );
  }

  /// 打开一个已存在的标签。
  static Future<T?> openTab<T extends Object?>(
    BuildContext context,
    BrowserTab tab, {
    String? url,
  }) {
    return Navigator.push<T>(
      context,
      MaterialPageRoute(
        builder: (_) => WebViewPage(url: url ?? tab.url, tabId: tab.id),
      ),
    );
  }

  /// 新建标签并打开。
  static Future<T?> openNewTab<T extends Object?>(
    BuildContext context, {
    bool private = false,
  }) {
    final tab = BrowserTabsService.instance.create(isPrivate: private);
    return openTab<T>(context, tab);
  }

  @override
  ConsumerState<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends ConsumerState<WebViewPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  String _currentUrl = '';
  String _currentTitle = '';
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _historyStateSettled = false;
  int _navigationRevision = 0;

  late final BrowserTabsService _tabs;
  late final String _tabId;
  late final bool _isPrivate;
  late bool _desktopMode;

  /// 页内查找。Android 走 WebView.findAllAsync，桌面端由插件映射到
  /// WebKitGTK / WebView2 的查找接口。
  late final FindInteractionController _findController;
  final ValueNotifier<String> _findStatus = ValueNotifier<String>('');

  /// 对话框期间用静态截图盖住 WebView，避免 BackdropFilter 对
  /// hybrid composition（Android）/HWND（Windows）实时回读造成卡顿。
  Uint8List? _webViewSnapshot;

  /// 这个页面的 WebView 使用期：开始时从 jar 重灌，期间定期、关页时把 `_t`
  /// 交 SessionTokenAuthority（用户浏览不把页面 cookie 带回 jar）。
  /// 无痕标签不参与这套逻辑，避免把站点登录态带进无痕页面。
  WebViewUse? _webViewUse;

  /// 站内页面长时间停留时 XHR 会让 WebView 自己轮换 _t，而 jar 只在页面
  /// 加载完成时跟一次。定期对账，避免两边分叉超过轮换窗口后 jar 的值被判死。
  Timer? _sessionTokenReconcileTimer;
  static const Duration _sessionTokenReconcileInterval = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    _tabs = BrowserTabsService.instance;

    final existing = widget.tabId == null ? null : _tabs.byId(widget.tabId!);
    final tab = existing ??
        _tabs.create(
          url: widget.url,
          title: widget.title ?? '',
          isPrivate: widget.private,
        );
    _tabId = tab.id;
    _isPrivate = tab.isPrivate;
    _desktopMode = tab.desktopMode;
    _tabs.setActive(_tabId);
    _tabs.tabs.addListener(_onTabsChanged);

    _currentUrl = widget.url.isNotEmpty ? widget.url : tab.url;
    _currentTitle =
        (widget.title != null && widget.title!.isNotEmpty)
            ? widget.title!
            : tab.title;

    _findController = FindInteractionController(
      onFindResultReceived: (_, activeMatch, numberOfMatches, isDoneCounting) {
        if (!mounted) return;
        if (numberOfMatches <= 0) {
          _findStatus.value = isDoneCounting ? '无结果' : '';
        } else {
          _findStatus.value = '$activeMatch/$numberOfMatches';
        }
      },
    );

    if (!_isPrivate) {
      _webViewUse = WebViewUses.instance.start(
        WebViewUsePurpose.browsing,
        url: _currentUrl.isEmpty ? AppConstants.baseUrl : _currentUrl,
        reason: 'in_app_browser',
      );
      _sessionTokenReconcileTimer = Timer.periodic(
        _sessionTokenReconcileInterval,
        (_) => _reconcileSessionToken('in_app_browser_tick'),
      );
    }

    // 可见 WebView(hybrid composition)在位期间会参与每帧合成,
    // 打点让诊断时间轴能对齐"WebView 页在前台"与掉帧段
    FrameJankMonitor.logEvent('WEBVIEW', 'WebViewPage mount');
  }

  @override
  void dispose() {
    FrameJankMonitor.logEvent('WEBVIEW', 'WebViewPage dispose');
    _tabs.tabs.removeListener(_onTabsChanged);
    _sessionTokenReconcileTimer?.cancel();
    _sessionTokenReconcileTimer = null;

    // 关页前最后对一次账：页面里最后几次 XHR 的轮换结果要交给 authority
    final use = _webViewUse;
    if (use != null) {
      final siteUrl = _siteUrlCandidate();
      unawaited(
        siteUrl == null
            ? use.end(WebViewUseOutcome.aborted)
            : use.end(
                WebViewUseOutcome.loaded,
                reason: 'in_app_browser_dispose',
                url: siteUrl,
              ),
      );
    }
    _controller?.dispose();
    _findController.dispose();
    _findStatus.dispose();
    super.dispose();
  }

  void _onTabsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _reconcileSessionToken(String reason) {
    final use = _webViewUse;
    if (use == null) return;
    // 初始 url 或当前 url 之一在站内才有对账意义；reconcile 自己会按
    // 站点域名再过滤一次，站外页面直接跳过。
    final siteUrl = _siteUrlCandidate();
    if (siteUrl == null) return;
    // 站内页打开期间 WebView 的 _t 被服务端删掉（页内请求带了死值）时，
    // 把 jar 里仍有效的值推过去，页面下一次请求就能恢复登录态（口径在
    // WebViewUses）。
    unawaited(
      use.checkpoint(
        WebViewUseOutcome.loaded,
        reason: reason,
        url: siteUrl,
      ),
    );
  }

  String? _siteUrlCandidate() {
    final siteHost = Uri.parse(AppConstants.baseUrl).host.toLowerCase();
    bool isSite(String url) {
      final host = Uri.tryParse(url)?.host.toLowerCase();
      if (host == null || host.isEmpty) return false;
      return host == siteHost || host.endsWith('.$siteHost');
    }

    if (isSite(_currentUrl)) return _currentUrl;
    if (isSite(widget.url)) return widget.url;
    return null;
  }

  InAppWebViewSettings _buildSettings() {
    final settings = WebViewSettings.visible;
    if (_isPrivate) {
      settings.incognito = true;
      settings.sharedCookiesEnabled = false;
      settings.cacheEnabled = false;
      settings.isInspectable = false;
    }
    // setSettings 会整份替换设置，这里必须把 URL 拦截重新打开，
    // 否则切一次桌面版后应用链接确认框就失效了。
    settings.useShouldOverrideUrlLoading = true;
    // 移动端也打开双指缩放；桌面版再放宽视口，让站点按桌面宽度排版。
    settings.supportZoom = true;
    settings.builtInZoomControls = true;
    settings.displayZoomControls = false;
    if (_desktopMode) {
      settings.userAgent = WebViewSettings.desktopUserAgent;
      settings.useWideViewPort = true;
      settings.loadWithOverviewMode = true;
    }
    return settings;
  }

  static bool _isBlankUrl(String? url) =>
      url == null || url.isEmpty || url == 'about:blank';

  @override
  Widget build(BuildContext context) {
    final windowsWebViewEnvironment =
        WindowsWebViewEnvironmentService.instance.environment;

    final theme = Theme.of(context);
    final tab = _tabs.byId(_tabId);
    final canGoBack = _canGoBack || (tab?.canGoBack ?? false);
    final canGoForward = _canGoForward || (tab?.canGoForward ?? false);
    final isBookmarked = ref.watch(
      webBookmarkProvider.select(
        (list) => list.any((e) => e.url == _currentUrl),
      ),
    );

    return PopScope(
      // WebView 还有历史时，返回键先回退网页；到首层后交给路由，
      // 这样离开浏览器页面可以使用 Android 预测式返回动画。
      // 历史状态未稳定时保守拦截并实时查询，避免新页面刚开始导航、
      // _canGoBack 尚未回填的窗口里把整个 WebView 路由直接退出。
      canPop: _historyStateSettled && !canGoBack,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackNavigation();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: GestureDetector(
            onTap: _showUrlInput,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Icon(
                    _isPrivate
                        ? Symbols.visibility_off_rounded
                        : (_currentUrl.startsWith('https://')
                              ? Symbols.lock_rounded
                              : Symbols.public_rounded),
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _currentTitle.isNotEmpty
                          ? _currentTitle
                          : (_currentUrl.isNotEmpty
                                ? _currentUrl
                                : '输入网址'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            _currentTitle.isNotEmpty || _currentUrl.isNotEmpty
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_desktopMode)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        Symbols.desktop_windows_rounded,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          leading: Center(
            child: GestureDetector(
              onTap: _closeActiveTab,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Symbols.close_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          leadingWidth: 48,
          actions: [
            ValueListenableBuilder<List<BrowserTab>>(
              valueListenable: _tabs.tabs,
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
            SwipeDismissiblePopupMenuButton<String>(
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'new_tab',
                  child: Row(
                    children: [
                      const Icon(Symbols.add_rounded),
                      const SizedBox(width: 8),
                      const Text('新建标签页'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'new_private_tab',
                  child: Row(
                    children: [
                      const Icon(Symbols.visibility_off_rounded),
                      const SizedBox(width: 8),
                      const Text('无痕标签页'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'find',
                  child: Row(
                    children: [
                      const Icon(Symbols.find_in_page_rounded),
                      const SizedBox(width: 8),
                      const Text('在页面中查找'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'toggle_desktop',
                  child: Row(
                    children: [
                      Icon(
                        Symbols.desktop_windows_rounded,
                        fill: _desktopMode ? 1 : 0,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('桌面版网站')),
                      if (_desktopMode)
                        const Icon(Symbols.check_rounded, size: 18),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'toggle_bookmark',
                  child: Row(
                    children: [
                      Icon(
                        Symbols.star_rounded,
                        fill: isBookmarked ? 1 : 0,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isBookmarked
                            ? context.l10n.webview_removeBookmark
                            : context.l10n.webview_addBookmark,
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: Row(
                    children: [
                      const Icon(Symbols.share_rounded),
                      const SizedBox(width: 8),
                      const Text('分享页面'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'library',
                  child: Row(
                    children: [
                      const Icon(Symbols.collections_bookmark_rounded),
                      const SizedBox(width: 8),
                      const Text('书签与历史'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'copy_url',
                  child: Row(
                    children: [
                      const Icon(Symbols.content_copy_rounded),
                      const SizedBox(width: 8),
                      Text(context.l10n.common_copyLink),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'open_external',
                  child: Row(
                    children: [
                      const Icon(Symbols.open_in_browser_rounded),
                      const SizedBox(width: 8),
                      Text(context.l10n.webview_openExternal),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'home',
                  child: Row(
                    children: [
                      const Icon(Symbols.home_rounded),
                      const SizedBox(width: 8),
                      const Text('回到主页'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (_isLoading)
              M3eLinearProgress(
                value: _progress,
                trackColor: theme.colorScheme.surfaceContainerHighest,
              ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: _webViewSnapshot != null,
                    child: WebViewSettings.wrapWithScrollFix(
                      InAppWebView(
                        webViewEnvironment: windowsWebViewEnvironment,
                        initialSettings: _buildSettings(),
                        initialUserScripts:
                            WebViewSettings.compatPolyfillScripts,
                        findInteractionController: _findController,
                        shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
                        onReceivedServerTrustAuthRequest: (_, challenge) =>
                            WebViewSettings.handleServerTrustAuthRequest(
                              challenge,
                            ),
                        onWebViewCreated: (controller) async {
                          _controller = controller;
                          // 老 WKWebView 的 JS 运行时错误回传到 LogWriter。
                          WebViewSettings.registerJsErrorReporter(controller);
                          if (_currentUrl.isNotEmpty) {
                            // 等使用期的准备（重灌）完成再加载；准备失败
                            // 也照常加载（取代 RawSetCookieQueue.flush）
                            final use = _webViewUse;
                            if (use != null) await use.ready;
                            await controller.loadUrl(
                              urlRequest: URLRequest(
                                url: WebUri(_currentUrl),
                              ),
                            );
                          }
                          // Android: 启用 WebAuthn/PassKey 支持
                          if (io.Platform.isAndroid) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              const MethodChannel('com.fluxdo/webauthn')
                                  .invokeMethod('enableWebAuthentication');
                            });
                          }
                        },
                        onLoadStart: (controller, url) {
                          final urlString = url?.toString() ?? '';
                          // 新标签页的 about:blank 不算一次导航，否则快捷入口
                          // 会被一个空白页盖掉。
                          if (_currentUrl.isEmpty && _isBlankUrl(urlString)) {
                            return;
                          }
                          setState(() {
                            _navigationRevision += 1;
                            _historyStateSettled = false;
                            _isLoading = true;
                            _currentUrl = urlString;
                          });
                        },
                        onProgressChanged: (controller, progress) {
                          setState(() => _progress = progress / 100);
                        },
                        onLoadStop: (controller, url) async {
                          final revision = _navigationRevision;
                          setState(() => _isLoading = false);
                          // 无痕标签不把 WebView cookie 带回 jar
                          if (!_isPrivate) {
                            CookieStoreObserver.instance
                                .notifyExternalChange();
                          }
                          await WebViewSettings.injectScrollFix(controller);
                          final title = await controller.getTitle();
                          final canGoBack = await controller.canGoBack();
                          final canGoForward = await controller.canGoForward();
                          if (!mounted || revision != _navigationRevision) {
                            return;
                          }
                          final urlString = url?.toString();
                          if (_currentUrl.isEmpty && _isBlankUrl(urlString)) {
                            return;
                          }
                          setState(() {
                            _currentUrl = urlString ?? '';
                            _canGoBack = canGoBack;
                            _canGoForward = canGoForward;
                            _historyStateSettled = true;
                            if (title != null && title.isNotEmpty) {
                              _currentTitle = title;
                            }
                          });
                          if (widget.injectCss != null) {
                            await controller.injectCSSCode(
                              source: widget.injectCss!,
                            );
                          }
                          // 记录浏览历史（无痕标签只维护内存里的标签历史）
                          if (urlString != null && urlString.isNotEmpty) {
                            if (!_isPrivate) {
                              ref
                                  .read(webHistoryProvider.notifier)
                                  .record(urlString, _currentTitle);
                            }
                            _tabs.recordNavigation(
                              _tabId,
                              urlString,
                              title: _currentTitle,
                            );
                          }
                        },
                        onUpdateVisitedHistory:
                            (controller, url, isReload) async {
                              final revision = _navigationRevision;
                              final canGoBack = await controller.canGoBack();
                              final canGoForward =
                                  await controller.canGoForward();
                              if (!mounted ||
                                  revision != _navigationRevision) {
                                return;
                              }
                              final urlString = url?.toString();
                              if (_currentUrl.isEmpty && _isBlankUrl(urlString)) {
                                return;
                              }
                              setState(() {
                                _currentUrl = urlString ?? '';
                                _canGoBack = canGoBack;
                                _canGoForward = canGoForward;
                                _historyStateSettled = true;
                              });
                              if (urlString != null && urlString.isNotEmpty) {
                                _tabs.recordNavigation(
                                  _tabId,
                                  urlString,
                                  title: _currentTitle,
                                );
                              }
                            },
                        onTitleChanged: (controller, title) {
                          if (title != null && title.isNotEmpty) {
                            setState(() => _currentTitle = title);
                            _tabs.updateTitle(_tabId, title);
                          }
                        },
                        onDownloadStarting: (controller, request) {
                          final url = request.url.toString();
                          ref
                              .read(downloadProvider.notifier)
                              .startDownload(
                                url: url,
                                suggestedFilename:
                                    request.suggestedFilename,
                                mimeType: request.mimeType,
                                contentLength: request.contentLength,
                              );
                          return null;
                        },
                      ),
                      getController: () => _controller,
                    ),
                  ),
                  if (_currentUrl.isEmpty && _webViewSnapshot == null)
                    _buildNewTabPage(theme),
                  if (_webViewSnapshot != null)
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: Image.memory(
                          _webViewSnapshot!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: _buildBottomBar(
          theme,
          canGoBack: canGoBack,
          canGoForward: canGoForward,
        ),
      ),
    );
  }

  Widget _buildBottomBar(
    ThemeData theme, {
    required bool canGoBack,
    required bool canGoForward,
  }) {
    return BottomAppBar(
      padding: EdgeInsets.zero,
      height: 52,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            tooltip: context.l10n.webview_goBack,
            onPressed: canGoBack ? _goBack : null,
            icon: const Icon(Symbols.arrow_back_rounded),
          ),
          IconButton(
            tooltip: context.l10n.webview_goForward,
            onPressed: canGoForward ? _goForward : null,
            icon: const Icon(Symbols.arrow_forward_rounded),
          ),
          IconButton(
            tooltip: _isLoading ? '停止' : context.l10n.common_refresh,
            onPressed: _isLoading
                ? () => _controller?.stopLoading()
                : () => _controller?.reload(),
            icon: Icon(
              _isLoading ? Symbols.close_rounded : Symbols.refresh_rounded,
            ),
          ),
          IconButton(
            tooltip: '主页',
            onPressed: _goHome,
            icon: const Icon(Symbols.home_rounded),
          ),
          IconButton(
            tooltip: '分享',
            onPressed: _currentUrl.isEmpty ? null : _share,
            icon: const Icon(Symbols.share_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildNewTabPage(ThemeData theme) {
    final scope = BrowserScopeService.instance.mitmHosts;
    final bookmarks = ref.watch(webBookmarkProvider).take(6).toList();

    return Container(
      color: theme.colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 56, 24, 32),
        children: [
          Icon(
            _isPrivate
                ? Symbols.visibility_off_rounded
                : Symbols.public_rounded,
            size: 56,
            color: _isPrivate
                ? theme.colorScheme.tertiary
                : theme.colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            _isPrivate ? '无痕浏览' : 'cfbrowser',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            _isPrivate
                ? '不记录浏览历史，也不共享站点登录态'
                : '输入网址，或从下面的入口开始',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (bookmarks.isNotEmpty) ...[
            const SizedBox(height: 32),
            Text('书签', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final bookmark in bookmarks)
                  ActionChip(
                    avatar: const Icon(Symbols.star_rounded, size: 16),
                    label: Text(
                      bookmark.title.isEmpty
                          ? BrowserUrl.hostOf(bookmark.url)
                          : bookmark.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () => _navigateToUrl(bookmark.url),
                  ),
              ],
            ),
          ],
          if (scope.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('加速范围', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final host in scope)
                  ActionChip(
                    avatar: const Icon(Symbols.bolt_rounded, size: 16),
                    label: Text(host),
                    onPressed: () => _navigateToUrl('https://$host'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _goBack() async {
    final controller = _controller;
    if (controller == null) return;
    if (await controller.canGoBack()) {
      await controller.goBack();
      return;
    }
    final url = _tabs.stepBack(_tabId);
    if (url != null) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  Future<void> _goForward() async {
    final controller = _controller;
    if (controller == null) return;
    if (await controller.canGoForward()) {
      await controller.goForward();
      return;
    }
    final url = _tabs.stepForward(_tabId);
    if (url != null) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  void _goHome() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _share() async {
    if (_currentUrl.isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(text: _currentUrl, subject: _currentTitle),
      );
    } catch (e) {
      if (mounted) ToastService.showError('分享失败：$e');
    }
  }

  void _openLibrary() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MyBrowserPage()),
    );
  }

  void _switchToTab(BrowserTab tab) {
    if (tab.id == _tabId) return;
    _tabs.setActive(tab.id);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => WebViewPage(url: tab.url, tabId: tab.id),
      ),
    );
  }

  void _closeActiveTab() {
    final next = _tabs.close(_tabId);
    if (!mounted) return;
    if (next == null) {
      Navigator.of(context).pop();
    } else {
      _switchToTab(next);
    }
  }

  Future<void> _showTabs() async {
    await showBrowserTabsSheet(
      context,
      onSelect: (tab) {
        if (!mounted) return;
        _switchToTab(tab);
      },
      onClose: (tab) {
        if (!mounted) return;
        final next = _tabs.active;
        if (next == null) {
          Navigator.of(context).pop();
        } else {
          _switchToTab(next);
        }
      },
      onCloseAll: () {
        if (mounted) Navigator.of(context).pop();
      },
    );
  }

  Future<void> _showFindSheet() async {
    if (_currentUrl.isEmpty) return;
    if (!FindInteractionController.isClassSupported()) {
      ToastService.showError('当前平台不支持页内查找');
      return;
    }
    _findStatus.value = '';
    final textController = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.viewInsetsOf(sheetContext).bottom + 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: textController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: '在页面中查找',
                  prefixIcon: Icon(Symbols.find_in_page_rounded),
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  if (value.isEmpty) {
                    unawaited(_findController.clearMatches());
                    _findStatus.value = '';
                  } else {
                    unawaited(_findController.findAll(find: value));
                  }
                },
                onSubmitted: (_) =>
                    unawaited(_findController.findNext(forward: true)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  ValueListenableBuilder<String>(
                    valueListenable: _findStatus,
                    builder: (context, status, _) {
                      return Text(
                        status,
                        style: Theme.of(context).textTheme.bodySmall,
                      );
                    },
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '上一个',
                    onPressed: () =>
                        unawaited(_findController.findNext(forward: false)),
                    icon: const Icon(Symbols.keyboard_arrow_up_rounded),
                  ),
                  IconButton(
                    tooltip: '下一个',
                    onPressed: () =>
                        unawaited(_findController.findNext(forward: true)),
                    icon: const Icon(Symbols.keyboard_arrow_down_rounded),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    await _findController.clearMatches();
    _findStatus.value = '';
    textController.dispose();
  }

  Future<void> _toggleDesktopMode() async {
    final next = !_desktopMode;
    setState(() => _desktopMode = next);
    _tabs.setDesktopMode(_tabId, next);
    final controller = _controller;
    if (controller == null) return;
    await controller.setSettings(settings: _buildSettings());
    await controller.reload();
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'new_tab':
        _tabs.create();
        final tab = _tabs.active;
        if (tab != null && mounted) _switchToTab(tab);
        break;
      case 'new_private_tab':
        final tab = _tabs.create(isPrivate: true);
        if (mounted) _switchToTab(tab);
        break;
      case 'find':
        _showFindSheet();
        break;
      case 'toggle_desktop':
        _toggleDesktopMode();
        break;
      case 'toggle_bookmark':
        _toggleBookmark();
        break;
      case 'share':
        _share();
        break;
      case 'library':
        _openLibrary();
        break;
      case 'copy_url':
        _copyUrl();
        break;
      case 'open_external':
        _openInExternalBrowser();
        break;
      case 'home':
        _goHome();
        break;
    }
  }

  /// 允许 WebView 内部加载的 scheme
  static const _allowedSchemes = {'http', 'https', 'about', 'data', 'blob'};

  /// 拦截 URL 加载：对非 HTTP(S) 的应用链接弹出确认对话框
  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction navigationAction,
  ) async {
    final url = navigationAction.request.url;
    if (url == null) return NavigationActionPolicy.ALLOW;

    final scheme = url.scheme.toLowerCase();

    // HTTP(S) 和内部 scheme 正常加载
    if (_allowedSchemes.contains(scheme)) {
      return NavigationActionPolicy.ALLOW;
    }

    // javascript: 静默阻止
    if (scheme == 'javascript') {
      return NavigationActionPolicy.CANCEL;
    }

    // 应用自有 scheme 直接交给深链服务，避免授权回调被当成外部应用
    // 链接弹出确认框，或在 WebView 内导航失败。
    if (scheme == 'fluxdo' || scheme == 'discourse') {
      DeepLinkService.instance.handleUri(url);
      return NavigationActionPolicy.CANCEL;
    }

    // 其他 scheme（应用链接）：解析目标应用并弹出确认对话框
    final urlString = url.toString();
    if (!mounted) return NavigationActionPolicy.CANCEL;

    // 通过原生代码解析目标应用信息
    final appInfo = await AppLinkService.resolveAppLink(urlString);

    if (!mounted) return NavigationActionPolicy.CANCEL;

    final confirmed = await showAppLinkConfirmDialog(
      context,
      urlString,
      appName: appInfo.appName,
      appIcon: appInfo.appIcon,
    );

    if (confirmed == true) {
      final success = await AppLinkService.launchAppLink(urlString);
      if (!success && mounted) {
        ToastService.showError(S.current.webview_noAppForLink);
      }
    }

    // 无论用户选择如何，都不让 WebView 加载此 URL
    return NavigationActionPolicy.CANCEL;
  }

  /// 弹出 URL 输入对话框。
  ///
  /// 为避免 BackdropFilter 对实时 WebView 做高斯模糊导致的掉帧，
  /// 先截图盖在 WebView 之上，让对话框模糊的是静态图像。
  /// 截图覆盖后 WebView 也不再持有 InputConnection，键盘可立即弹出。
  Future<void> _showUrlInput() async {
    final snapshot = await _controller?.takeScreenshot();
    if (!mounted) return;
    if (snapshot != null) {
      setState(() => _webViewSnapshot = snapshot);
    }

    final textController = TextEditingController(text: _currentUrl);
    final focusNode = FocusNode();
    try {
      await showAppDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.current.webview_inputUrl),
          content: TextField(
            controller: textController,
            focusNode: focusNode,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: '输入网址或搜索词',
              suffixIcon: IconButton(
                icon: const Icon(Symbols.clear_rounded, size: 18),
                onPressed: () => textController.clear(),
              ),
            ),
            onSubmitted: (value) {
              Navigator.pop(ctx);
              _navigateToUrl(value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(S.current.common_cancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _navigateToUrl(textController.text);
              },
              child: Text(S.current.webview_go),
            ),
          ],
        ),
      );
    } finally {
      focusNode.dispose();
      textController.dispose();
      if (mounted && _webViewSnapshot != null) {
        setState(() => _webViewSnapshot = null);
      }
    }
  }

  void _navigateToUrl(String input) {
    final url = BrowserUrl.normalize(input);
    if (url.isEmpty) return;
    final controller = _controller;
    if (controller == null) return;
    controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _toggleBookmark() {
    if (_currentUrl.isEmpty) return;
    final added = ref
        .read(webBookmarkProvider.notifier)
        .toggle(_currentUrl, _currentTitle);
    ToastService.showSuccess(
      added
          ? S.current.webview_bookmarkAdded
          : S.current.webview_bookmarkRemoved,
    );
  }

  Future<void> _handleBackNavigation() async {
    final controller = _controller;
    if (controller == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (await controller.canGoBack()) {
      await controller.goBack();
      return;
    }
    final tab = _tabs.byId(_tabId);
    if (tab?.canGoBack == true) {
      await _goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copyUrl() async {
    if (_currentUrl.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: _currentUrl));
      if (mounted) {
        ToastService.showSuccess(S.current.common_linkCopied);
      }
    }
  }

  Future<void> _openInExternalBrowser() async {
    if (_currentUrl.isEmpty) return;

    try {
      final success = await launchInExternalBrowser(_currentUrl);
      if (!success && mounted) {
        ToastService.showError(S.current.webview_cannotOpenBrowser);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.webview_openFailed(e.toString()));
      }
    }
  }
}
