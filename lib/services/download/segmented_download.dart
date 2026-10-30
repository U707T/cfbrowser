import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

/// 服务端不支持/不适合分段下载时抛出，调用方应回退到单连接下载。
class SegmentedDownloadUnsupported implements Exception {
  const SegmentedDownloadUnsupported(this.reason);

  final String reason;

  @override
  String toString() => 'SegmentedDownloadUnsupported($reason)';
}

/// 一个闭区间的分段。
@immutable
class SegmentRange {
  const SegmentRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;

  @override
  String toString() => 'SegmentRange($start-$end)';
}

/// `Content-Range: bytes start-end/total` 的解析结果。
@immutable
class ContentRange {
  const ContentRange({
    required this.start,
    required this.end,
    required this.total,
  });

  final int start;
  final int end;
  final int total;

  static ContentRange? parse(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) return null;
    final totalText = match.group(3)!;
    if (totalText == '*') return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = int.tryParse(totalText);
    if (start == null || end == null || total == null) return null;
    if (total <= 0 || start < 0 || end < start || end >= total) return null;
    return ContentRange(start: start, end: end, total: total);
  }
}

/// 分段计划：固定大小的闭区间 + 初始/最小/最大并发。
@immutable
class SegmentedDownloadPlan {
  const SegmentedDownloadPlan._({required this.total, required this.segments});

  /// 小于 2 MB 的文件走单连接，避免 Range 握手和分段的固定成本。
  static const int minTotalBytes = 2 * 1024 * 1024;
  static const int minSegmentBytes = 512 * 1024;
  static const int maxSegmentBytes = 4 * 1024 * 1024;
  static const int _targetChunks = 12;

  final int total;
  final List<SegmentRange> segments;

  int get initialWorkers => min(4, segments.length);
  int get minWorkers => min(2, segments.length);
  int get maxWorkers => min(6, segments.length);

  factory SegmentedDownloadPlan.forTotal(int total) {
    if (total < minTotalBytes) {
      throw const SegmentedDownloadUnsupported('文件小于 2 MB');
    }
    final rawSize = (total / _targetChunks).ceil();
    var segmentSize = rawSize.clamp(minSegmentBytes, maxSegmentBytes).toInt();
    // 超大文件兜底：最多 4096 段，避免分段对象本身占掉几十 MB。
    const maxSegments = 4096;
    if ((total / segmentSize).ceil() > maxSegments) {
      segmentSize = (total / maxSegments).ceil();
    }
    final segments = <SegmentRange>[];
    for (var start = 0; start < total; start += segmentSize) {
      final end = min(start + segmentSize, total) - 1;
      segments.add(SegmentRange(start, end));
    }
    return SegmentedDownloadPlan._(
      total: total,
      segments: List<SegmentRange>.unmodifiable(segments),
    );
  }
}

/// 并发自适应：每个采样窗口根据吞吐和错误数调整目标连接数。
class AdaptiveConcurrency {
  AdaptiveConcurrency._();

  static const int scaleUpBytesPerSecond = 768 * 1024;
  static const int scaleDownBytesPerSecond = 192 * 1024;

  static int next({
    required int current,
    required int minWorkers,
    required int maxWorkers,
    required int bytesSinceSample,
    required double elapsedSeconds,
    required int remainingBytes,
    required int segmentSize,
    required int recentErrors,
  }) {
    final clamped = current.clamp(minWorkers, maxWorkers).toInt();
    if (recentErrors > 0) {
      return max(minWorkers, clamped - 1);
    }
    // 剩余量不够再开新连接时不再扩容，避免刚拉起就结束。
    if (remainingBytes <= segmentSize * 2) return clamped;
    final speed = elapsedSeconds <= 0 ? 0.0 : bytesSinceSample / elapsedSeconds;
    if (speed >= scaleUpBytesPerSecond && clamped < maxWorkers) {
      return clamped + 1;
    }
    if (speed <= scaleDownBytesPerSecond && clamped > minWorkers) {
      return clamped - 1;
    }
    return clamped;
  }
}

/// Range 分段 + 自适应并发的下载器。
///
/// 只负责写临时文件；临时文件的生命周期、失败清理和最终 rename 仍由
/// `DownloadReservation` 管。探测失败/服务端忽略 Range 时抛
/// [SegmentedDownloadUnsupported]，调用方回退到原来的 Dio 单连接下载。
class SegmentedDownloader {
  SegmentedDownloader({
    required Dio dio,
    required String url,
    required String temporaryPath,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
    int maxRetries = 2,
  }) : _dio = dio,
       _url = url,
       _temporaryPath = temporaryPath,
       _onProgress = onProgress,
       _callerCancelToken = cancelToken,
       _maxRetries = maxRetries;

