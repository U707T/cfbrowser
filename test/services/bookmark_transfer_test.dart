import 'package:cfbrowser/models/web_bookmark.dart';
import 'package:cfbrowser/services/browser/bookmark_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final created = DateTime(2026, 11, 23, 10, 30);

  WebBookmark item(String url, String title, [DateTime? at]) =>
      WebBookmark(url: url, title: title, createdAt: at ?? created);

  group('导出', () {
    test('HTML 是 Netscape 书签格式，属性与文本都转义', () {
      final html = BookmarkTransfer.exportHtml([
        item('https://example.com/a?x=1&y=2', 'A & B <tag>'),
        item('https://example.org/', ''),
      ]);

      expect(html, startsWith('<!DOCTYPE NETSCAPE-Bookmark-file-1>'));
      expect(html, contains('HREF="https://example.com/a?x=1&amp;y=2"'));
      expect(html, contains('>A &amp; B &lt;tag&gt;</A>'));
      // 空标题回落到域名，不会出现空的 <A> 标签
      expect(html, contains('>example.org</A>'));
      expect(html, contains('ADD_DATE="${created.millisecondsSinceEpoch ~/ 1000}"'));
      expect(html, endsWith('</DL><p>\n'));
    });

    test('JSON 带格式标识与版本，可再被自己解析', () {
      final json = BookmarkTransfer.exportJson([item('https://a.test/', '甲')]);
      expect(json, contains('"format": "cfbrowser-bookmarks"'));
      expect(json, contains('"version": 1'));
      final parsed = BookmarkTransfer.parseJson(json);
      expect(parsed.single.url, 'https://a.test/');
      expect(parsed.single.title, '甲');
      expect(parsed.single.createdAt, created);
    });
  });

  group('导入', () {
    test('解析浏览器导出的书签 HTML：忽略文件夹、内部链接与重复项', () {
      const html = '''
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
  <DT><H3>工具栏</H3>
  <DL><p>
    <DT><A HREF="https://one.test/a" ADD_DATE="1700000000">第一个</A>
    <DT><A HREF="https://one.test/a" ADD_DATE="1700000001">重复</A>
    <DT><A HREF="javascript:alert(1)">脚本</A>
    <DT><A HREF="chrome://settings">内部页</A>
    <DT><A HREF="https://two.test/" >第二个</A>
  </DL><p>
</DL><p>
''';
      final result = BookmarkTransfer.parse(html, fileName: 'bookmarks.html');
      expect(result.map((e) => e.url), [
        'https://one.test/a',
        'https://two.test/',
      ]);
      expect(result.first.title, '第一个');
      expect(result.first.createdAt.millisecondsSinceEpoch, 1700000000000);
      // 没有 ADD_DATE 时用当前时间兜底，不能丢条目
      expect(
        result.last.createdAt.isAfter(DateTime(2000)),
        isTrue,
      );
    });

    test('JSON 备份与裸数组都能导入，坏条目被跳过', () {
      final backup = BookmarkTransfer.exportJson([
        item('https://keep.test/', '保留'),
        item('https://drop.test/', '会被去重'),
      ]);
      expect(BookmarkTransfer.parse(backup).map((e) => e.url), [
        'https://keep.test/',
        'https://drop.test/',
      ]);

      const raw = '''
[
  {"url": "https://a.test/", "title": "A"},
  {"url": "https://a.test/", "title": "A2"},
  {"url": "ftp://b.test/", "title": "FTP"},
  {"title": "没有地址"},
  "字符串"
]
''';
      final parsed = BookmarkTransfer.parse(raw);
      expect(parsed.map((e) => e.url), ['https://a.test/']);
      expect(parsed.single.title, 'A');
    });

    test('空内容与无法识别的格式返回空列表，不抛异常', () {
      expect(BookmarkTransfer.parse(''), isEmpty);
      expect(BookmarkTransfer.parse('   '), isEmpty);
      expect(BookmarkTransfer.parse('{坏的 json'), isEmpty);
      expect(BookmarkTransfer.parseHtml('<html><body>没有链接</body></html>'), isEmpty);
    });

    test('导入条数有上限，避免超大文件卡住界面', () {
      final buffer = StringBuffer('<DL><p>\n');
      for (var i = 0; i <= BookmarkTransfer.maxImportItems + 5; i++) {
        buffer.writeln('<DT><A HREF="https://n$i.test/">n$i</A>');
      }
      buffer.writeln('</DL><p>');
      final parsed = BookmarkTransfer.parseHtml(buffer.toString());
      expect(parsed.length, BookmarkTransfer.maxImportItems);
    });
  });
}
