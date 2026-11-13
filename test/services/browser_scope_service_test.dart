import 'package:cfbrowser/services/browser/browser_scope_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    test('默认是 linux.do 主站 + 静态资源域 ldstatic.com', () {
      expect(BrowserScopeService.defaultHosts, contains('linux.do'));
      expect(
        BrowserScopeService.defaultHosts,
        contains('ldstatic.com'),
        reason: '站内图片/表情/通知/直传都在 ldstatic.com 下（上游 23e0c32b）',
      );
      expect(
        BrowserScopeService.instance.mitmHosts,
        containsAll(BrowserScopeService.defaultHosts),
      );
    });

    test('子域视为覆盖，相似域名不算', () {
      final service = BrowserScopeService.instance;
      expect(service.covers('cdn.linux.do'), isTrue);
      expect(service.covers('LINUX.DO'), isTrue);
      expect(service.covers('notlinux.do'), isFalse);
      expect(service.covers('linux.do.evil.test'), isFalse);
    });
  });

  group('覆盖域名（钉住出口）', () {
    test('范围原样下发即可（子域由核心按后缀覆盖）', () {
      final covered = BrowserScopeService.instance.coveredHosts;
      expect(covered, containsAll(['linux.do', 'ldstatic.com']));
      // 不再手工枚举子域：核心 f584d0e 起 extra_covered_hosts 按子域后缀匹配
      expect(covered, isNot(contains('cdn.ldstatic.com')));
    });

    test('契约：范围里的每个域名都必须在覆盖域名里，否则只解密不加速', () {
      for (final host in BrowserScopeService.instance.mitmHosts) {
        expect(
          BrowserScopeService.instance.coveredHosts,
          contains(host),
          reason: '$host 在加速范围里但没有交给 Rust 当覆盖域名',
        );
      }
    });

    test('去掉 ldstatic.com 后不再下发它的子域主机', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final service = BrowserScopeService.instance;
      try {
        await service.setMitmHosts(['linux.do'], prefs: prefs);
        expect(service.coveredHosts, isNot(contains('cdn.ldstatic.com')));
      } finally {
        await service.setMitmHosts(BrowserScopeService.defaultHosts, prefs: prefs);
      }
    });
  });
}
