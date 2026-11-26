import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import '../models/web_bookmark.dart';
import '../services/browser/browser_url.dart';
import 'theme_provider.dart';

/// 网页收藏状态管理。所有修改顺序写入，写入成功才更新界面。
class WebBookmarkNotifier extends StateNotifier<List<WebBookmark>> {
  static const String _storageKey = 'web_bookmarks';

  final Future<bool> Function(String) _write;
  final Lock _writes = Lock();

  WebBookmarkNotifier(
    SharedPreferences prefs, {
    Future<bool> Function(String)? write,
  }) : _write = write ?? ((value) => prefs.setString(_storageKey, value)),
       super(_load(prefs));

  static List<WebBookmark> _load(SharedPreferences prefs) {
    final raw = prefs.get(_storageKey);
    if (raw is! String) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final urls = <String>{};
    return List.unmodifiable([
      for (final row in decoded)
        if (_readRow(row) case final item?)
          if (urls.add(item.url)) item,
    ]);
  }

  static WebBookmark? _readRow(Object? row) {
    if (row is! Map<String, dynamic>) return null;
    try {
      final item = WebBookmark.fromJson(row);
      return BrowserUrl.isWebUrl(item.url) ? item : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> add(WebBookmark item) => _writes.synchronized(() async {
    _validateUrl(item.url);
    await _commit([item, ...state.where((entry) => entry.url != item.url)]);
  });

  Future<void> removeByUrl(String url) => _writes.synchronized(() async {
    if (!isBookmarked(url)) return;
    await _commit(state.where((entry) => entry.url != url).toList());
  });

  Future<void> rename(String url, String title) =>
      _writes.synchronized(() async {
        if (!isBookmarked(url)) return;
        await _commit([
          for (final item in state)
            if (item.url == url)
              WebBookmark(url: url, title: title, createdAt: item.createdAt)
            else
              item,
        ]);
      });

  /// 合并导入结果，返回实际新增条数。
  ///
  /// 已存在的 URL 不覆盖（用户可能改过标题、或导入的是更旧的备份），
  /// 只追加新条目；顺序保持「先导入的在前」。
  Future<int> importBookmarks(List<WebBookmark> incoming) =>
      _writes.synchronized(() async {
        final existing = state.map((entry) => entry.url).toSet();
        final added = <WebBookmark>[];
        for (final item in incoming) {
          if (!BrowserUrl.isWebUrl(item.url)) continue;
          if (!existing.add(item.url)) continue;
          added.add(item);
        }
        if (added.isEmpty) return 0;
        await _commit(List.unmodifiable([...state, ...added]));
        return added.length;
      });

  /// 用完整备份替换现有收藏（用户确认后才会走到这里）。
  Future<void> replaceAll(List<WebBookmark> items) =>
      _writes.synchronized(() async {
        final seen = <String>{};
        final next = <WebBookmark>[];
        for (final item in items) {
          if (!BrowserUrl.isWebUrl(item.url)) continue;
          if (!seen.add(item.url)) continue;
          next.add(item);
        }
        await _commit(next);
      });

  bool isBookmarked(String url) => state.any((entry) => entry.url == url);

  /// 切换收藏状态，返回操作后是否为已收藏。
  Future<bool> toggle(String url, String title) =>
      _writes.synchronized(() async {
        _validateUrl(url);
        final exists = isBookmarked(url);
        await _commit([
          if (!exists)
            WebBookmark(url: url, title: title, createdAt: DateTime.now()),
          ...state.where((entry) => entry.url != url),
        ]);
        return !exists;
      });

  static void _validateUrl(String url) {
    if (!BrowserUrl.isWebUrl(url)) throw const FormatException('无效的网页地址');
  }

  Future<void> _commit(List<WebBookmark> next) async {
    final saved = await _write(
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
    if (!saved) throw StateError('无法保存网页收藏');
    if (mounted) state = List.unmodifiable(next);
  }
}

final webBookmarkProvider =
    StateNotifierProvider<WebBookmarkNotifier, List<WebBookmark>>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      return WebBookmarkNotifier(prefs);
    });
