// Read-only mock harness: flutter run -d flutter-tester -t test/campus/learning_people_harness.dart
import 'dart:convert';
import 'dart:developer';

import 'package:dansheng_app/ui/campus/learning/people/course_people_page.dart';
import 'package:flutter/material.dart';

import 'learning_chat_test.dart' as mocks;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final errors = <String>[];
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());
  final bridge = mocks.ChatBridge();
  bridge.handler = (method, params) async => switch (method) {
    'canvas.course_users.sync' => [
      mocks.record({
        'id': '30',
        'name': '示例老师',
        'enrollments': [
          {'type': 'TeacherEnrollment'},
        ],
      }),
    ],
    _ => throw StateError('Harness disallows other requests: $method'),
  };
  final app = mocks.ChatApp(bridge);
  final controller = mocks.ChatLearning(app);
  runApp(
    MaterialApp(
      home: CoursePeoplePage(
        controller: controller,
        course: controller.courses.first,
      ),
    ),
  );
  registerExtension('ext.peopleHarness.check', (_, params) async {
    final widgets = <Widget>[];
    void visit(Element element) {
      widgets.add(element.widget);
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    switch (params['action']) {
      case 'compose':
        widgets
            .whereType<TextButton>()
            .firstWhere(
              (w) => w.child is Text && (w.child as Text).data == '发消息',
            )
            .onPressed!();
      case 'account':
        app.changeTestAccount();
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    widgets.clear();
    final nextRoot = WidgetsBinding.instance.rootElement;
    if (nextRoot != null) visit(nextRoot);
    return ServiceExtensionResponse.result(
      jsonEncode({
        'texts': widgets
            .whereType<Text>()
            .map((w) => w.data)
            .whereType<String>()
            .toList(),
        'errors': errors,
        'methods': bridge.calls.map((c) => c['method']).toList(),
      }),
    );
  });
}