  final Dio _dio;
  final String _url;
  final String _temporaryPath;
  final void Function(int received, int total) _onProgress;
  final CancelToken? _callerCancelToken;
  final int _maxRetries;

  final CancelToken _cancelToken = CancelToken();
  final Lock _writeLock = Lock();
  final Completer<void> _completion = Completer<void>();

  RandomAccessFile? _file;
  late List<SegmentRange> _segments;
  late int _segmentSize;
  int _total = 0;
  int _received = 0;
  int _nextSegment = 0;
  int _completedSegments = 0;
  int _activeWorkers = 0;
  int _targetWorkers = 1;
  int _minWorkers = 1;
  int _maxWorkers = 1;
  int _recentErrors = 0;
  String? _validator;
  bool _cancelled = false;
  bool _finished = false;
  Object? _fatalError;
  StackTrace? _fatalStack;

  Future<void> download() async {
    _attachCallerCancel();
    final probe = await _probe();
    if (probe == null) {
      throw const SegmentedDownloadUnsupported('服务器不支持 Range');
    }

    final plan = SegmentedDownloadPlan.forTotal(probe.total);
    _segments = plan.segments;
    _segmentSize = plan.segments.first.length;
    _total = plan.total;
    _validator = probe.validator;
    _minWorkers = plan.minWorkers;
    _maxWorkers = plan.maxWorkers;
    _targetWorkers = plan.initialWorkers;

    Object? error;
    StackTrace? stackTrace;
    try {
      // open/truncate 也放进 try：truncate 失败（磁盘满）时文件句柄仍要
      // 关闭，否则 Windows 上上层删临时文件会失败。
      _file = await File(_temporaryPath).open(mode: FileMode.write);
      await _file!.truncate(_total);
      _notifyProgress();

      _ensureWorkers();
      unawaited(_adaptiveLoop());
      await _completion.future;
    } catch (e, s) {
      error = e;
      stackTrace = s;
    } finally {
      _cancelled = true;
      if (error != null && !_cancelToken.isCancelled) {
        // 提前失败时让已启动的 worker 尽快退出。
        _cancelToken.cancel('segmented_download_aborted');
      }
      try {
        await _file?.flush();
      } catch (_) {}
      try {
        await _file?.close();
      } catch (_) {}
    }

    // 调用方在收尾窗口取消时，即使分段刚好全部写完也按取消处理，
    // 让上层删除临时文件，而不是把「用户取消」误判成下载成功。
    if (_callerCancelToken?.isCancelled == true) {
      throw _callerCancelException();
    }
    if (error != null) {
      Error.throwWithStackTrace(error, stackTrace!);
    }

    final actualLength = await File(_temporaryPath).length();
    if (actualLength != _total) {
      throw StateError('分段下载文件长度不一致：$actualLength != $_total');
    }
    _notifyProgress();
  }

  DioException _callerCancelException() {
    return DioException(
      requestOptions: RequestOptions(path: _url),
      type: DioExceptionType.cancel,
      error: 'caller_cancelled',
    );
  }

  void _attachCallerCancel() {
    final caller = _callerCancelToken;
    if (caller == null) return;
    if (caller.isCancelled) {
      _cancelToken.cancel('caller_cancelled');
      return;
    }
    unawaited(
      caller.whenCancel.then((error) {
        if (!_cancelToken.isCancelled) {
          _cancelToken.cancel(error.error);
        }
      }),
    );
  }

