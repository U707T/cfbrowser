/// 地址栏输入归一化。
///
/// 浏览器地址栏要同时处理三种输入：
/// - 完整 URL（`https://example.com/a`）
/// - 省略 scheme 的域名（`example.com`、`localhost:3000`）
/// - 搜索词（`flutter webview`）
class BrowserUrl {
  BrowserUrl._();

  /// 默认搜索。Bing 在国内可直连，且不像 Google 那样需要额外网络条件。
  static const String searchTemplate = 'https://www.bing.com/search?q={query}';

  static final RegExp _schemePattern = RegExp(
    r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
  );
  static final RegExp _hostPattern = RegExp(
    r'^[a-zA-Z0-9.-]+(:\d+)?(/.*)?$',
  );

  /// 把地址栏输入变成可加载的 URL；空输入返回空字符串。
  static String normalize(String raw, {String template = searchTemplate}) {
    final value = raw.trim();
    if (value.isEmpty) return '';

    if (_schemePattern.hasMatch(value)) return value;
    if (value.startsWith('about:') || value.startsWith('data:')) return value;

    final looksLikeHost = _hostPattern.hasMatch(value) &&
        (value.contains('.') || value.startsWith('localhost'));
    if (looksLikeHost) return 'https://$value';

    return template.replaceFirst('{query}', Uri.encodeQueryComponent(value));
  }

  /// 显示用 host；解析失败时回退到原串。
  static String hostOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host;
  }

  static bool isWebUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }
}
