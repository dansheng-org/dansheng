import 'dart:async';
import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/learning/learning_controller.dart';
import 'package:dansheng_app/ui/campus/learning/learning_page.dart';
import 'package:dansheng_app/ui/campus/learning/models/canvas_models.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements DanshengBridge {
  final Future<dynamic> Function(String, Map<String, dynamic>) call;
  _Bridge(this.call);
  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final request = jsonDecode(payload) as Map;
    return jsonEncode(
      await call(
        request['method'] as String,
        Map<String, dynamic>.from(request['params'] as Map),
      ),
    );
  }
}

const current = {
  'external_id': 'current',
  'name': '2026-2027学年第一学期',
  'starts_on': '2026-09-07',
};
const past = {
  'external_id': 'past',
  'name': '2025-2026学年第二学期',
  'starts_on': '2026-02-23',
};
const future = {
  'external_id': 'future',
  'name': '2026-2027学年第二学期',
  'starts_on': '2027-02-22',
};
final clock = DateTime.utc(2026, 11, 14);
const courseRecords = [
  {
    'id': '1',
    'name': '本学期测试课',
    'term': {'name': '2026秋季学期'},
  },
  {
    'id': '2',
    'name': '历史测试课',
    'term': {'name': '2026春季学期'},
  },
  {'id': '3', 'name': '未标学期测试课'},
];

class _StudentApp extends DanshengController {
  _StudentApp({required super.client});
  @override
  String? get activeAccountId => '26300000000';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('term aliases, dates, future and undated courses', () {
    final day = DateTime(2026, 11, 14);
    expect(CanvasCourse.termKey('2026-2027学年第一学期'), '2026:1');
    expect(CanvasCourse.termKey('2027春季'), '2026:2');
    expect(CanvasCourse.termKey('2026-2027-1 MATH'), '2026:1');
    expect(CanvasCourse.termKey('2026-2027学年1学期'), '2026:1');
    expect(CanvasCourse.termKey('2026-2027学年2学期'), '2026:2');
    expect(CanvasCourse.fromJson(courseRecords[0]).belongsToTerm(day), isTrue);
    expect(CanvasCourse.fromJson(courseRecords[1]).belongsToTerm(day), isFalse);
    expect(CanvasCourse.fromJson(courseRecords[2]).belongsToTerm(day), isFalse);
    final dated = CanvasCourse.fromJson({
      'id': '4',
      'name': '课程',
      'term': {
        'start_at': '2026-09-01T00:00:00+08:00',
        'end_at': '2027-01-01T00:00:00+08:00',
      },
    });
    expect(dated.belongsToTerm(day), isTrue);
    expect(dated.belongsToTerm(DateTime(2027, 1, 1)), isFalse);
    final futureCourse = CanvasCourse.fromJson({
      'id': '5',
      'name': '课程',
      'term': {'name': '2026秋季学期', 'start_at': '2026-12-01T00:00:00+08:00'},
    });
    expect(futureCourse.belongsToTerm(day), isFalse);
  });

  test('current semester ignores future default; archive details stay out of agenda', () async {
    final detailIds = <String>[];
    final owner = _StudentApp(
      client: DanshengClient(
        bridge: _Bridge((method, params) async {
          if (method == 'fudan.semesters') {
            return {
              'semesters': [future, past, current],
              'default_semester_id': 'future',
            };
          }
          if (method == 'fudan.timetable.sync') {
            expect(params['semester']['external_id'], 'current');
            return {'semester': current, 'courses': []};
          }
          if (method == 'canvas.courses.sync') return courseRecords;
          if (method == 'canvas.assignments.sync') {
            detailIds.add(params['course_id'] as String);
            return [
              {'id': '10', 'name': '作业', 'due_at': '2026-11-14T10:00:00Z'},
            ];
          }
          return [];
        }),
      ),
    );
    final ctrl = LearningController(appController: owner, now: () => clock);
    await ctrl.loadAll();
    expect(ctrl.selectedSemester?.externalId, 'current');
    expect(ctrl.courses.map((c) => c.id), ['1']);
    expect(ctrl.archivedCourses.map((c) => c.id), ['2', '3']);
    expect(detailIds, ['1']);
    await ctrl.loadCourseDetails('2');
    expect(ctrl.allAssignments.map((a) => a.courseId), ['1']);
    ctrl.dispose();
    owner.dispose();
  });

