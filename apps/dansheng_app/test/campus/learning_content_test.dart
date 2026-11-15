import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/learning/learning_controller.dart';
import 'package:dansheng_app/ui/campus/learning/models/canvas_models.dart';
import 'package:dansheng_app/ui/campus/learning/models/timetable_models.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements DanshengBridge {
  final calls = <(String, Map)>[];
  final Map<String, dynamic Function(Map params)> responses = {};
  final Map<String, dynamic> cache = {};

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final request = jsonDecode(payload) as Map;
    final method = request['method'] as String;
    final params = request['params'] as Map;
    calls.add((method, params));
    if (method == 'campus.cached') {
      final hit = cache[params['method']];
      return jsonEncode(hit is Function ? hit(params) : hit);
    }
    final respond = responses[method];
    if (respond == null) throw PlatformException(code: 'SourceHttpError');
    return jsonEncode(respond(params));
  }
}

class _App extends DanshengController {
  _App(_Bridge bridge, this.account)
    : super(client: DanshengClient(bridge: bridge));
  final String account;
  @override
  String? get activeAccountId => account;
}

TimetableCourse _lesson(String? lessonId) => TimetableCourse(
  name: '高等数学',
  weekday: 1,
  startUnit: 1,
  endUnit: 2,
  weeks: const [1],
  lessonId: lessonId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('plain text keeps structure and never keeps markup', () {
    expect(
      plainText(
        '<p>第一段&nbsp;<b>粗体</b></p><ul><li>甲</li><li>乙</li></ul>'
        '<script>alert(1)</script>a&lt;b &amp; c&#x4E2D;',
      ),
      '第一段 粗体\n• 甲\n• 乙\na<b & c中',
    );
    expect(plainText(null), '');
  });

  test('own submission status distinguishes handed-in, late and missing', () {
    CanvasSubmission s(Map<String, dynamic> p) =>
        CanvasSubmission.fromJson({'payload': p});
    expect(s({'workflow_state': 'unsubmitted'}).statusLabel, '未提交');
    expect(s({'workflow_state': 'unsubmitted'}).isDone, isFalse);
    expect(
      s({'workflow_state': 'submitted', 'submitted_at': '2026-11-01T00:00:00Z'})
          .statusLabel,
      '已提交',
    );
    expect(
      s({
        'workflow_state': 'submitted',
        'submitted_at': '2026-11-01T00:00:00Z',
        'late': true,
      }).statusLabel,
      '迟交',
    );
    expect(s({'missing': true}).statusLabel, '缺交');
    expect(s({'excused': true}).isDone, isTrue);
    expect(s({'workflow_state': 'graded', 'score': 8.5}).scoreLabel, '8.5 分');
  });

  test('module items, pages and discussion threads load on demand', () async {
    final bridge = _Bridge();
    bridge.responses['canvas.module_items.sync'] = (p) => [
      {
        'payload': {
          'id': '2',
          'title': '第二讲',
          'type': 'Page',
          'page_slug': 'lecture-2',
          'position': 2,
        },
      },
      {
        'payload': {
          'id': '1',
          'title': '讲义',
          'type': 'File',
          'content_id': '55',
          'position': 1,
        },
      },
    ];
    bridge.responses['canvas.page.read'] = (p) => {
      'external_id': 'page:1:lecture-2',
      'payload': {
        'page_slug': p['page_slug'],
        'title': '第二讲',
        'body': '<h2>目标</h2><p>理解极限</p>',
      },
    };
    bridge.responses['canvas.discussion.view'] = (p) => [
      {
        'payload': {
          'view': [
            {
              'id': '1',
              'user_id': '7',
              'message': '<p>请问第三题</p>',
              'replies': [
                {'id': '2', 'user_id': '8', 'parent_id': '1', 'message': '见讲义'},
              ],
            },
          ],
          'participants': [
            {'id': '7', 'display_name': '同学甲'},
            {'id': '8', 'display_name': '助教'},
          ],
          'unread_entries': ['2'],
        },
      },
    ];
    final app = _App(bridge, '24300000000');
    final ctrl = LearningController(appController: app);

    await ctrl.loadModuleItems('10', '3');
    final items = ctrl.moduleItems('10', '3')!;
    expect(items.map((i) => i.title), ['讲义', '第二讲']);
    expect(items.first.contentId, '55');
    expect(bridge.calls.last.$2, {
      'course_id': '10',
      'module_id': '3',
      'account_id': app.account,
    });

    final page = await ctrl.readPage('10', 'lecture-2');
    expect(page.text, '目标\n理解极限');

    final thread = await ctrl.readDiscussionThread('10', '9');
    expect(thread.count, 2);
    expect(thread.participants['8'], '助教');
    expect(thread.unreadIds, {'2'});
    expect(thread.entries.single.text, '请问第三题');

    ctrl.dispose();
    app.dispose();
  });

  test('a failed page read falls back to the cached copy', () async {
    final bridge = _Bridge();
    bridge.cache['canvas.page.read'] = {
      'payload': {'page_slug': 'a', 'title': '缓存页面', 'body': '内容'},
    };
    final app = _App(bridge, '24300000000');
    final ctrl = LearningController(appController: app);
    expect((await ctrl.readPage('10', 'a')).title, '缓存页面');
    ctrl.dispose();
    app.dispose();
  });

  test('syllabus is offered only for undergraduate lessons', () async {
    final bridge = _Bridge();
    bridge.responses['fudan.catalog.syllabus'] = (p) => {
      'lesson_id': p['lesson_id'],
      'text_coverage': 'partial',
      'sections': [
        {'title': '课程目标', 'text': '<p>掌握微积分</p>'},
        {'title': '空白', 'text': ' '},
      ],
    };
    final ug = _App(bridge, '24300000000');
    final ugCtrl = LearningController(appController: ug);
    expect(ugCtrl.hasSyllabus(_lesson('700001')), isTrue);
    expect(ugCtrl.hasSyllabus(_lesson(null)), isFalse);
    final syllabus = await ugCtrl.readSyllabus(_lesson('700001'));
    expect(syllabus.sections, [('课程目标', '掌握微积分')]);
    expect(bridge.calls.last.$2, {
      'lesson_id': '700001',
      'account_id': ug.account,
    });

    final pg = _App(bridge, '24100000000');
    final pgCtrl = LearningController(appController: pg);
    expect(pgCtrl.hasSyllabus(_lesson('700001')), isFalse);

    for (final c in [ugCtrl, pgCtrl]) {
      c.dispose();
    }
    ug.dispose();
    pg.dispose();
  });

  test(
    'a course without quizzes or discussions shows no sign-in prompt',
    () async {
      final bridge = _Bridge();
      bridge.responses['canvas.courses.sync'] = (_) => [
        {
          'id': '10',
          'name': '课程',
          'term': {
            'start_at': '2026-09-01T00:00:00Z',
            'end_at': '2027-01-31T00:00:00Z',
          },
        },
      ];
      bridge.responses['canvas.assignments.sync'] = (_) => [
        {
          'id': '1',
          'course_id': '10',
          'name': '作业',
          'due_at': '2026-11-20T00:00:00Z',
        },
      ];
      bridge.responses['canvas.announcements.sync'] = (_) => [];
      // Quizzes and the submission read fail like a disabled course tool.
      final app = _App(bridge, '24300000000');
      final ctrl = LearningController(
        appController: app,
        now: () => DateTime.utc(2026, 11, 14),
      );
      await ctrl.loadCanvas();
      expect(ctrl.canvasAuthRequired, isFalse);
      expect(ctrl.detailsError('10'), isNull);
      expect(ctrl.optionalError('canvas.quizzes.sync', '10'), isNotNull);
      final work = ctrl.courseWork('10').single;
      expect(ctrl.submissionFor(work), isNull);
      // Unknown status still counts as owed so the deadline stays visible.
      expect(ctrl.isOutstanding(work), isTrue);
      expect(
        bridge.calls.where((c) => c.$1 == 'canvas.submission.self'),
        hasLength(1),
      );
      ctrl.dispose();
      app.dispose();
    },
  );

  test(
    'old assignments get their status and a cached hand-in survives restart',
    () async {
      final bridge = _Bridge();
      bridge.responses['canvas.courses.sync'] = (_) => [
        {
          'id': '10',
          'name': '课程',
          'term': {
            'start_at': '2026-09-01T00:00:00Z',
            'end_at': '2027-01-31T00:00:00Z',
          },
        },
      ];
      bridge.responses['canvas.assignments.sync'] = (_) => [
        for (final (id, due) in [
          ('1', '2026-10-10T00:00:00Z'),
          ('2', '2026-10-20T00:00:00Z'),
          ('3', '2026-11-12T00:00:00Z'),
        ])
          {'id': id, 'course_id': '10', 'name': '作业$id', 'due_at': due},
      ];
      bridge.responses['canvas.announcements.sync'] = (_) => [];
      Map<String, dynamic> submitted(Map p) => {
        'assignment_id': p['assignment_id'],
        'workflow_state': 'submitted',
        'submitted_at': '2026-10-01T00:00:00Z',
      };
      // Earlier session: assignment 1 was seen handed in.
      bridge.cache['canvas.submission.self'] = (Map p) =>
          p['assignment_id'] == '1' ? [submitted(p)] : null;
      bridge.responses['canvas.submission.self'] = (p) => [submitted(p)];
      final app = _App(bridge, '24300000000');
      final ctrl = LearningController(
        appController: app,
        now: () => DateTime.utc(2026, 11, 14),
      );
      await ctrl.loadCanvas();
      for (final work in ctrl.courseWork('10')) {
        expect(ctrl.isOutstanding(work), isFalse, reason: work.name);
      }
      // Known-done old work is not re-read; the rest is.
      expect(
        bridge.calls
            .where((c) => c.$1 == 'canvas.submission.self')
            .map((c) => c.$2['assignment_id']),
        unorderedEquals(['2', '3']),
      );
      ctrl.dispose();
      app.dispose();
    },
  );
}
