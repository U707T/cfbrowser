import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'browser_url.dart';

/// 浏览器首页的快捷访问项（Via 风格）。
@immutable
class BrowserQuickLink {
  const BrowserQuickLink({
    required this.id,
    required this.url,
    required this.title,
    required this.createdAt,
  });

  final String id;
  final String url;
  final String title;
  final DateTime createdAt;

  String get host => Uri.tryParse(url)?.host ?? url;

  String get displayTitle {
    final value = title.trim();
    if (value.isNotEmpty) return value;
    final h = host;
    return h.isEmpty ? url : h;
  }

  BrowserQuickLink copyWith({String? url, String? title}) {
    return BrowserQuickLink(
      id: id,
      url: url ?? this.url,
      title: title ?? this.title,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'url': url,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
  };

  factory BrowserQuickLink.fromJson(Map<String, dynamic> json) {
    return BrowserQuickLink(
      id: json['id'] as String? ?? '',
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// 快捷访问持久化。默认给几个可直接用的入口，用户可增删改。
class BrowserQuickLinksService {
  BrowserQuickLinksService._();

  static final BrowserQuickLinksService instance =
      BrowserQuickLinksService._();

  static const String _storageKey = 'browser_quick_links_v1';
  static const int maxLinks = 12;

  final ValueNotifier<List<BrowserQuickLink>> links =
      ValueNotifier<List<BrowserQuickLink>>(const <BrowserQuickLink>[]);

  SharedPreferences? _prefs;
  int _sequence = 0;

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    final raw = prefs.getString(_storageKey);
    if (raw == null) {
      links.value = _defaults();
      _persist();
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final restored = <BrowserQuickLink>[];
        for (final item in decoded) {
          if (item is! Map) continue;
          final link = BrowserQuickLink.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          );
          if (link.id.isEmpty || link.url.isEmpty) continue;
          restored.add(link);
        }
        links.value = List<BrowserQuickLink>.unmodifiable(restored);
      }
    } catch (e) {
      debugPrint('[QuickLinks] 恢复快捷访问失败: $e');
    }
  }

  /// 仅测试用：清空内存与持久化句柄。
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    links.value = const <BrowserQuickLink>[];
    _sequence = 0;
  }

  BrowserQuickLink? add({required String url, String? title}) {
    final normalized = BrowserUrl.normalize(url);
    if (normalized.isEmpty) return null;
    final existing = links.value.where((item) => item.url == normalized);
    if (existing.isNotEmpty) {
      update(existing.first.id, title: title);
      return existing.first;
    }
    if (links.value.length >= maxLinks) return null;
    final link = BrowserQuickLink(
      id: _nextId(),
      url: normalized,
      title: _normalizeTitle(title, normalized),
      createdAt: DateTime.now(),
    );
    links.value = List<BrowserQuickLink>.unmodifiable([
      ...links.value,
      link,
    ]);
    _persist();
    return link;
  }

  void update(String id, {String? url, String? title}) {
    final index = links.value.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final current = links.value[index];
    final normalizedUrl = url == null
        ? current.url
        : BrowserUrl.normalize(url);
    if (normalizedUrl.isEmpty) return;
    final nextTitle = title == null
        ? current.title
        : _normalizeTitle(title, normalizedUrl);
    final list = <BrowserQuickLink>[...links.value];
    list[index] = current.copyWith(url: normalizedUrl, title: nextTitle);
    links.value = List<BrowserQuickLink>.unmodifiable(list);
    _persist();
  }

  void remove(String id) {
    final list = links.value.where((item) => item.id != id).toList();
    if (list.length == links.value.length) return;
    links.value = List<BrowserQuickLink>.unmodifiable(list);
    _persist();
  }

  void resetToDefaults() {
    links.value = _defaults();
    _persist();
  }

  List<BrowserQuickLink> _defaults() {
    return <BrowserQuickLink>[
      _defaultLink('https://linux.do', 'Linux.do'),
      _defaultLink('https://www.bing.com', 'Bing'),
      _defaultLink('https://github.com', 'GitHub'),
    ];
  }

  BrowserQuickLink _defaultLink(String url, String title) {
    return BrowserQuickLink(
      id: _nextId(),
      url: url,
      title: title,
      createdAt: DateTime.now(),
    );
  }

  String _normalizeTitle(String? title, String url) {
    final value = title?.trim() ?? '';
    if (value.isNotEmpty) return value;
    final host = Uri.tryParse(url)?.host ?? url;
    if (host.isEmpty) return url;
    final stripped = host.startsWith('www.') ? host.substring(4) : host;
    return stripped;
  }

  String _nextId() {
    _sequence = (_sequence + 1) % 0x10000;
    return 'quick-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${_sequence.toRadixString(36)}';
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(
      prefs.setString(
        _storageKey,
        jsonEncode(links.value.map((item) => item.toJson()).toList()),
      ),
    );
  }
}
