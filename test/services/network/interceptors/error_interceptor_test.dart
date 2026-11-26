import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cfbrowser/services/network/exceptions/api_exception.dart';
import 'package:cfbrowser/services/network/interceptors/error_interceptor.dart';
import 'package:cfbrowser/services/network/recovery/policies.dart';
import 'package:cfbrowser/services/network/recovery/recovery_policy.dart';

/// ErrorInterceptor 的「结果保真」契约:
/// 把 429/5xx 转成类型化异常时,必须保留原始 response,
/// 否则下游拦截器(CF 验证/网络日志)与调用方只能看到 statusCode=null。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('429 转 RateLimitException 后下游与调用方仍可见原始 response', () async {
    final downstream = _CaptureInterceptor();
    final dio = _buildDio(
      statusCode: 429,
      body: '{"errors":["请等待 7 秒"]}',
      headers: {
        'retry-after': ['7'],
        Headers.contentTypeHeader: ['application/json'],
      },
      downstream: downstream,
    );

    Object? callerError;
    int? callerStatus;
    try {
      await dio.get('/latest.json');
    } on DioException catch (e) {
      callerError = e.error;
      callerStatus = e.response?.statusCode;
    }

    // 下游拦截器(注册在 ErrorInterceptor 之后)看得到状态码与响应体
    expect(downstream.seenStatusCode, 429);
    expect(downstream.seenError, isA<RateLimitException>());

    // 调用方拿到类型化异常,且 response 未丢失
    expect(callerStatus, 429);
    expect(callerError, isA<RateLimitException>());
    final rateLimit = callerError as RateLimitException;
    expect(rateLimit.retryAfterSeconds, 7);
    // 异常自身也挂着 response,供业务层提取服务端文案
    expect(rateLimit.response?.statusCode, 429);
  });

  test('第三方接口返回结构化 error 时，原始 400 错误继续传给下游与调用方', () async {
    final downstream = _CaptureInterceptor();
    final dio = _buildDio(
      statusCode: 400,
      body: '{"error":{"code":"BAD_RETURN_URL","message":"回调地址不被允许"}}',
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
      downstream: downstream,
    );

    await expectLater(
      dio.get<dynamic>('/api/auth/init'),
      throwsA(
        isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.badResponse)
            .having((e) => e.response?.statusCode, 'statusCode', 400)
            .having((e) => e.response?.data, 'data', {
              'error': {'code': 'BAD_RETURN_URL', 'message': '回调地址不被允许'},
            }),
      ),
    );
    expect(downstream.seenStatusCode, 400);
  });

  group('429 错误文案', () {
    for (final (label, body, message) in <(String, String, String?)>[
      ('优先使用 error 字符串', '{"error":"限流","errors":["备用"]}', '限流'),
      ('读取结构化 error.message', '{"error":{"message":"请求过多"}}', '请求过多'),
      ('退回 errors 首项', '{"error":{"message":false},"errors":["太快"]}', '太快'),
      ('忽略无效 error', '{"error":42}', null),
      ('忽略非列表 errors', '{"errors":{"message":"无效"}}', null),
      ('忽略非对象响应', '["无效"]', null),
    ]) {
      test('$label，拦截器和恢复策略都保留原始 response', () async {
        final downstream = _CaptureInterceptor();
        final dio = _buildDio(
          statusCode: 429,
          body: body,
          headers: {
            'retry-after': ['600'],
            Headers.contentTypeHeader: ['application/json'],
          },
          downstream: downstream,
        );
        final Response<dynamic> response;
        try {
          await dio.get<dynamic>('/latest.json');
          throw StateError('请求应失败');
        } on DioException catch (error) {
          expect(error.type, DioExceptionType.badResponse);
          expect(error.response?.statusCode, 429);
          expect(downstream.seenStatusCode, 429);
          expect(error.error, same(downstream.seenError));
          final rateLimit = error.error as RateLimitException;
          expect(rateLimit.message, message);
          expect(rateLimit.response, same(error.response));
          response = error.response!;
        }

        final original = DioException.badResponse(
          statusCode: 429,
          requestOptions: response.requestOptions,
          response: response,
        );
        const policy = RateLimitPolicy();
        final decision = await policy.decide(
          AttemptOutcome.failure(error: original, attemptIndex: 0),
        );
        expect(decision, isA<RecoveryFail>());
        final failure = (decision as RecoveryFail).error;
        expect(failure.type, original.type);
        expect(failure.response, same(response));
        final rateLimit = failure.error as RateLimitException;
        expect(rateLimit.message, message);
        expect(rateLimit.retryAfterSeconds, 600);
        expect(rateLimit.response, same(response));
      });
    }
  });

  test('503 转 ServerException 后仍可见原始 response', () async {
    final downstream = _CaptureInterceptor();
    final dio = _buildDio(
      statusCode: 503,
      body: 'service unavailable',
      headers: const {},
      downstream: downstream,
    );

    Object? callerError;
    int? callerStatus;
    try {
      await dio.get('/latest.json');
    } on DioException catch (e) {
      callerError = e.error;
      callerStatus = e.response?.statusCode;
    }

    expect(downstream.seenStatusCode, 503);
    expect(callerStatus, 503);
    expect(callerError, isA<ServerException>());
    expect((callerError as ServerException).statusCode, 503);
  });

  test('挑战型 503 原样交给 CF 拦截器,不转 ServerException', () async {
    final downstream = _CaptureInterceptor();
    final dio = _buildDio(
      statusCode: 503,
      body: 'challenge',
      headers: {
        'cf-mitigated': ['challenge'],
        Headers.contentTypeHeader: ['text/plain'],
      },
      downstream: downstream,
    );

    Object? callerError;
    try {
      await dio.get('/latest.json');
    } on DioException catch (e) {
      callerError = e.error;
    }

    expect(downstream.seenStatusCode, 503);
    expect(
      callerError,
      isNot(isA<ServerException>()),
      reason: '挑战不是服务器故障,不能弹"服务器暂不可用"',
    );
  });
}

Dio _buildDio({
  required int statusCode,
  required String body,
  required Map<String, List<String>> headers,
  required _CaptureInterceptor downstream,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://linux.do',
      validateStatus: (status) => status != null && status < 400,
    ),
  )..httpClientAdapter = _FixedStatusAdapter(statusCode, body, headers);
  // 静默请求会在 ErrorInterceptor 早退,这里用默认(非静默)GET,
  // 且 GET 默认不弹 toast,避免测试环境缺少 l10n/Overlay。
  dio.interceptors.add(ErrorInterceptor());
  dio.interceptors.add(downstream);
  return dio;
}

class _CaptureInterceptor extends Interceptor {
  int? seenStatusCode;
  Object? seenError;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    seenStatusCode = err.response?.statusCode;
    seenError = err.error;
    handler.next(err);
  }
}

class _FixedStatusAdapter implements HttpClientAdapter {
  _FixedStatusAdapter(this.statusCode, this.body, this.headers);

  final int statusCode;
  final String body;
  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(body, statusCode, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}
