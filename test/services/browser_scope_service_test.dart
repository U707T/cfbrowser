import 'package:cfbrowser/services/browser/browser_scope_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrowserScopeService.normalizeHost', () {
    test('粘贴完整 URL 时只保留主机名', () {
      expect(
        BrowserScopeService.normalizeHost('https://Linux.DO/t/1062697'),
        'linux.do',
      );
    });

    test('去掉通配前缀与端口', () {
      expect(BrowserScopeService.normalizeHost('*.linux.do:443'), 'linux.do');
    });

    test('非法输入返回 null', () {
      expect(BrowserScopeService.normalizeHost(''), isNull);
      expect(BrowserScopeService.normalizeHost('   '), isNull);
      expect(BrowserScopeService.normalizeHost('localhost'), isNull);
    });

    test('批量归一化会去重并保序', () {
      expect(
        BrowserScopeService.normalizeAll([
          'linux.do',
          'https://linux.do/',
          'example.com',
        ]),
        ['linux.do', 'example.com'],
      );
    });
  });

  group('BrowserScopeService 默认范围', () {
    test('默认仍是 linux.do', () {
      expect(BrowserScopeService.instance.mitmHosts, contains('linux.do'));
    });

    test('子域视为覆盖，相似域名不算', () {
      final service = BrowserScopeService.instance;
      expect(service.covers('cdn.linux.do'), isTrue);
      expect(service.covers('LINUX.DO'), isTrue);
      expect(service.covers('notlinux.do'), isFalse);
      expect(service.covers('linux.do.evil.test'), isFalse);
    });
  });
}
