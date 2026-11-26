import 'package:cfbrowser/services/update_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestUpdates extends UpdateService {
  _TestUpdates({super.dio, super.prefs});

  @override
  Future<String> getCurrentVersion() async => '1.2.1';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('只选择本产品发布的 arm64 安装包', () {
    expect(
      UpdateService.pickReleaseAbi(['armeabi-v7a', 'arm64-v8a']),
      'arm64-v8a',
    );
    expect(UpdateService.pickReleaseAbi(['armeabi-v7a']), isNull);
    expect(UpdateService.abiOfFileName('cfbrowser-arm64-v8a.apk'), 'arm64-v8a');
    expect(
      UpdateService.abiOfFileName('cfbrowser-1.2.2-arm64-v8a.apk'),
      'arm64-v8a',
    );
    expect(UpdateService.abiOfFileName('cfluxdo-1.3.4-arm64-v8a.apk'), isNull);
    expect(
      UpdateService.abiOfFileName('cfbrowser-arm64-v8a.apk.sha256'),
      isNull,
    );
    expect(UpdateService.abiOfFileName('cfbrowser-armeabi-v7a.apk'), isNull);
  });

  test('只有降级版本时不提示更新，桌面端不回落对应平台的安装包', () {
    expect(UpdateService.isNewerVersion('1.2.2', '1.2.2'), isFalse);
    expect(UpdateService.isNewerVersion('1.2.1', '1.2.2'), isFalse);
    expect(UpdateService.isNewerVersion('9.9.9', '1.2.2'), isTrue);
    expect(UpdateService.isNewerVersion('1.3.0-beta.2', '1.3.3'), isFalse);
    expect(UpdateService.isNewerVersion('v1.2.3', '1.2.2'), isTrue);
  });

  test('忽略旧发布缓存和 ETag，保留官方摘要，跳过其他应用的包', () async {
    SharedPreferences.setMockInitialValues({
      'update_cache':
          '{"currentVersion":"1.2.1","remoteVersion":"9.9.9",'
          '"releaseUrl":"https://example.com/old","releaseNotes":"",'
          '"hasUpdate":true}',
      'update_cache_time': DateTime.now().millisecondsSinceEpoch,
      'update_etag': 'upstream',
    });
    final prefs = await SharedPreferences.getInstance();
    final dio = Dio();
    addTearDown(dio.close);
    const base = 'https://github.com/U707T/cfbrowser/releases/download/v1.2.2';
    final digest = List.filled(64, 'A').join();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          expect(
            request.uri.toString(),
            'https://api.github.com/repos/U707T/cfbrowser/releases/latest',
          );
          expect(request.headers['If-None-Match'], isNull);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {
                'tag_name': 'v1.2.2',
                'html_url':
                    'https://github.com/U707T/cfbrowser/releases/tag/v1.2.2',
                'assets': [
                  {
                    'name': 'cfluxdo-arm64-v8a.apk',
                    'browser_download_url': '$base/cfluxdo-arm64-v8a.apk',
                  },
                  null,
                  {
                    'name': 'cfbrowser-arm64-v8a.apk',
                    'browser_download_url':
                        'https://example.org/cfbrowser-arm64-v8a.apk',
                  },
                  {
                    'name': 'cfbrowser-arm64-v8a.apk.sha256',
                    'browser_download_url':
                        '$base/cfbrowser-arm64-v8a.apk.sha256',
                  },
                  {
                    'name': 'cfbrowser-arm64-v8a.apk',
                    'browser_download_url': '$base/cfbrowser-arm64-v8a.apk',
                    'digest': 'sha256:$digest',
                  },
                ],
              },
            ),
          );
        },
      ),
    );

    final service = _TestUpdates(dio: dio, prefs: prefs);
    final update = await service.checkForUpdate(useCache: true);
    expect(update.hasUpdate, isTrue);
    expect(update.remoteVersion, '1.2.2');
    expect(update.apkAssets.single.name, 'cfbrowser-arm64-v8a.apk');
    expect(update.apkAssets.single.sha256, digest.toLowerCase());
    expect(
      (await service.checkForUpdate(useCache: true)).apkAssets.single.sha256,
      digest.toLowerCase(),
    );
    expect(
      UpdateService.pickApkAsset(['armeabi-v7a'], update.apkAssets),
      isNull,
    );
  });
}
