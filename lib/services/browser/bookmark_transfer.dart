import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../models/web_bookmark.dart';
import 'browser_url.dart';

/// 书签导入 / 导出。
///
/// 两种格式：
/// - **HTML**：Netscape Bookmark File，Chrome / Edge / Firefox / Safari 都能
///   直接导入，也是它们导出的默认格式；
/// - **JSON**：本应用自己的完整备份（保留收藏时间），用于迁移与恢复。
///
/// 解析只接受 `http` / `https` 地址，并按 URL 去重；`javascript:`、
/// `place:`、`chrome://` 之类浏览器内部链接一律丢弃，避免导入后点不动。
class BookmarkTransfer {
  BookmarkTransfer._();

  static const String jsonFormat = 'cfbrowser-bookmarks';
  static const int jsonVersion = 1;

  /// 一次导入最多接受的条数，防止误选超大文件把界面卡死。
  static const int maxImportItems = 5000;

  // ---------------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------------

  /// Netscape Bookmark File 文本。按当前顺序输出，时间取收藏时间。
  static String exportHtml(List<WebBookmark> bookmarks) {
    final buffer = StringBuffer()
      ..writeln('<!DOCTYPE NETSCAPE-Bookmark-file-1>')
      ..writeln('<!-- This is an automatically generated file.')
      ..writeln('     It will be read and overwritten.')
      ..writeln('     DO NOT EDIT! -->')
      ..writeln('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
      ..writeln('<TITLE>Bookmarks</TITLE>')
      ..writeln('<H1>Bookmarks</H1>')
      ..writeln('<DL><p>');
    for (final item in bookmarks) {
      final title = item.title.trim().isEmpty
          ? BrowserUrl.hostOf(item.url)
          : item.title.trim();
      final added = item.createdAt.millisecondsSinceEpoch ~/ 1000;
      buffer.writeln(
        '    <DT><A HREF="${_escapeAttribute(item.url)}" '
        'ADD_DATE="$added">${_escapeText(title)}</A>',
      );
    }
    buffer.writeln('</DL><p>');
    return buffer.toString();
  }

  /// 完整备份（JSON，带版本号）。
  static String exportJson(List<WebBookmark> bookmarks) {
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'format': jsonFormat,
      'version': jsonVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'bookmarks': [
        for (final item in bookmarks)
          <String, Object?>{
            'url': item.url,
            'title': item.title,
            'createdAt': item.createdAt.toIso8601String(),
          },
      ],
    });
  }

  // ---------------------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------------------

  /// 解析导入文件；[fileName] 只用来判断格式，内容本身决定成败。
  static List<WebBookmark> parse(String content, {String? fileName}) {
    final trimmed = content.trimLeft();
    final looksJson =
        (fileName?.toLowerCase().endsWith('.json') ?? false) ||
        trimmed.startsWith('{') ||
        trimmed.startsWith('[');
    return looksJson ? parseJson(trimmed) : parseHtml(content);
  }

  /// 解析 Netscape 书签 HTML。文件夹层级被忽略，只保留链接本身。
  static List<WebBookmark> parseHtml(String content) {
    if (content.trim().isEmpty) return const [];
    final dom.Document document;
    try {
      document = html_parser.parse(content);
    } catch (_) {
      return const [];
    }
    final seen = <String>{};
    final result = <WebBookmark>[];
    for (final anchor in document.querySelectorAll('a')) {
      final href = (anchor.attributes['href'] ?? '').trim();
      if (!BrowserUrl.isWebUrl(href)) continue;
      if (!seen.add(href)) continue;
      final title = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final added = int.tryParse(anchor.attributes['add_date'] ?? '');
      result.add(
        WebBookmark(
          url: href,
          title: title.isEmpty ? BrowserUrl.hostOf(href) : title,
          createdAt: added == null || added <= 0
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(added * 1000),
        ),
      );
      if (result.length >= maxImportItems) break;
    }
    return result;
  }

  /// 解析 JSON 备份；也接受裸数组（只含 `url` / `title`）。
  static List<WebBookmark> parseJson(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return const [];
    }
    final List<Object?> rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map && decoded['bookmarks'] is List) {
      rows = decoded['bookmarks'] as List<Object?>;
    } else {
      return const [];
    }
    final seen = <String>{};
    final result = <WebBookmark>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final url = (row['url'] as Object?)?.toString().trim() ?? '';
      if (!BrowserUrl.isWebUrl(url)) continue;
      if (!seen.add(url)) continue;
      final rawTitle = (row['title'] as Object?)?.toString().trim() ?? '';
      final createdAt = DateTime.tryParse(
        (row['createdAt'] as Object?)?.toString() ?? '',
      );
      result.add(
        WebBookmark(
          url: url,
          title: rawTitle.isEmpty ? BrowserUrl.hostOf(url) : rawTitle,
          createdAt: createdAt ?? DateTime.now(),
        ),
      );
      if (result.length >= maxImportItems) break;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 转义
  // ---------------------------------------------------------------------------

  static String _escapeText(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escapeAttribute(String value) =>
      _escapeText(value).replaceAll('"', '&quot;');
}
