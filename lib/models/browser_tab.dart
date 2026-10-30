/// 浏览器标签页。
///
/// cfbrowser 的标签页是「轻量级」的：不保持后台 WebView 常驻，只保存
/// 当前地址与一条 URL 级历史。切回标签页时用保存的地址重建 WebView，
/// 后退/前进优先走 WebView 自己的历史，走不通时再回落到这里的历史。
///
/// 这样做的代价是切标签会丢页面滚动位置和表单状态，收益是：
/// - 标签页数量不受 WebView 内存占用限制；
/// - 标签列表可以持久化，App 重启后仍能恢复；
/// - 不需要把 WebViewPage 重构成多 WebView 的 IndexedStack。
class BrowserTab {
  const BrowserTab({
    required this.id,
    required this.url,
    required this.title,
    required this.history,
    required this.historyIndex,
    required this.updatedAt,
    this.isPrivate = false,
    this.desktopMode = false,
  });

  final String id;
  final String url;
  final String title;

  /// URL 级历史，按访问顺序排列。
  final List<String> history;

  /// [history] 中当前所在的位置；空历史为 -1。
  final int historyIndex;

  final DateTime updatedAt;

  /// 无痕标签页：不写浏览历史、不灌入站点登录态，也不参与持久化。
  final bool isPrivate;

  /// 桌面版网站（覆盖 User-Agent）。
  final bool desktopMode;

  bool get canGoBack => historyIndex > 0 && history.isNotEmpty;

  bool get canGoForward =>
      historyIndex >= 0 && historyIndex < history.length - 1;

  String? get backUrl => canGoBack ? history[historyIndex - 1] : null;

  String? get forwardUrl => canGoForward ? history[historyIndex + 1] : null;

  /// 标签列表 / 地址栏里显示的标题。
  String get displayTitle {
    final trimmed = title.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final host = Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) return host;
    return isPrivate ? '无痕标签页' : '新标签页';
  }

  BrowserTab copyWith({
    String? url,
    String? title,
    List<String>? history,
    int? historyIndex,
    DateTime? updatedAt,
    bool? isPrivate,
    bool? desktopMode,
  }) {
    return BrowserTab(
      id: id,
      url: url ?? this.url,
      title: title ?? this.title,
      history: history ?? this.history,
      historyIndex: historyIndex ?? this.historyIndex,
      updatedAt: updatedAt ?? this.updatedAt,
      isPrivate: isPrivate ?? this.isPrivate,
      desktopMode: desktopMode ?? this.desktopMode,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'url': url,
      'title': title,
      'history': history,
      'historyIndex': historyIndex,
      'updatedAt': updatedAt.toIso8601String(),
      'isPrivate': isPrivate,
      'desktopMode': desktopMode,
    };
  }

  factory BrowserTab.fromJson(Map<String, dynamic> json) {
    final rawHistory = json['history'];
    final history = rawHistory is List
        ? rawHistory.whereType<String>().toList(growable: false)
        : const <String>[];
    final rawIndex = json['historyIndex'];
    final index = rawIndex is int
        ? rawIndex.clamp(-1, history.isEmpty ? -1 : history.length - 1).toInt()
        : (history.isEmpty ? -1 : history.length - 1);
    return BrowserTab(
      id: json['id'] as String? ?? '',
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      history: history,
      historyIndex: index,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      isPrivate: json['isPrivate'] as bool? ?? false,
      desktopMode: json['desktopMode'] as bool? ?? false,
    );
  }
}
