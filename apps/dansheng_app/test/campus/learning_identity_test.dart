import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/learning/learning_controller.dart';
import 'package:dansheng_app/ui/campus/learning/learning_page.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/screens/account_balance_screen.dart';
import 'package:dansheng_app/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _semester = {
  'external_id': '1',
  'name': '2026-2027学年第一学期',
  'starts_on': '2026-09-07',
};

class _Bridge implements DanshengBridge {
  final calls = <String>[];
  bool calendarUnavailable = false;
  @override
  Future<String> invoke(HostCommand command, String payload) async {
    if (command != HostCommand.campus) return '{}';
    final request = jsonDecode(payload) as Map;
    final method = request['method'] as String;
    calls.add(method);
    if (method == 'fudan.postgraduate.semester' && calendarUnavailable) {
      throw PlatformException(code: 'SemesterCalendarUnavailable');
    }
    return jsonEncode(switch (method) {
      'fudan.postgraduate.semester' => _semester,
      'fudan.semesters' => {
        'semesters': [_semester],
      },
      'fudan.timetable.sync' ||
      'fudan.postgraduate.sync' => {'semester': _semester, 'courses': []},
      _ => [],
    });
  }
}

class _App extends DanshengController {
  _App(_Bridge bridge, this.account)
    : super(client: DanshengClient(bridge: bridge));
  String? account;
  @override
  String? get activeAccountId => account;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'an unverified PG semester cannot be replaced with an old cached calendar',
    () async {
      final bridge = _Bridge()..calendarUnavailable = true;
      final app = _App(bridge, '26100000000');
      final ctrl = LearningController(appController: app);
      await ctrl.loadAcademic();
      expect(ctrl.academicError, contains('校历尚未确认'));
      expect(bridge.calls, ['fudan.postgraduate.semester']);
      expect(ctrl.timetableData, isNull);
      ctrl.dispose();
      app.dispose();
    },
  );
  test(
    'the third digit selects the academic source; unknown IDs are not guessed',
    () {
      expect(LearningController.undergraduateForAccount('26100000000'), false);
      expect(LearningController.undergraduateForAccount('26200000000'), false);
      expect(LearningController.undergraduateForAccount('26300000000'), true);
      for (final invalid in [null, '', '26', '26400000000', 'account-263000']) {
        expect(LearningController.undergraduateForAccount(invalid), null);
      }
    },
  );

  test('account changes recompute the source and unknown accounts can still load Canvas', () async {
    final bridge = _Bridge();
    final app = _App(bridge, '26300000000');
    final ctrl = LearningController(
      appController: app,
      now: () => DateTime.utc(2026, 11, 14),
    );
    await ctrl.loadAcademic();
    expect(bridge.calls, contains('fudan.timetable.sync'));
    for (final id in ['26100000000', '26200000000']) {
      bridge.calls.clear();
      app.account = id;
      ctrl.checkAccountChange();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.calls, contains('fudan.postgraduate.sync'));
      expect(bridge.calls, isNot(contains('fudan.timetable.sync')));
      expect(bridge.calls, isNot(contains('fudan.semesters')));
    }
    bridge.calls.clear();
    app.account = 'unknown';
    ctrl.checkAccountChange();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls.where((m) => m.startsWith('fudan.')), isEmpty);
    expect(bridge.calls, contains('canvas.courses.sync'));
    expect(ctrl.academicError, contains('有效学号'));
    ctrl.dispose();
    app.dispose();
  });

  testWidgets(
    'eLearning uses the same account and settings destinations without technical selectors',
    (tester) async {
      final app = _App(_Bridge(), '26300000000');
      await tester.pumpWidget(MaterialApp(home: LearningPage(controller: app)));
      await tester.pumpAndSettle();
      expect(find.byTooltip('设置'), findsOneWidget);
      expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
      for (final label in ['本科生', '研究生', '主端', '次端', '课表设置', '服务选项']) {
        expect(find.text(label), findsNothing);
      }
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('账号与校园卡'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountBalanceScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );
}
