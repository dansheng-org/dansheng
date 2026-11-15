import 'dart:async';
import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/learning/chat/chat_data.dart';
import 'package:dansheng_app/ui/campus/learning/chat/learning_chat_page.dart';
import 'package:dansheng_app/ui/campus/learning/learning_controller.dart';
import 'package:dansheng_app/ui/campus/learning/models/canvas_models.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ChatBridge implements DanshengBridge {
  final calls = <Map<String, dynamic>>[];
  Future<dynamic> Function(String, Map<String, dynamic>)? handler;
  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final request = jsonDecode(payload) as Map<String, dynamic>;
    calls.add(request);
    return jsonEncode(
      await handler!(
        request['method'] as String,
        Map<String, dynamic>.from(request['params'] as Map),
      ),
    );
  }
}

class ChatApp extends DanshengController {
  ChatApp(ChatBridge bridge) : super(client: DanshengClient(bridge: bridge));
  String account = 'a';
  @override
  String? get activeAccountId => account;
  void changeTestAccount() {
    account = 'b';
    notifyListeners();
  }
}

class ChatLearning extends LearningController {
  ChatLearning(DanshengController app) : super(appController: app);
  List<CanvasCourse> testCourses = const [
    CanvasCourse(id: '10', name: '本学期 A'),
    CanvasCourse(id: '11', name: '本学期 B'),
  ];
  @override
  List<CanvasCourse> get courses => testCourses;
  void replaceCourses(List<CanvasCourse> value) {
    testCourses = value;
    notifyListeners();
  }
}

Map<String, dynamic> conversation({String body = '老师的消息'}) => {
  'id': '20',
  'subject': '课程问题',
  'last_message': body,
  'participants': [
    {'id': '30', 'name': '老师'},
  ],
  'messages': [
    {'id': '40', 'author_id': '30', 'body': body, 'created_at': '2026-11-14'},
  ],
};
dynamic record(dynamic payload) => {'external_id': '20', 'payload': payload};

