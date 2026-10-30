import 'package:cfbrowser/services/browser/browser_tabs_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = BrowserTabsService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service.resetForTest();
    await service.initialize(await SharedPreferences.getInstance());
  });

  tearDown(() => service.resetForTest());

  test('新建标签页时用初始地址初始化历史', () {
    final tab = service.create(url: 'https://example.com/a');
    expect(tab.history, <String>['https://example.com/a']);
    expect(tab.historyIndex, 0);
    expect(tab.canGoBack, isFalse);
    expect(tab.canGoForward, isFalse);
  });

  test('前进到新页面时追加历史，回退/前进只移动指针', () {
    final tab = service.create(url: 'https://example.com/a');
    service.recordNavigation(tab.id, 'https://example.com/b');

    var current = service.byId(tab.id)!;
    expect(current.history, <String>[
      'https://example.com/a',
      'https://example.com/b',
    ]);
    expect(current.historyIndex, 1);

    expect(service.stepBack(tab.id), 'https://example.com/a');
    current = service.byId(tab.id)!;
    expect(current.historyIndex, 0);
    expect(current.url, 'https://example.com/a');
    expect(current.canGoForward, isTrue);

    // 重建 WebView 后触发的 onUpdateVisitedHistory 不应再次追加
    service.recordNavigation(tab.id, 'https://example.com/a');
    expect(service.byId(tab.id)!.history.length, 2);

    expect(service.stepForward(tab.id), 'https://example.com/b');
    expect(service.byId(tab.id)!.historyIndex, 1);
  });

  test('从历史中间打开新页面会截断前进历史', () {
    final tab = service.create(url: 'https://example.com/a');
    service.recordNavigation(tab.id, 'https://example.com/b');
    service.stepBack(tab.id);
    service.recordNavigation(tab.id, 'https://example.com/c');

    final current = service.byId(tab.id)!;
    expect(current.history, <String>[
      'https://example.com/a',
      'https://example.com/c',
    ]);
    expect(current.historyIndex, 1);
    expect(current.canGoForward, isFalse);
  });

  test('关闭标签页会选中相邻标签', () {
    final first = service.create(url: 'https://example.com/1');
    final second = service.create(url: 'https://example.com/2');
    expect(service.activeTabId.value, second.id);

    final next = service.close(second.id);
    expect(next?.id, first.id);
    expect(service.tabs.value.length, 1);
  });

  test('无痕标签不写入持久化', () async {
    service.create(url: 'https://example.com/normal');
    service.create(url: 'https://example.com/secret', isPrivate: true);
    await Future<void>.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('browser_tabs_v1') ?? '';
    expect(raw, contains('https://example.com/normal'));
    expect(raw, isNot(contains('https://example.com/secret')));
  });

  test('从持久化恢复时丢弃无痕标签', () async {
    final normal = service.create(url: 'https://example.com/normal');
    service.create(url: 'https://example.com/secret', isPrivate: true);
    await Future<void>.delayed(Duration.zero);

    service.resetForTest();
    await service.initialize(await SharedPreferences.getInstance());

    expect(service.tabs.value.map((tab) => tab.id), contains(normal.id));
    expect(service.tabs.value.any((tab) => tab.isPrivate), isFalse);
  });
}