  test('missing cached timetable remains an error', () async {
    final owner = _StudentApp(
      client: DanshengClient(
        bridge: _Bridge((method, params) async {
          if (method == 'fudan.semesters') {
            return {
              'semesters': [current],
            };
          }
          if (method == 'fudan.timetable.sync') throw Exception('Network');
          return null;
        }),
      ),
    );
    final ctrl = LearningController(appController: owner, now: () => clock);
    await ctrl.loadAcademic();
    expect(ctrl.academicError, isNotNull);
    expect(ctrl.academicFromCache, isFalse);
    expect(ctrl.timetableData, isNull);
    ctrl.dispose();
    owner.dispose();
  });

  test(
    'an old cached catalog cannot promote past Canvas courses to current',
    () async {
      final owner = _StudentApp(
        client: DanshengClient(
          bridge: _Bridge((method, params) async {
            if (method == 'fudan.semesters') {
              return {
                'semesters': [past],
              };
            }
            if (method == 'fudan.timetable.sync') {
              return {'semester': past, 'courses': []};
            }
            if (method == 'canvas.courses.sync') return courseRecords;
            return [];
          }),
        ),
      );
      final ctrl = LearningController(appController: owner, now: () => clock);
      await ctrl.loadAll();
      expect(ctrl.currentSemester, isNull);
      expect(ctrl.courses.map((c) => c.id), ['1']);
      ctrl.dispose();
      owner.dispose();
    },
  );

  test(
    'slow older semester response cannot replace the new selection',
    () async {
      final pending = Completer<dynamic>();
      var calls = 0;
      final owner = _StudentApp(
        client: DanshengClient(
          bridge: _Bridge((method, params) async {
            if (method == 'fudan.semesters') {
              return {
                'semesters': [current, past],
              };
            }
            if (method == 'fudan.timetable.sync') {
              calls++;
              if (calls == 2) return pending.future;
              return {'semester': params['semester'], 'courses': []};
            }
            return [];
          }),
        ),
      );
      final ctrl = LearningController(appController: owner, now: () => clock);
      await ctrl.loadAcademic();
      ctrl.selectSemester(ctrl.semesters.last);
      ctrl.selectSemester(ctrl.semesters.first);
      await Future<void>.delayed(Duration.zero);
      pending.complete({'semester': past, 'courses': []});
      await Future<void>.delayed(Duration.zero);
      expect(ctrl.selectedSemester?.externalId, 'current');
      expect(ctrl.timetableData?.semester?.externalId, 'current');
      expect(ctrl.academicError, isNull);
      ctrl.dispose();
      owner.dispose();
    },
  );

  testWidgets('past courses live on a secondary page and remain openable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final owner = _StudentApp(
      client: DanshengClient(
        bridge: _Bridge((method, params) async {
          if (method == 'fudan.semesters') {
            return {
              'semesters': [current],
            };
          }
          if (method == 'fudan.timetable.sync') {
            return {'semester': current, 'courses': []};
          }
          if (method == 'canvas.courses.sync') return courseRecords;
          return [];
        }),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LearningPage(controller: owner, now: () => clock),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本学期测试课'), findsOneWidget);
    expect(find.text('历史测试课'), findsNothing);
    expect(find.text('未标学期测试课'), findsNothing);
    await tester.tap(find.text('过往学期与其他课程'));
    await tester.pumpAndSettle();
    expect(find.text('历史测试课'), findsOneWidget);
    expect(find.text('未标学期测试课'), findsOneWidget);
    await tester.tap(find.text('历史测试课'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('课程聊天'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    owner.dispose();
  });
}