void main() {
  late ChatBridge bridge;
  late ChatApp app;
  late ChatLearning controller;
  setUp(() {
    bridge = ChatBridge();
    app = ChatApp(bridge);
    controller = ChatLearning(app);
    bridge.handler = (method, params) async => switch (method) {
      'canvas.conversations.sync' => [record(conversation())],
      'canvas.conversation.read' ||
      'canvas.conversation.reply' => record(conversation()),
      'canvas.recipients.search' => [
        record({'id': '30', 'name': '老师'}),
      ],
      'canvas.conversation.create' => [record(conversation())],
      _ => {},
    };
  });
  tearDown(() {
    controller.dispose();
    app.dispose();
  });
  Future<void> mount(WidgetTester tester, {CanvasCourse? course}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LearningChatPage(controller: controller, course: course),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final code in [
    'CapabilityUnavailable',
    'PermissionDenied',
    'InvalidConfiguration',
    'UnexpectedFailure',
  ]) {
    testWidgets('definite rejection $code keeps draft editable', (
      tester,
    ) async {
      await mount(tester);
      await tester.tap(find.text('课程问题'));
      await tester.pumpAndSettle();
      bridge.handler = (_, _) async => throw Exception(code);
      await tester.enterText(find.byKey(const Key('chat-body')), '保留草稿');
      await tester.pump();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(find.textContaining('发送结果未确认'), findsNothing);
      expect(find.text('保留草稿'), findsOneWidget);
      expect(find.textContaining('token'), findsNothing);
      expect(find.text('绑定 Canvas 令牌'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
            .onPressed,
        isNotNull,
      );
    });
  }

  testWidgets(
    'course refresh clears invalid selection and preserves explicit archive',
    (tester) async {
      await mount(tester);
      controller.replaceCourses(const [CanvasCourse(id: '11', name: '本学期 B')]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(bridge.calls.last['params']['course_id'], '11');
      controller.replaceCourses([]);
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('课程问题'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await mount(
        tester,
        course: const CanvasCourse(id: '9', name: '归档课程'),
      );
      controller.replaceCourses(const [CanvasCourse(id: '12', name: '新课程')]);
      await tester.pumpAndSettle();
      expect(find.text('归档课程'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('320px narrow chat list read and composer do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await tester.tap(find.text('课程问题'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建消息'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('current-term selector and explicit archived course', (
    tester,
  ) async {
    await mount(tester);
    expect(bridge.calls.first['params']['course_id'], '10');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本学期 B').last);
    await tester.pumpAndSettle();
    expect(bridge.calls.last['params']['course_id'], '11');
    await tester.pumpWidget(const SizedBox());
    await mount(
      tester,
      course: const CanvasCourse(id: '9', name: '归档课程'),
    );
    expect(bridge.calls.last['params']['course_id'], '9');
    expect(find.text('归档课程'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets('read and reply suppress duplicate send while pending', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('课程问题'));
    await tester.pumpAndSettle();
    expect(find.text('老师的消息'), findsOneWidget);
    final pending = Completer<dynamic>();
    bridge.handler = (method, params) async =>
        method == 'canvas.conversation.reply'
        ? pending.future
        : record(conversation(body: '回复后'));
    await tester.enterText(find.byKey(const Key('chat-body')), '我的回复');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pump();
    await tester.tap(find.text('发送中…'));
    await tester.pump();
    final sends = bridge.calls
        .where((c) => c['method'] == 'canvas.conversation.reply')
        .toList();
    expect(sends.length, 1);
    expect(sends.single['params'], {'conversation_id': '20', 'body': '我的回复'});
    pending.complete(record(conversation()));
    await tester.pumpAndSettle();
    expect(find.text('回复后'), findsOneWidget);
    expect(find.text('我的回复'), findsNothing);
  });

  testWidgets('search recipient and create source-record array conversation', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('新建消息'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-search')), '老师');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat-subject')), '请教');
    await tester.enterText(find.byKey(const Key('chat-body')), '你好');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    final send = bridge.calls.singleWhere(
      (c) => c['method'] == 'canvas.conversation.create',
    );
    expect(send['params'], {
      'course_id': '10',
      'recipients': ['30'],
      'subject': '请教',
      'body': '你好',
    });
    expect(find.text('课程问题'), findsOneWidget);
  });

  testWidgets('token binding replaces login without automatically resending', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('课程问题'));
    await tester.pumpAndSettle();
    bridge.handler = (method, _) async {
      if (method == 'campus.login') return {};
      throw Exception('CanvasTokenRequired');
    };
    await tester.enterText(find.byKey(const Key('chat-body')), '需要令牌的草稿');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.text('绑定 Canvas 令牌'), findsOneWidget);
    expect(find.text('刷新 Canvas 统一登录'), findsNothing);
    expect(find.textContaining('校园账号登录仅支持读取'), findsNothing);
    await tester.tap(find.text('绑定 Canvas 令牌'));
    await tester.pumpAndSettle();
    expect(bridge.calls.last['params'], {'service': 'canvas', 'replace': true});
    expect(
      bridge.calls
          .where((c) => c['method'] == 'canvas.conversation.reply')
          .length,
      1,
    );
    expect(find.text('需要令牌的草稿'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'CSRF preflight refresh preserves recipient and draft until manual send',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LearningChatPage(
            controller: controller,
            course: controller.courses.first,
            initialRecipient: const ChatRecipient(id: '30', name: '老师'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var refreshed = false;
      bridge.handler = (method, _) async {
        if (method == 'campus.login') {
          refreshed = true;
          return {};
        }
        if (method == 'canvas.conversation.create' && !refreshed) {
          throw Exception('CanvasCsrfRequired');
        }
        return record(conversation());
      };
      await tester.enterText(find.byKey(const Key('chat-subject')), '保留主题');
      await tester.enterText(find.byKey(const Key('chat-body')), '保留正文');
      await tester.pump();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(find.text('消息尚未发送，请刷新 Canvas 统一登录后手动发送。'), findsOneWidget);
      expect(find.textContaining('发送结果未确认'), findsNothing);
      expect(find.text('绑定 Canvas 令牌'), findsNothing);
      await tester.tap(find.text('刷新 Canvas 统一登录'));
      await tester.pumpAndSettle();
      expect(bridge.calls.last['method'], 'campus.login');
      expect(bridge.calls.last['params'], {'service': 'canvas'});
      expect(
        bridge.calls
            .where((c) => c['method'] == 'canvas.conversation.create')
            .length,
        1,
      );
      expect(find.text('保留主题'), findsOneWidget);
      expect(find.text('保留正文'), findsOneWidget);
      expect(find.widgetWithText(InputChip, '老师'), findsOneWidget);
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      final sends = bridge.calls
          .where((c) => c['method'] == 'canvas.conversation.create')
          .toList();
      expect(sends.length, 2);
      expect(sends.last['params'], {
        'course_id': '10',
        'recipients': ['30'],
        'subject': '保留主题',
        'body': '保留正文',
      });
    },
  );

  testWidgets('failed CSRF login keeps draft and never automatically resends', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('课程问题'));
    await tester.pumpAndSettle();
    bridge.handler = (method, _) async => throw Exception(
      method == 'campus.login'
          ? 'AuthenticationRequired'
          : 'CanvasCsrfRequired',
    );
    await tester.enterText(find.byKey(const Key('chat-body')), '待恢复草稿');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新 Canvas 统一登录'));
    await tester.pumpAndSettle();
    expect(find.text('待恢复草稿'), findsOneWidget);
    expect(find.text('登录 Canvas'), findsOneWidget);
    expect(find.text('绑定 Canvas 令牌'), findsNothing);
    expect(
      bridge.calls
          .where((c) => c['method'] == 'canvas.conversation.reply')
          .length,
      1,
    );
  });

  testWidgets('account switch clears draft and rejects late read', (
    tester,
  ) async {
    await mount(tester);
    final pending = Completer<dynamic>();
    bridge.handler = (_, _) => pending.future;
    await tester.tap(find.text('课程问题'));
    await tester.pump();
    app.changeTestAccount();
    await tester.pump();
    pending.complete(record(conversation(body: '旧账号秘密')));
    await tester.pumpAndSettle();
    expect(find.text('旧账号秘密'), findsNothing);
    expect(find.text('课程问题'), findsNothing);
    expect(find.text('账号已切换，请返回并重新打开站内消息。'), findsOneWidget);
    expect(find.text('发送'), findsNothing);
  });

  testWidgets('account switch clears active composer and recipient', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('新建消息'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-body')), '旧草稿');
    app.changeTestAccount();
    await tester.pumpAndSettle();
    expect(find.text('旧草稿'), findsNothing);
    expect(find.text('发送'), findsNothing);
    expect(
      bridge.calls.where((c) => c['method'] == 'canvas.conversation.create'),
      isEmpty,
    );
  });

  testWidgets('disposed page ignores late response', (tester) async {
    final pending = Completer<dynamic>();
    bridge.handler = (_, _) => pending.future;
    await tester.pumpWidget(
      MaterialApp(home: LearningChatPage(controller: controller)),
    );
    await tester.pumpWidget(const SizedBox());
    pending.complete([record(conversation())]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('login and retry recover loading failure', (tester) async {
    bridge.handler = (_, _) async => throw Exception('AuthenticationRequired');
    await mount(tester);
    expect(find.text('登录 Canvas'), findsOneWidget);
    bridge.handler = (method, _) async =>
        method == 'campus.login' ? {} : [conversation()];
    await tester.tap(find.text('登录 Canvas'));
    await tester.pumpAndSettle();
    expect(find.text('课程问题'), findsOneWidget);
  });

  testWidgets('uncertain write preserves draft and disables resending', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('课程问题'));
    await tester.pumpAndSettle();
    bridge.handler = (_, _) async => throw Exception('NeedsReconciliation');
    await tester.enterText(find.byKey(const Key('chat-body')), '待核对回复');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.textContaining('发送结果未确认'), findsOneWidget);
    expect(find.text('待核对回复'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
          .onPressed,
      isNull,
    );
  });
}
