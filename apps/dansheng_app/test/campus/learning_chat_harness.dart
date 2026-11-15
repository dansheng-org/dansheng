// Headless mock UI: flutter run -d flutter-tester -t test/campus/learning_chat_harness.dart
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:dansheng_app/ui/campus/learning/chat/learning_chat_page.dart';
import 'package:dansheng_app/ui/campus/learning/models/canvas_models.dart';

import 'learning_chat_test.dart' as mocks;

String reloadMarker() => 'chat-harness-v2';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final errors = <String>[];
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
  };
  final bridge = mocks.ChatBridge();
  bridge.handler = (method, params) async => switch (method) {
    'canvas.conversations.sync' => [mocks.record(mocks.conversation())],
    'canvas.conversation.read' => mocks.record(mocks.conversation()),
    'canvas.recipients.search' => [
      mocks.record({'id': '30', 'name': '老师'}),
    ],
    _ => throw StateError('Harness disallows writes: $method'),
  };
  final controller = mocks.ChatLearning(mocks.ChatApp(bridge));
  final archived = ValueNotifier<bool>(false);
  runApp(
    MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: archived,
        builder: (_, value, _) => LearningChatPage(
          key: ValueKey(value),
          controller: controller,
          course: value ? const CanvasCourse(id: '9', name: '归档课程') : null,
        ),
      ),
    ),
  );
  registerExtension('ext.chatHarness.check', (method, params) async {
    final widgets = <Widget>[];
    void visit(Element element) {
      widgets.add(element.widget);
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    switch (params['action']) {
      case 'archive':
        archived.value = true;
      case 'read':
        widgets.whereType<ListTile>().first.onTap!();
      case 'compose':
        widgets.whereType<FloatingActionButton>().first.onPressed!();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    widgets.clear();
    final nextRoot = WidgetsBinding.instance.rootElement;
    if (nextRoot != null) visit(nextRoot);
    return ServiceExtensionResponse.result(
      jsonEncode({
        'marker': reloadMarker(),
        'texts': widgets
            .whereType<Text>()
            .map((w) => w.data)
            .whereType<String>()
            .toList(),
        'errors': errors,
        'calls': bridge.calls,
      }),
    );
  });
}
