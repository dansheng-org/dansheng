import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (report) async {
  final output = File(Platform.environment['DANSHENG_FRAMES_OUT'] ?? '.local/performance/frames.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  },
);
