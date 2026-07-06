/// Regression test for #123 (ML-ERR-026): `registerDeviceToken` hardcoded
/// `'platform': 'ios'` for every device, poisoning the platform column the
/// server needs to branch APNs vs FCM-Android push payloads. The request
/// body must now reflect `defaultTargetPlatform`.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/api_service.dart';

/// A Dio that captures the last request body instead of hitting the network.
class _CapturingDio with DioMixin implements Dio {
  _CapturingDio() {
    options = BaseOptions();
  }

  Map<String, dynamic>? lastData;

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
    lastData = data as Map<String, dynamic>;
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
    );
  }
}

void main() {
  group('ApiService.registerDeviceToken (#123 platform field)', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('sends platform "android" on Android devices', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final dio = _CapturingDio();
      final api = ApiService(dio: dio);

      await api.registerDeviceToken(userId: 'u1', token: 'tok');

      expect(dio.lastData!['platform'], 'android');
    });

    test('sends platform "ios" on iOS devices', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final dio = _CapturingDio();
      final api = ApiService(dio: dio);

      await api.registerDeviceToken(userId: 'u1', token: 'tok');

      expect(dio.lastData!['platform'], 'ios');
    });
  });
}
