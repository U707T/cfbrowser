import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cfbrowser/services/download/segmented_download.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SegmentedDownloadPlan', () {
    test('分段覆盖完整文件且没有重叠', () {
      const total = 10 * 1024 * 1024;
      final plan = SegmentedDownloadPlan.forTotal(total);

      expect(plan.total, total);
      expect(plan.segments.length, greaterThanOrEqualTo(2));
      expect(plan.segments.first.start, 0);
      expect(plan.segments.last.end, total - 1);

      var expectedStart = 0;
      for (final segment in plan.segments) {
        expect(segment.start, expectedStart);
        expect(segment.end, greaterThanOrEqualTo(segment.start));
        expectedStart = segment.end + 1;
      }
      expect(expectedStart, total);
    });

    test('2 MB 文件拆成 4 个 512 KB 分段', () {
      const total = 2 * 1024 * 1024;
      final plan = SegmentedDownloadPlan.forTotal(total);
      expect(plan.segments.length, 4);
      expect(plan.segments.first.length, 512 * 1024);
      expect(plan.initialWorkers, 2);
      expect(plan.minWorkers, 1);
      expect(plan.maxWorkers, 3);
    });

    test('小于 2 MB 时抛 Unsupported', () {
      expect(
        () => SegmentedDownloadPlan.forTotal(
          SegmentedDownloadPlan.minTotalBytes - 1,
        ),
        throwsA(isA<SegmentedDownloadUnsupported>()),
      );
    });
  });

  group('ContentRange', () {
    test('解析 206 的 Content-Range', () {
      final range = ContentRange.parse('bytes 0-0/12345');
      expect(range, isNotNull);
      expect(range!.start, 0);
      expect(range.end, 0);
      expect(range.total, 12345);
    });

    test('未知总长度/非法格式返回 null', () {
      expect(ContentRange.parse('bytes 0-0/*'), isNull);
      expect(ContentRange.parse('0-0/12345'), isNull);
      expect(ContentRange.parse('bytes 10-5/12345'), isNull);
      expect(ContentRange.parse(null), isNull);
    });
  });

  group('AdaptiveConcurrency', () {
    int next({
      int current = 3,
      int bytes = 0,
      double seconds = 2,
      int remaining = 10 * 1024 * 1024,
      int segment = 1024 * 1024,
      int errors = 0,
    }) {
      return AdaptiveConcurrency.next(
        current: current,
        minWorkers: 2,
        maxWorkers: 6,
        bytesSinceSample: bytes,
        elapsedSeconds: seconds,
        remainingBytes: remaining,
        segmentSize: segment,
        recentErrors: errors,
      );
    }

    test('吞吐高时扩容，吞吐低时缩容', () {
      expect(next(bytes: 4 * 1024 * 1024), 4);
      expect(next(bytes: 100 * 1024), 2);
    });

    test('错误优先缩容，且不越过上下界', () {
      expect(next(current: 6, bytes: 4 * 1024 * 1024), 6);
      expect(next(current: 2, bytes: 100 * 1024), 2);
      expect(next(current: 3, errors: 1), 2);
    });

    test('剩余量不足时不再扩容', () {
      expect(next(bytes: 4 * 1024 * 1024, remaining: 1024 * 1024), 3);
    });
  });

  test('本地 HTTP Range 服务：多分段写入的字节与源文件一致', () async {
    final content = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024, (index) => index % 251),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path != '/file') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = content.length;
        request.response.add(content);
      } else {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        final slice = content.sublist(start, end + 1);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${content.length}',
        );
        request.response.headers.contentLength = slice.length;
        request.response.add(slice);
      }
      await request.response.close();
    });

    final directory = await Directory.systemTemp.createTemp('segmented_test_');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/download.part');
    final progress = <(int, int)>[];

    final downloader = SegmentedDownloader(
      dio: Dio(),
      url: 'http://${server.address.address}:${server.port}/file',
      temporaryPath: target.path,
      onProgress: (received, total) => progress.add((received, total)),
    );
    await downloader.download();

    expect(await target.readAsBytes(), content);
    expect(progress.last, (content.length, content.length));
    expect(
      progress.any((item) => item.$1 > 0 && item.$1 < content.length),
      isTrue,
    );
  });

  test('服务端忽略 Range 时抛 Unsupported', () async {
    final content = Uint8List(3 * 1024 * 1024);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentLength = content.length;
      request.response.add(content);
      await request.response.close();
    });

    final directory = await Directory.systemTemp.createTemp('segmented_test_');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/download.part');

    final downloader = SegmentedDownloader(
      dio: Dio(),
      url: 'http://${server.address.address}:${server.port}/file',
      temporaryPath: target.path,
      onProgress: (_, _) {},
    );
    expect(downloader.download, throwsA(isA<SegmentedDownloadUnsupported>()));
  });

  test('SegmentRange 长度是闭区间', () {
    expect(const SegmentRange(0, 0).length, 1);
    expect(const SegmentRange(100, 199).length, 100);
  });

  test('分段响应的 Content-Range 多给一个字节时拒绝', () async {
    final content = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024, (index) => index % 239),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = content.length;
        request.response.add(content);
      } else {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final requestedEnd = int.parse(match.group(2)!);
        final isProbe = start == 0 && requestedEnd == 0;
        final end = isProbe
            ? 0
            : (requestedEnd < content.length - 1
                  ? requestedEnd + 1
                  : requestedEnd);
        final slice = content.sublist(start, end + 1);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${content.length}',
        );
        request.response.headers.contentLength = slice.length;
        request.response.add(slice);
      }
      await request.response.close();
    });

    final directory = await Directory.systemTemp.createTemp(
      'segmented_bad_end_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/download.part');
    final downloader = SegmentedDownloader(
      dio: Dio(),
      url: 'http://${server.address.address}:${server.port}/file',
      temporaryPath: target.path,
      onProgress: (_, _) {},
    );

    await expectLater(
      downloader.download,
      throwsA(isA<SegmentedDownloadUnsupported>()),
    );
  });

  test('分段 body 超出 Content-Range 时拒绝越界写入', () async {
    final content = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024, (index) => index % 241),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = content.length;
        request.response.add(content);
      } else {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        final slice = content.sublist(start, end + 1);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${content.length}',
        );
        // 声明 512 KB，实际多送 1 字节。
        request.response.headers.contentLength = slice.length + 1;
        request.response.add(slice);
        request.response.add(<int>[0xAA]);
      }
      await request.response.close();
    });

    final directory = await Directory.systemTemp.createTemp(
      'segmented_overrun_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/download.part');
    final downloader = SegmentedDownloader(
      dio: Dio(),
      url: 'http://${server.address.address}:${server.port}/file',
      temporaryPath: target.path,
      onProgress: (_, _) {},
    );

    await expectLater(downloader.download, throwsA(isA<StateError>()));
  });

  test('单个分段 500 后自动重试并完成', () async {
    final content = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024, (index) => index % 251),
    );
    var failedOnce = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = content.length;
        request.response.add(content);
      } else {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        final isProbe = start == 0 && end == 0;
        if (!isProbe && !failedOnce) {
          failedOnce = true;
          request.response.statusCode = HttpStatus.internalServerError;
        } else {
          final slice = content.sublist(start, end + 1);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${content.length}',
          );
          request.response.headers.contentLength = slice.length;
          request.response.add(slice);
        }
      }
      await request.response.close();
    });

    final directory = await Directory.systemTemp.createTemp('segmented_retry_');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/download.part');
    final downloader = SegmentedDownloader(
      dio: Dio(),
      url: 'http://${server.address.address}:${server.port}/file',
      temporaryPath: target.path,
      onProgress: (_, _) {},
    );

    await downloader.download();
    expect(failedOnce, isTrue);
    expect(await target.readAsBytes(), content);
  });

  test('分段长时间无进展时 watchdog 抛 Unsupported，交给上层回退单连接', () async {
    final content = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024, (index) => index % 233),
    );
    final stall = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      if (!stall.isCompleted) stall.complete();
      await server.close(force: true);
    });
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = content.length;
        request.response.add(content);
        await request.response.close();
        return;
      }
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      final isProbe = start == 0 && end == 0;
      final slice = content.sublist(start, end + 1);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${content.length}',
      );
      request.response.headers.contentLength = isProbe ? 1 : slice.length;
      if (isProbe) {
        request.response.add(slice.sublist(0, 1));
      } else {
        // 先给一小段证明连接活着，然后永远不再发数据。
        request.response.add(slice.sublist(0, 1024));
        await request.response.flush();
        await stall.future;
      }
      await request.response.close();
    });

    final directory = await Directory.systemTemp.createTemp('segmented_stall_');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/download.part');
    final downloader = SegmentedDownloader(
      dio: Dio(),
      url: 'http://${server.address.address}:${server.port}/file',
      temporaryPath: target.path,
      onProgress: (_, _) {},
      stallTimeout: const Duration(milliseconds: 300),
      watchdogInterval: const Duration(milliseconds: 80),
    );

    await expectLater(
      downloader.download,
      throwsA(isA<SegmentedDownloadUnsupported>()),
    );
  });
}
