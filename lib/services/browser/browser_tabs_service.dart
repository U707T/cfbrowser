import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/browser_tab.dart';

/// 全局标签页状态。
///
/// 只保存「地址 + URL 级历史」，不持有 WebView 控制器。WebViewPage 在
/// 切标签时用 [BrowserTab.url] 重建页面，后退/前进先走 WebView 自己的
/// 历史，走不通时再用这里的历史补位。
class BrowserTabsService {
  BrowserTabsService._();

  static final BrowserTabsService instance = BrowserTabsService._();

  static const String _tabsKey = 'browser_tabs_v1';
  static const String _activeKey = 'browser_tabs_active_v1';

  /// 每个标签最多保留的 URL 历史条数，防止长期浏览把 prefs 撑大。
  static const int maxHistoryPerTab = 100;

  /// 标签总数上限。超过时关闭最早的非当前标签，避免无上限增长。
  static const int maxTabs = 50;

  final ValueNotifier<List<BrowserTab>> tabs =
      ValueNotifier<List<BrowserTab>>(const <BrowserTab>[]);

  final ValueNotifier<String?> activeTabId = ValueNotifier<String?>(null);

  SharedPreferences? _prefs;
  int _idSequence = 0;

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    final raw = prefs.getString(_tabsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final restored = <BrowserTab>[];
          for (final item in decoded) {
            if (item is! Map) continue;
            final tab = BrowserTab.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            );
            if (tab.id.isEmpty || tab.isPrivate) continue;
            restored.add(tab);
          }
          if (restored.isNotEmpty) {
            tabs.value = List<BrowserTab>.unmodifiable(restored);
          }
        }
      } catch (e) {
        debugPrint('[BrowserTabs] 恢复标签页失败: $e');
      }
    }
    final storedActive = prefs.getString(_activeKey);
    final active = storedActive == null ? null : byId(storedActive);
    activeTabId.value = active?.id ?? (tabs.value.isEmpty ? null : tabs.value.first.id);
  }

  BrowserTab? byId(String id) {
    for (final tab in tabs.value) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  BrowserTab? get active {
    final id = activeTabId.value;
    return id == null ? null : byId(id);
  }

  /// 新建标签页。空 [url] 表示新标签页（显示快捷入口）。
  BrowserTab create({
    String url = '',
    String title = '',
    bool isPrivate = false,
    bool desktopMode = false,
  }) {
    final cleanUrl = url.trim();
    final history = _isWebUrl(cleanUrl)
        ? <String>[cleanUrl]
        : const <String>[];
    final tab = BrowserTab(
      id: _nextId(),
      url: cleanUrl,
      title: title.trim(),
      history: history,
      historyIndex: history.isEmpty ? -1 : 0,
      updatedAt: DateTime.now(),
      isPrivate: isPrivate,
      desktopMode: desktopMode,
    );

    final list = <BrowserTab>[...tabs.value];
    // 超过上限时先关掉最早的非当前标签，保持行为可预期。
    while (list.length >= maxTabs && list.isNotEmpty) {
      final victim = list.firstWhere(
        (item) => item.id != activeTabId.value,
        orElse: () => list.first,
      );
      list.remove(victim);
    }
    list.add(tab);
    _emit(list);
    activeTabId.value = tab.id;
    _persist();
    return tab;
  }

  void setActive(String? id) {
    if (id != null && byId(id) == null) return;
    if (activeTabId.value == id) return;
    activeTabId.value = id;
    _persist();
  }

  /// 关闭标签页，返回关闭后应当展示的标签（没有则为 null）。
  BrowserTab? close(String id) {
    final list = <BrowserTab>[...tabs.value];
    final index = list.indexWhere((tab) => tab.id == id);
    if (index < 0) return active;
    final wasActive = activeTabId.value == id;
    list.removeAt(index);
    _emit(list);
    if (list.isEmpty) {
      activeTabId.value = null;
      _persist();
      return null;
    }
    if (wasActive) {
      final next = list[index.clamp(0, list.length - 1).toInt()];
      activeTabId.value = next.id;
      _persist();
      return next;
    }
    _persist();
    return active;
  }

  void closeAll() {
    _emit(const <BrowserTab>[]);
    activeTabId.value = null;
    _persist();
  }

  void updateTitle(String id, String title) {
    final clean = title.trim();
    if (clean.isEmpty) return;
    final index = _indexOf(id);
    if (index < 0) return;
    final tab = tabs.value[index];
    if (tab.title == clean) return;
    _replaceAt(index, tab.copyWith(title: clean, updatedAt: DateTime.now()));
  }

  void setDesktopMode(String id, bool enabled) {
    final index = _indexOf(id);
    if (index < 0) return;
    final tab = tabs.value[index];
    if (tab.desktopMode == enabled) return;
    _replaceAt(
      index,
      tab.copyWith(desktopMode: enabled, updatedAt: DateTime.now()),
    );
  }

  /// 记录一次页面导航，同时同步标签的 URL 级历史。
  void recordNavigation(String id, String url, {String? title}) {
    final index = _indexOf(id);
    if (index < 0) return;
    final tab = tabs.value[index];
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return;

    if (!_isWebUrl(cleanUrl)) {
      final cleanTitle = title?.trim() ?? '';
      if (cleanTitle.isNotEmpty && cleanTitle != tab.title) {
        _replaceAt(
          index,
          tab.copyWith(title: cleanTitle, updatedAt: DateTime.now()),
        );
      }
      return;
    }

    final history = <String>[...tab.history];
    var historyIndex = tab.historyIndex;

    if (history.isEmpty || historyIndex < 0) {
      history.add(cleanUrl);
      historyIndex = 0;
    } else if (history[historyIndex] == cleanUrl) {
      // 同一页面：标题可能后到，历史不动。
    } else {
      final existing = history.lastIndexOf(cleanUrl);
      if (existing >= 0) {
        // WebView 自身的后退/前进，或页面跳回历史项。
        historyIndex = existing;
      } else {
        // 从当前项之后截断，再追加新页面。
        history.removeRange(historyIndex + 1, history.length);
        history.add(cleanUrl);
        historyIndex = history.length - 1;
      }
    }

    if (history.length > maxHistoryPerTab) {
      final drop = history.length - maxHistoryPerTab;
      history.removeRange(0, drop);
      historyIndex = (historyIndex - drop).clamp(0, history.length - 1).toInt();
    }

    final urlChanged = tab.url != cleanUrl;
    final nextTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : (urlChanged ? '' : tab.title);
    _replaceAt(
      index,
      tab.copyWith(
        url: cleanUrl,
        title: nextTitle,
        history: List<String>.unmodifiable(history),
        historyIndex: historyIndex,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// WebView 没有后退历史时，用标签自己的 URL 历史补位。
  String? stepBack(String id) {
    final index = _indexOf(id);
    if (index < 0) return null;
    final tab = tabs.value[index];
    if (!tab.canGoBack) return null;
    final nextIndex = tab.historyIndex - 1;
    final url = tab.history[nextIndex];
    _replaceAt(
      index,
      tab.copyWith(
        url: url,
        title: '',
        historyIndex: nextIndex,
        updatedAt: DateTime.now(),
      ),
    );
    return url;
  }

  String? stepForward(String id) {
    final index = _indexOf(id);
    if (index < 0) return null;
    final tab = tabs.value[index];
    if (!tab.canGoForward) return null;
    final nextIndex = tab.historyIndex + 1;
    final url = tab.history[nextIndex];
    _replaceAt(
      index,
      tab.copyWith(
        url: url,
        title: '',
        historyIndex: nextIndex,
        updatedAt: DateTime.now(),
      ),
    );
    return url;
  }

  /// 仅测试用：清空内存与持久化句柄，让 initialize 可以重新执行。
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    tabs.value = const <BrowserTab>[];
    activeTabId.value = null;
    _idSequence = 0;
  }

  int _indexOf(String id) {
    return tabs.value.indexWhere((tab) => tab.id == id);
  }

  void _replaceAt(int index, BrowserTab tab) {
    final list = <BrowserTab>[...tabs.value];
    list[index] = tab;
    _emit(list);
  }

  void _emit(List<BrowserTab> list) {
    tabs.value = List<BrowserTab>.unmodifiable(list);
    _persist();
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    final persisted = tabs.value.where((tab) => !tab.isPrivate).toList();
    unawaited(prefs.setString(_tabsKey, jsonEncode(
      persisted.map((tab) => tab.toJson()).toList(),
    )));
    final active = activeTabId.value;
    final activeTab = active == null ? null : byId(active);
    if (activeTab == null || activeTab.isPrivate) {
      unawaited(prefs.remove(_activeKey));
    } else {
      unawaited(prefs.setString(_activeKey, activeTab.id));
    }
  }

  String _nextId() {
    _idSequence = (_idSequence + 1) % 0x10000;
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'tab-$now-${_idSequence.toRadixString(36)}';
  }

  static bool _isWebUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }
}
