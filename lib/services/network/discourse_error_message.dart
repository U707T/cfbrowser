/// 从已解码的响应体提取错误文案，忽略不符合预期的字段类型。
String? extractDiscourseErrorMessage(Object? data) {
  if (data is! Map) return null;

  final error = data['error'];
  if (error is String) return error;
  if (error is Map) {
    final message = error['message'];
    if (message is String) return message;
  }

  final errors = data['errors'];
  return errors is List ? errors.firstOrNull?.toString() : null;
}
