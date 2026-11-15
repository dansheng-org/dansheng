import 'dart:async';
import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/campus/learning/cloud/cloud_drive_page.dart';
import 'package:dansheng_app/ui/campus/learning/cloud/drive_backend.dart';
import 'package:dansheng_app/ui/campus/learning/learning_controller.dart';
import 'package:dansheng_app/ui/campus/learning/widgets/course_content_pages.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements DanshengBridge {
  final calls = <(String, Map)>[];
  final responses = <String, FutureOr<dynamic> Function(Map)>{};
  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final request = jsonDecode(payload) as Map;
    final method = request['method'] as String;
    final params = request['params'] as Map;
    calls.add((method, params));
    return jsonEncode(await responses[method]?.call(params));
  }
}

class _App extends DanshengController {
  _App(_Bridge bridge) : super(client: DanshengClient(bridge: bridge));
  String account = '24300000000';
  bool changing = false;
  @override
  bool get isChangingAccount => changing;
  @override
  String get activeAccountId => account;
  void change(String value) {
    account = value;
    notifyListeners();
  }
}

final _changed = isA<PlatformException>().having(
  (e) => e.code,
  'code',
  'AccountChanged',
);

Future<void> _push(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => page)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a scope opened during account transition never becomes usable later',
    () {
      final app = _App(_Bridge())..changing = true;
      final old = CampusApi.forAccount(app);
      app.changing = false;
      app.change(app.account);
      expect(old.isCurrent, isFalse);
      final fresh = CampusApi.forAccount(app);
      expect(fresh.isCurrent, isTrue);
      old.accountScope!.dispose();
      fresh.accountScope!.dispose();
      app.dispose();
    },
  );

  test('account failures never fall back to another account cache', () async {
    final bridge = _Bridge();
    bridge.responses['canvas.page.read'] = (_) =>
        throw PlatformException(code: 'AccountChanged');
    bridge.responses['campus.cached'] = (_) => {
      'title': 'wrong account',
      'body': 'private',
    };
    final app = _App(bridge);
    final ctrl = LearningController(appController: app);
    await expectLater(ctrl.readPage('10', 'page'), throwsA(_changed));
    expect(bridge.calls.map((c) => c.$1), ['canvas.page.read']);
    expect(bridge.calls.single.$2['account_id'], app.account);
    ctrl.dispose();
    app.dispose();
  });

  test('an old read and backend stay invalid after A to B to A', () async {
    final bridge = _Bridge();
    final pending = Completer<dynamic>();
    bridge.responses['canvas.page.read'] = (_) => pending.future;
    final app = _App(bridge);
    final ctrl = LearningController(appController: app);
    final oldDrive = FudanCloudBackend(ctrl.api);
    final result = ctrl.readPage('10', 'page');
    final rejected = expectLater(result, throwsA(_changed));
    final original = app.account;
    app.change('B');
    app.change(original);
    pending.complete({'title': 'old A', 'body': 'private'});
    await rejected;
    await expectLater(
      oldDrive.createFolder('/', 'wrong account'),
      throwsA(_changed),
    );
    expect(bridge.calls.map((c) => c.$1), ['canvas.page.read']);
    ctrl.dispose();
    app.dispose();
  });

  testWidgets('account changes withdraw a pending content route', (
    tester,
  ) async {
    final bridge = _Bridge();
    final pending = Completer<dynamic>();
    bridge.responses['canvas.page.read'] = (_) => pending.future;
    final app = _App(bridge);
    final ctrl = LearningController(appController: app);
    await _push(
      tester,
      CanvasPageScreen(
        controller: ctrl,
        courseId: '10',
        slug: 'page',
        title: 'page',
      ),
    );
    expect(find.byType(CanvasPageScreen), findsOneWidget);
    app.change('B');
    await tester.pumpAndSettle();
    expect(find.byType(CanvasPageScreen), findsNothing);
    pending.complete({'title': 'old A', 'body': 'private'});
    await tester.pumpAndSettle();
    expect(find.text('private'), findsNothing);
    expect(bridge.calls.where((c) => c.$1 == 'campus.cached'), isEmpty);
    expect(tester.takeException(), isNull);
    ctrl.dispose();
    app.dispose();
  });

  testWidgets(
    'account change closes drive and delete confirmation without writing',
    (tester) async {
      final bridge = _Bridge();
      bridge.responses['fudan.cloud.roots'] = (_) => [
        {'name': 'root', 'path': '3/42/directory/'},
      ];
      bridge.responses['fudan.cloud.list'] = (_) => {
        'items': [
          {
            'name': 'a.txt',
            'path': '3/42/directory/a.txt',
            'downloadable': true,
          },
        ],
      };
      final app = _App(bridge);
      final api = CampusApi.forAccount(app);
      await _push(tester, CloudDrivePage(drive: FudanCloudBackend(api)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      app.change('B');
      await tester.pumpAndSettle();
      expect(find.byType(CloudDrivePage), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.calls.where((c) => c.$1 == 'fudan.cloud.delete'), isEmpty);
      expect(tester.takeException(), isNull);
      api.accountScope!.dispose();
      app.dispose();
    },
  );

  testWidgets('local upload limit has a distinct 5 MiB message', (
    tester,
  ) async {
    final bridge = _Bridge();
    bridge.responses['fudan.cloud.roots'] = (_) => [
      {'name': 'root', 'path': '3/42/directory/'},
    ];
    bridge.responses['fudan.cloud.list'] = (_) => {'items': []};
    bridge.responses['campus.uploadLocalFile'] = (_) =>
        throw PlatformException(code: 'LocalUploadTooLarge');
    await tester.pumpWidget(
      MaterialApp(
        home: CloudDrivePage(
          drive: FudanCloudBackend(CampusApi(DanshengClient(bridge: bridge))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('上传文件'));
    await tester.pumpAndSettle();
    expect(find.text('本地文件超过 5 MiB，暂不支持上传'), findsOneWidget);
  });

  test(
    'course refresh updates cached statuses and old assignment scores',
    () async {
      final bridge = _Bridge();
      var fresh = false;
      bridge.responses['canvas.courses.sync'] = (_) => [
        {
          'id': '10',
          'name': 'course',
          'term': {
            'start_at': '2026-09-01T00:00:00Z',
            'end_at': '2027-01-31T00:00:00Z',
          },
        },
      ];
      bridge.responses['canvas.assignments.sync'] = (_) => [
        {'id': '1', 'name': 'upcoming', 'due_at': '2026-11-20T00:00:00Z'},
        {'id': '2', 'name': 'older', 'due_at': '2026-09-20T00:00:00Z'},
      ];
      bridge.responses['canvas.announcements.sync'] = (_) => [];
      bridge.responses['canvas.quizzes.sync'] = (_) => [];
      bridge.responses['canvas.submission.self'] = (p) => [
        {
          'assignment_id': p['assignment_id'],
          'workflow_state': fresh ? 'graded' : 'unsubmitted',
          if (fresh) 'score': 9,
        },
      ];
      final app = _App(bridge);
      final ctrl = LearningController(
        appController: app,
        now: () => DateTime.utc(2026, 11, 14),
      );
      await ctrl.loadCanvas();
      final work = ctrl.courseWork('10');
      expect(work, hasLength(2));
      await ctrl.loadSubmissions(
        work,
      ); // The grades tab loaded the old assignment too.
      expect(ctrl.submissionFor(work.first)!.isDone, isFalse);
      fresh = true;
      await ctrl.loadCourseDetails('10');
      for (final a in work) {
        expect(ctrl.submissionFor(a)!.isDone, isTrue);
        expect(ctrl.submissionFor(a)!.score, 9);
      }
      ctrl.dispose();
      app.dispose();
    },
  );
}
