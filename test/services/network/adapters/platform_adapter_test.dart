import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cfbrowser/services/network/adapters/platform_adapter.dart';

void main() {
  group('requestAllowsRhttpAdapter', () {
    RequestOptions buildOptions({
      ResponseType? responseType,
      Map<String, dynamic>? extra,
    }) {
      return RequestOptions(
        path: '/latest.json',
        baseUrl: 'https://linux.do',
        responseType: responseType,
        extra: extra ?? <String, dynamic>{},
      );
    }

    test('普通 API 请求允许走 rhttp', () {
      expect(requestAllowsRhttpAdapter(buildOptions()), isTrue);
    });

    test('stream 响应默认允许走 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(responseType: ResponseType.stream),
        ),
        isTrue,
      );
    });

    test('bytes 响应默认允许走 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(responseType: ResponseType.bytes),
        ),
        isTrue,
      );
    });

    test('显式 skipRhttpAdapter 时旁路 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(extra: {'skipRhttpAdapter': true}),
        ),
        isFalse,
      );
    });
  });

  group('forumReachabilityOf（VPN 让路时一直连不上就恢复加速）', () {
    ResponseBody body(int status, {String? gatewayError}) =>
        ResponseBody.fromString(
          '',
          status,
          headers: {
            if (gatewayError != null)
              'x-cfluxdo-gateway-error': [gatewayError],
          },
        );
    final options = RequestOptions(path: 'https://linux.do/latest.json');

    test('拿到任何 HTTP 响应都算连得上：挑战 403、源站 5xx 也一样', () {
      for (final viaGateway in [true, false]) {
        expect(forumReachabilityOf(viaGateway: viaGateway, body: body(200)), isTrue);
        expect(forumReachabilityOf(viaGateway: viaGateway, body: body(403)), isTrue);
        expect(forumReachabilityOf(viaGateway: viaGateway, body: body(502)), isTrue);
      }
    });

    test('本机网关回的 502 是网关连不上论坛；网关自己的 4xx 不算数', () {
      expect(
        forumReachabilityOf(
          viaGateway: true,
          body: body(502, gatewayError: 'Connection reset by peer'),
        ),
        isFalse,
      );
      expect(
        forumReachabilityOf(
          viaGateway: true,
          body: body(400, gatewayError: 'Missing Host header'),
        ),
        isNull,
      );
    });

    test('不经网关时连接出错、连接超时、握手失败都是连不上', () {
      expect(
        forumReachabilityOf(
          viaGateway: false,
          error: DioException.connectionError(
            requestOptions: options,
            reason: 'Connection reset by peer',
          ),
        ),
        isFalse,
      );
      expect(
        forumReachabilityOf(
          viaGateway: false,
          error: DioException.connectionTimeout(
            requestOptions: options,
            timeout: const Duration(seconds: 30),
          ),
        ),
        isFalse,
      );
      expect(
        forumReachabilityOf(
          viaGateway: false,
          error: const HandshakeException('Connection terminated during handshake'),
        ),
        isFalse,
      );
      expect(
        forumReachabilityOf(
          viaGateway: false,
          error: const SocketException('Connection reset by peer'),
        ),
        isFalse,
      );
    });

    test('取消、读超时、连本机网关本身失败都不算数', () {
      expect(
        forumReachabilityOf(
          viaGateway: false,
          error: DioException.requestCancelled(
            requestOptions: options,
            reason: 'cancel',
          ),
        ),
        isNull,
      );
      expect(
        forumReachabilityOf(
          viaGateway: false,
          error: DioException.receiveTimeout(
            requestOptions: options,
            timeout: const Duration(seconds: 30),
          ),
        ),
        isNull,
      );
      expect(
        forumReachabilityOf(
          viaGateway: true,
          error: const SocketException('Connection refused'),
        ),
        isNull,
      );
    });

    test('只看论坛的主域和子域', () {
      expect(isForumHost('linux.do'), isTrue);
      expect(isForumHost('connect.linux.do'), isTrue);
      // 本仓单站点：另一个域名不算论坛
      expect(isForumHost('idcflare.com'), isFalse);
      expect(isForumHost('cdn.ldstatic.com'), isFalse);
      expect(isForumHost('notlinux.do'), isFalse);
    });
  });

  group('requestCanUseWebViewAdapter', () {
    RequestOptions options(
      String path, {
      String method = 'GET',
      String baseUrl = 'https://linux.do',
      ResponseType? responseType,
      Map<String, dynamic>? headers,
    }) {
      return RequestOptions(
        path: path,
        baseUrl: baseUrl,
        method: method,
        responseType: responseType,
        headers: headers,
      );
    }

    test('主站 JSON API 可以由 WebView 接管', () {
      expect(requestCanUseWebViewAdapter(options('/latest.json')), isTrue);
    });

    test('主站写操作可以由 WebView 接管', () {
      expect(
        requestCanUseWebViewAdapter(options('/posts', method: 'POST')),
        isTrue,
      );
    });

    test('MessageBus、子域和二进制请求不进入兼容提示', () {
      expect(
        requestCanUseWebViewAdapter(options('/message-bus/abc/poll')),
        isFalse,
      );
      expect(
        requestCanUseWebViewAdapter(
          options('/api/v1/user', baseUrl: 'https://cdk.linux.do'),
        ),
        isFalse,
      );
      expect(
        requestCanUseWebViewAdapter(
          options('/download.json', responseType: ResponseType.bytes),
        ),
        isFalse,
      );
    });

    test('明确 HTML 请求不进入兼容提示', () {
      expect(
        requestCanUseWebViewAdapter(
          options('/', headers: {'Accept': 'text/html'}),
        ),
        isFalse,
      );
    });
  });
}
