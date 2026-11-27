import 'dart:async';
import 'dart:convert';

import 'package:cfbrowser/models/web_bookmark.dart';
import 'package:cfbrowser/providers/web_bookmark_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'https://example.com/page';
  const otherUrl = 'https://example.org/';
  late SharedPreferences prefs;

  WebBookmark sample(String address) => WebBookmark(
    url: address,
    title: '原始标题',
    createdAt: DateTime(2026, 11, 23),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('收藏和删除写盘后重新读取；改名保留顺序与时间', () async {
    final bookmarks = WebBookmarkNotifier(prefs);
    await bookmarks.add(sample(url));
    await bookmarks.add(sample(otherUrl));
    await bookmarks.rename(url, '新标题');
    await prefs.reload();
    final restored = WebBookmarkNotifier(prefs);
    expect(restored.isBookmarked(url), isTrue);
    final items = (jsonDecode(prefs.getString('web_bookmarks')!) as List);
    expect(items.map((entry) => entry['url']), [otherUrl, url]);
    expect(items.last['title'], '新标题');
    expect(items.last['createdAt'], sample(url).createdAt.toIso8601String());
    expect(await restored.toggle(url, ''), isFalse);
    await prefs.reload();
    expect(WebBookmarkNotifier(prefs).isBookmarked(url), isFalse);
  });

  test('单个坏条目不会掩盖可读收藏；不可收藏无效页面', () async {
    await prefs.setString(
      'web_bookmarks',
      jsonEncode([{}, sample(url).toJson()]),
    );
    final bookmarks = WebBookmarkNotifier(prefs);
    expect(bookmarks.isBookmarked(url), isTrue);
    for (final invalid in ['about:blank', 'https://', 'https:path']) {
      await expectLater(bookmarks.toggle(invalid, ''), throwsFormatException);
    }
    expect(bookmarks.isBookmarked(url), isTrue);
  });

  test('并发写入按顺序完成，失败不提交可见状态', () async {
    final first = Completer<bool>();
    final writes = <List>[];
    final bookmarks = WebBookmarkNotifier(
      prefs,
      write: (value) async {
        writes.add(jsonDecode(value) as List);
        return writes.length == 1 ? await first.future : true;
      },
    );
    final failed = expectLater(bookmarks.toggle(url, '未保存'), throwsStateError);
    final saved = bookmarks.toggle(otherUrl, '保存');
    expect(writes, hasLength(1));
    expect(bookmarks.isBookmarked(url), isFalse);
    first.complete(false);
    await failed;
    expect(await saved, isTrue);
    expect(bookmarks.isBookmarked(url), isFalse);
    expect(bookmarks.isBookmarked(otherUrl), isTrue);
    expect(writes.last, hasLength(1));
  });

  test('导入合并只追加新网址，替换则整体覆盖并去重', () async {
    final bookmarks = WebBookmarkNotifier(prefs);
    await bookmarks.add(sample(url));
    await bookmarks.rename(url, '我的标题');

    final added = await bookmarks.importBookmarks([
      sample(url),
      sample(otherUrl),
      sample('about:blank'),
    ]);
    // 已有网址不覆盖用户改过的标题；无效地址被丢弃
    expect(added, 1);
    expect(
      bookmarks.state.map((item) => item.url),
      [url, otherUrl],
    );
    expect(bookmarks.state.first.title, '我的标题');
    await prefs.reload();
    expect(
      (jsonDecode(prefs.getString('web_bookmarks')!) as List).length,
      2,
    );

    await bookmarks.replaceAll([sample(otherUrl), sample(otherUrl)]);
    expect(bookmarks.state.map((item) => item.url), [otherUrl]);
    await prefs.reload();
    expect(WebBookmarkNotifier(prefs).state.single.url, otherUrl);
  });
}
