import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ota/flutter_ota.dart';

void main() {
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp();
    const MethodChannel('plugins.flutter.io/path_provider')
        .setMockMethodCallHandler((MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        return directory.path;
      }
      return null;
    });
  });

  test('adds one to input values', () async {
    final flutterOTA = FlutterOTA(channel: 'main');
    await flutterOTA.init();
    await flutterOTA.syncData();
    expect(1, 1);
  });
}