  Future<_ProbeResult?> _probe() async {
    final probeToken = CancelToken();
    final caller = _callerCancelToken;
    if (caller != null) {
      if (caller.isCancelled) {
        probeToken.cancel('caller_cancelled');
      } else {
        unawaited(
          caller.whenCancel.then((error) {
            if (!probeToken.isCancelled) probeToken.cancel(error.error);
          }),
        );
      }
    }

    StreamSubscription<Uint8List>? subscription;
    try {
      final response = await _dio.get<ResponseBody>(
        _url,
        options: Options(
          responseType: ResponseType.stream,
          headers: const {'Range': 'bytes=0-0', 'Accept-Encoding': 'identity'},
          extra: const {'skipCsrf': true, 'skipAuthCheck': true},
          receiveTimeout: const Duration(seconds: 20),
        ),
        cancelToken: probeToken,
      );

      final body = response.data;
      if (body == null) return null;
      // 无论 200 还是 206，都只需要响应头；立即取消，避免服务端把整包发完。
      subscription = body.stream.listen(null);
      await subscription.cancel();

      if (response.statusCode != 206) return null;

      final contentEncoding = response.headers
          .value('content-encoding')
          ?.toLowerCase();
      if (contentEncoding != null && contentEncoding != 'identity') {
        return null;
      }
      final contentRange = ContentRange.parse(
        response.headers.value('content-range'),
      );
      if (contentRange == null ||
          contentRange.start != 0 ||
          contentRange.end != 0) {
        return null;
      }
      return _ProbeResult(
        total: contentRange.total,
        validator:
            response.headers.value('etag') ??
            response.headers.value('last-modified'),
      );
    } catch (error) {
      if (error is DioException && error.type == DioExceptionType.cancel) {
        rethrow;
      }
      // 416 / 405 / 网络错误 / 响应流异常都按「不支持」处理，
      // 交给单连接回退。
      return null;
    } finally {
      await subscription?.cancel();
      if (!probeToken.isCancelled) probeToken.cancel('probe_done');
    }
  }

