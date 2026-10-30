import 'package:cfbrowser/services/browser/browser_quick_links_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = BrowserQuickLinksService.instance;

  Future<void> init([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    service.resetForTest();
    await service.initialize(await SharedPreferences.getInstance());
  }

  setUp(init);

  tearDown(() => service.resetForTest());

  test('首次启动给默认快捷访问', () async {
    await init();
    expect(service.links.value.length, 3);
    expect(
      service.links.value.map((item) => item.url),
      containsAll(<String>['https://linux.do', 'https://www.bing.com', 'https://github.com']),
    );
  });

  test('添加自定义网址会自动补全 https 并去重', () async {
    await init();
    final link = service.add(url: 'example.com', title: '示例');
    expect(link, isNotNull);
    expect(link!.url, 'https://example.com');
    expect(link.title, '示例');

    service.add(url: 'https://example.com', title: '新名字');
    expect(
      service.links.value.where((item) => item.url == 'https://example.com').length,
      1,
    );
    expect(
      service.links.value.firstWhere((item) => item.url == 'https://example.com').title,
      '新名字',
    );
  });

  test('编辑与删除', () async {
    await init();
    final link = service.add(url: 'example.com')!;
    service.update(link.id, url: 'https://example.org', title: 'Org');
    expect(service.links.value.last.url, 'https://example.org');
    expect(service.links.value.last.title, 'Org');

    service.remove(link.id);
    expect(service.links.value.any((item) => item.id == link.id), isFalse);
  });

  test('持久化恢复，且空列表不会被默认项重新灌回', () async {
    await init();
    service.add(url: 'example.com', title: '示例');
    await Future<void>.delayed(Duration.zero);

    service.resetForTest();
    await service.initialize(await SharedPreferences.getInstance());
    expect(
      service.links.value.any((item) => item.url == 'https://example.com'),
      isTrue,
    );

    await init({'browser_quick_links_v1': '[]'});
    expect(service.links.value, isEmpty);
  });

  test('超过上限时拒绝新增', () async {
    await init();
    for (var i = 0; i < BrowserQuickLinksService.maxLinks - 3; i++) {
      expect(service.add(url: 'https://example.com/$i'), isNotNull);
    }
    expect(service.links.value.length, BrowserQuickLinksService.maxLinks);
    expect(service.add(url: 'https://example.com/overflow'), isNull);
  });
}
