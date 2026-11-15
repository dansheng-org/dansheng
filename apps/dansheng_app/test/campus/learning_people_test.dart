import 'dart:async';

import 'package:dansheng_app/ui/campus/learning/people/course_people_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'learning_chat_test.dart' as mocks;

void main() {
  late mocks.ChatBridge bridge;
  late mocks.ChatApp app;
  late mocks.ChatLearning controller;
  final people = [
    mocks.record({
      'id': '30',
      'name': '老师甲',
      'email': 'hidden@example.test',
      'enrollments': [
        {'type': 'TeacherEnrollment'},
      ],
    }),
    mocks.record({
      'id': '31',
      'name': '助教乙',
      'enrollments': [
        {'type': 'TaEnrollment'},
      ],
    }),
    mocks.record({
      'id': '32',
      'name': '同学丙',
      'enrollments': [
        {'role': 'StudentEnrollment'},
      ],
    }),
    mocks.record({'id': '33', 'short_name': '成员丁'}),
  ];
  setUp(() {
    bridge = mocks.ChatBridge();
    app = mocks.ChatApp(bridge);
    controller = mocks.ChatLearning(app);
    bridge.handler = (method, params) async => switch (method) {
      'canvas.course_users.sync' => people,
      'canvas.conversation.create' => [mocks.record(mocks.conversation())],
      'canvas.conversation.read' => mocks.record(mocks.conversation()),
      _ => throw StateError('Unexpected method $method'),
    };
  });
  tearDown(() {
    controller.dispose();
    app.dispose();
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CoursePeoplePage(
          controller: controller,
          course: controller.courses.first,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'roster roles and compose use selected recipient API params only after send',
    (tester) async {
      await mount(tester);
      expect(bridge.calls.single['params'], {
        'course_id': '10',
        'account_id': 'a',
      });
      for (final label in ['老师', '助教', '学生', '成员']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('hidden@example.test'), findsNothing);
      expect(find.text('30'), findsNothing);
      await tester.tap(find.text('发消息').first);
      await tester.pumpAndSettle();
      expect(find.text('新建消息'), findsOneWidget);
      expect(find.widgetWithText(InputChip, '老师甲'), findsOneWidget);
      expect(bridge.calls.length, 1);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byKey(const Key('chat-subject')), '请教');
      await tester.enterText(find.byKey(const Key('chat-body')), '你好');
      await tester.pump();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(
        bridge.calls.singleWhere(
          (c) => c['method'] == 'canvas.conversation.create',
        )['params'],
        {
          'course_id': '10',
          'recipients': ['30'],
          'subject': '请教',
          'body': '你好',
          'account_id': 'a',
        },
      );
    },
  );

  testWidgets('search empty result and clear search', (tester) async {
    await mount(tester);
    bridge.handler = (_, _) async => [];
    await tester.enterText(find.byKey(const Key('people-search')), '不存在');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(bridge.calls.last['params'], {
      'course_id': '10',
      'search': '不存在',
      'account_id': 'a',
    });
    expect(find.text('未找到匹配的课程人员'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('people-search')), '');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(bridge.calls.last['params'], {'course_id': '10', 'account_id': 'a'});
    expect(find.text('暂无课程人员'), findsOneWidget);
  });

  testWidgets('permission failure is sanitized and retry recovers', (
    tester,
  ) async {
    bridge.handler = (_, _) async =>
        throw Exception('PermissionDenied hidden@example.test');
    await mount(tester);
    expect(find.text('无法查看课程人员，请确认已登录且有课程访问权限。'), findsOneWidget);
    expect(find.textContaining('hidden@example.test'), findsNothing);
    bridge.handler = (_, _) async => people;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('老师甲'), findsOneWidget);
  });

  testWidgets('account switch clears roster search and ignores late response', (
    tester,
  ) async {
    await mount(tester);
    final pending = Completer<dynamic>();
    bridge.handler = (_, _) => pending.future;
    await tester.enterText(find.byKey(const Key('people-search')), '老师');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump();
    expect(find.text('正在加载课程人员…'), findsOneWidget);
    app.changeTestAccount();
    await tester.pump();
    pending.complete(people);
    await tester.pumpAndSettle();
    expect(find.text('老师甲'), findsNothing);
    expect(find.byKey(const Key('people-search')), findsNothing);
    expect(find.text('账号已切换，请返回并重新打开课程人员。'), findsOneWidget);
    expect(find.text('发消息'), findsNothing);
  });

  testWidgets(
    'account switch clears prefilled recipient and draft on both routes',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('发消息').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('chat-subject')), '旧主题');
      await tester.enterText(find.byKey(const Key('chat-body')), '旧正文');
      app.changeTestAccount();
      await tester.pumpAndSettle();
      expect(find.text('旧主题'), findsNothing);
      expect(find.text('旧正文'), findsNothing);
      expect(find.byType(InputChip), findsNothing);
      expect(find.text('发送'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('老师甲'), findsNothing);
      expect(find.text('账号已切换，请返回并重新打开课程人员。'), findsOneWidget);
      expect(
        bridge.calls.where((c) => c['method'] == 'canvas.conversation.create'),
        isEmpty,
      );
    },
  );

  testWidgets('320px roster and long recipient composer do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bridge.handler = (_, _) async => [
      mocks.record({
        'id': '30',
        'name': '很长的课程成员姓名用于验证窄屏下能够正确换行和截断显示而不溢出',
        'enrollments': [],
      }),
    ];
    await mount(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