  Future<void> _downloadSegment(int index) async {
    final segment = _segments[index];
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      if (_cancelled) throw const _Aborted();
      var received = 0;
      try {
        final headers = <String, dynamic>{
          'Range': 'bytes=${segment.start}-${segment.end}',
          'Accept-Encoding': 'identity',
        };
        final validator = _validator;
        if (validator != null) headers['If-Range'] = validator;

        final response = await _dio.get<ResponseBody>(
          _url,
          options: Options(
            responseType: ResponseType.stream,
            headers: headers,
            extra: const {'skipCsrf': true, 'skipAuthCheck': true},
            // 单个分段卡住时尽快失败重试，不让整包挂在 30 分钟的全局
            // receiveTimeout 上。
            receiveTimeout: const Duration(seconds: 60),
          ),
          cancelToken: _cancelToken,
        );

        final body = response.data;
        if (response.statusCode != 206) {
          await _closeBody(body);
          throw SegmentedDownloadUnsupported(
            '分段请求返回 HTTP ${response.statusCode}',
          );
        }
        final contentRange = ContentRange.parse(
          response.headers.value('content-range'),
        );
        if (contentRange == null ||
            contentRange.total != _total ||
            contentRange.start != segment.start ||
            // 必须精确等于请求的区间：服务端如果多给一个字节，后面的
            // 写入会越过本段边界，和相邻 worker 的数据互相覆盖。
            contentRange.end != segment.end) {
          await _closeBody(body);
          throw const SegmentedDownloadUnsupported('Content-Range 与分段不匹配');
        }
        if (body == null) {
          throw const SegmentedDownloadUnsupported('分段响应为空');
        }
        // Range 的字节偏移针对的是实体字节；如果服务端无视
        // Accept-Encoding: identity 仍然压缩，偏移和实际写入会对不上。
        // 探测阶段已经拦过一次，这里对每个分段再确认，避免中途换行为。
        final contentEncoding = response.headers
            .value('content-encoding')
            ?.toLowerCase();
        if (contentEncoding != null && contentEncoding != 'identity') {
          await _closeBody(body);
          throw const SegmentedDownloadUnsupported('分段响应被压缩');
        }
        // If-Range 只是请求头，服务端可以选择忽略。这里再核对一次
        // ETag/Last-Modified，避免文件在下载途中被替换后拼出新旧混合内容。
        final responseValidator =
            response.headers.value('etag') ??
            response.headers.value('last-modified');
        if (_validator != null &&
            responseValidator != null &&
            responseValidator != _validator) {
          await _closeBody(body);
          throw const SegmentedDownloadUnsupported('文件在下载过程中发生变化');
        }

        await for (final chunk in body.stream) {
          if (_cancelled) throw const _Aborted();
          if (chunk.isEmpty) continue;
          // body 比声明的 Content-Range 长时，先拒绝而不是写越界；
          // 否则会覆盖相邻分段，且长度校验要等到全部写完才发现。
          if (received + chunk.length > segment.length) {
            throw StateError('分段 ${segment.start}-${segment.end} 响应超出请求范围');
          }
          await _writeAt(segment.start + received, chunk);
          received += chunk.length;
          _received += chunk.length;
          _notifyProgress();
        }

        if (received != segment.length) {
          throw StateError(
            '分段 ${segment.start}-${segment.end} 长度不一致：'
            '$received != ${segment.length}',
          );
        }
        _completedSegments++;
        return;
      } on _Aborted {
        _received -= received;
        rethrow;
      } on SegmentedDownloadUnsupported {
        _received -= received;
        _notifyProgress();
        rethrow;
      } on DioException catch (error) {
        _received -= received;
        _notifyProgress();
        if (error.type == DioExceptionType.cancel) rethrow;
        if (error.response?.statusCode == 416) {
          throw const SegmentedDownloadUnsupported('服务端拒绝了 Range');
        }
        if (attempt >= _maxRetries) rethrow;
        _recentErrors++;
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      } on FileSystemException {
        _received -= received;
        rethrow;
      } catch (error) {
        _received -= received;
        _notifyProgress();
        if (attempt >= _maxRetries) rethrow;
        _recentErrors++;
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
  }

  Future<void> _writeAt(int offset, Uint8List data) {
    return _writeLock.synchronized(() async {
      final file = _file;
      if (file == null) throw const _Aborted();
      await file.setPosition(offset);
      await file.writeFrom(data);
    });
  }

  Future<void> _closeBody(ResponseBody? body) async {
    if (body == null) return;
    StreamSubscription<Uint8List>? subscription;
    try {
      subscription = body.stream.listen(null);
      await subscription.cancel();
    } catch (_) {
      // 关闭探测/回退响应时流已结束或已取消，忽略。
    } finally {
      await subscription?.cancel();
    }
  }

  void _ensureWorkers() {
    while (!_cancelled && _activeWorkers < _targetWorkers) {
      _activeWorkers++;
      unawaited(_worker());
    }
  }

  Future<void> _worker() async {
    try {
      while (!_cancelled) {
        if (_activeWorkers > _targetWorkers) break;
        final index = _nextSegment;
        if (index >= _segments.length) break;
        _nextSegment++;
        await _downloadSegment(index);
      }
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    } finally {
      _activeWorkers--;
      _maybeComplete();
    }
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_fatalError != null) return;
    _fatalError = error;
    _fatalStack = stackTrace;
    _cancelled = true;
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('segmented_download_aborted');
    }
  }

  void _maybeComplete() {
    if (_finished) return;
    if (_activeWorkers > 0) return;
    if (_fatalError == null && _completedSegments < _segments.length) {
      _ensureWorkers();
      if (_activeWorkers > 0) return;
    }
    _finished = true;
    if (_fatalError != null) {
      _completion.completeError(_fatalError!, _fatalStack);
    } else {
      _completion.complete();
    }
  }

  Future<void> _adaptiveLoop() async {
    try {
      var lastBytes = _received;
      var lastAt = DateTime.now();
      while (!_cancelled && !_finished) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (_cancelled || _finished) return;

        final now = DateTime.now();
        final elapsed = now.difference(lastAt).inMilliseconds / 1000.0;
        final delta = _received - lastBytes;
        final next = AdaptiveConcurrency.next(
          current: _targetWorkers,
          minWorkers: _minWorkers,
          maxWorkers: _maxWorkers,
          bytesSinceSample: delta,
          elapsedSeconds: elapsed,
          remainingBytes: _total - _received,
          segmentSize: _segmentSize,
          recentErrors: _recentErrors,
        );
        _recentErrors = 0;
        if (next != _targetWorkers) {
          _targetWorkers = next;
          debugPrint('[SegmentedDownload] 并发调整为 $_targetWorkers');
        }
        _ensureWorkers();
        lastBytes = _received;
        lastAt = now;
      }
    } catch (error) {
      // 自适应只是优化，失败不应中断下载。
      debugPrint('[SegmentedDownload] 自适应并发循环退出: $error');
    }
  }

  void _notifyProgress() {
    if (_total <= 0) return;
    try {
      _onProgress(_received.clamp(0, _total).toInt(), _total);
    } catch (error) {
      // 进度只是 UI 反馈，不能因为它打断下载。
      debugPrint('[SegmentedDownload] 进度回调失败: $error');
    }
  }
}

class _ProbeResult {
  const _ProbeResult({required this.total, this.validator});

  final int total;
  final String? validator;
}

class _Aborted implements Exception {
  const _Aborted();
}
