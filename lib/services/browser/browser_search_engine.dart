import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 地址栏搜索词使用的搜索引擎。
///
/// 只放国内可直连或用户常备的几家，避免把需要额外网络条件的服务设成默认。
/// 模板里的 `{query}` 会被 URL 编码后的关键词替换。
enum BrowserSearchEngine {
  bing('Bing', 'https://www.bing.com/search?q={query}'),
  baidu('百度', 'https://www.baidu.com/s?wd={query}'),
  google('Google', 'https://www.google.com/search?q={query}'),
  duckduckgo('DuckDuckGo', 'https://duckduckgo.com/?q={query}'),
  sogou('搜狗', 'https://www.sogou.com/web?query={query}');

  const BrowserSearchEngine(this.label, this.template);

  final String label;
  final String template;

  static BrowserSearchEngine fromName(String? name) {
    for (final engine in values) {
      if (engine.name == name) return engine;
    }
    return bing;
  }
}

/// 搜索引擎选择的持久化与读取。
///
/// 地址栏归一化、首页搜索框和新标签页都从这里取模板，保证三处一致。
class BrowserSearchEngineService {
  BrowserSearchEngineService._();

  static final BrowserSearchEngineService instance =
      BrowserSearchEngineService._();

  static const String _storageKey = 'browser_search_engine_v1';

  final ValueNotifier<BrowserSearchEngine> current =
      ValueNotifier<BrowserSearchEngine>(BrowserSearchEngine.bing);

  SharedPreferences? _prefs;

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    current.value = BrowserSearchEngine.fromName(prefs.getString(_storageKey));
  }

  /// 当前模板，直接传给 `BrowserUrl.normalize(template: ...)`。
  String get template => current.value.template;

  Future<void> select(BrowserSearchEngine engine) async {
    if (current.value == engine) return;
    current.value = engine;
    await _prefs?.setString(_storageKey, engine.name);
  }

  /// 仅测试用：清空内存与持久化句柄。
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    current.value = BrowserSearchEngine.bing;
  }
}
