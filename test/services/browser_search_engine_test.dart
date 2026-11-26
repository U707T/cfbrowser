import 'package:cfbrowser/services/browser/browser_search_engine.dart';
import 'package:cfbrowser/services/browser/browser_url.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    BrowserSearchEngineService.instance.resetForTest();
  });

  tearDown(BrowserSearchEngineService.instance.resetForTest);

  test('默认 Bing；选择后写盘并在重启后恢复', () async {
    final service = BrowserSearchEngineService.instance;
    await service.initialize(await SharedPreferences.getInstance());
    expect(service.current.value, BrowserSearchEngine.bing);

    await service.select(BrowserSearchEngine.baidu);
    await service.initialize(await SharedPreferences.getInstance());
    expect(service.template, BrowserSearchEngine.baidu.template);

    service.resetForTest();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('browser_search_engine_v1'), 'baidu');
    await service.initialize(prefs);
    expect(service.current.value, BrowserSearchEngine.baidu);
  });

  test('未知或缺失的存储值回退 Bing，不抛异常', () async {
    SharedPreferences.setMockInitialValues({
      'browser_search_engine_v1': '不存在的引擎',
    });
    final service = BrowserSearchEngineService.instance;
    await service.initialize(await SharedPreferences.getInstance());
    expect(service.current.value, BrowserSearchEngine.bing);
  });

  test('地址栏归一化使用选中的模板，关键词被正确编码', () async {
    final service = BrowserSearchEngineService.instance;
    await service.initialize(await SharedPreferences.getInstance());
    await service.select(BrowserSearchEngine.duckduckgo);

    final url = BrowserUrl.normalize(
      'flutter 网页 搜索',
      template: service.template,
    );
    expect(url, startsWith('https://duckduckgo.com/?q='));
    expect(url, contains(Uri.encodeQueryComponent('flutter 网页 搜索')));

    // 输入网址时不受模板影响
    expect(
      BrowserUrl.normalize('example.com', template: service.template),
      'https://example.com',
    );
  });
}
