/// Regression test for issue #123 (audit ML-ERR-026): registerDeviceToken sent
/// platform "ios" for every device, poisoning the data FCM v1 needs to build
/// platform-specific push payloads (apns vs android config blocks). The
/// platform must be derived from the actual target platform.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/api_service.dart';

/// A Dio that records the body of the last `post` and returns an empty 200.
class _CapturingDio with DioMixin implements Dio {
  Object? lastPostData;

  _CapturingDio() {
    options = BaseOptions();
  }

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    lastPostData = data;
    return Response<T>(requestOptions: RequestOptions(path: path), statusCode: 200);
  }
}

void main() {
  group('ApiService.registerDeviceToken platform field (#123)', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    Future<String?> sentPlatform(TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      final dio = _CapturingDio();
      await ApiService(dio: dio)
          .registerDeviceToken(userId: 'user-1', token: 'fcm-token');
      return (dio.lastPostData as Map<String, dynamic>?)?['platform'] as String?;
    }

    test('sends "android" on Android devices', () async {
      expect(await sentPlatform(TargetPlatform.android), 'android');
    });

    test('sends "ios" on iOS devices', () async {
      expect(await sentPlatform(TargetPlatform.iOS), 'ios');
    });
  });
}
