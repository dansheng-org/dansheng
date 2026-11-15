// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dansheng_app/bridge.g.dart';

import 'dart:convert';

import 'package:dansheng_app/ui/campus/learning/learning_page.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';

/// Test bridge satisfying DanshengBridge.
class _TestBridge implements DanshengBridge {
  static Future<dynamic> Function(String method, Map<String, dynamic> params)?
  handler;
  @override
  Future<String> invoke(HostCommand command, String payload) async {
    if (command == HostCommand.campus && handler != null) {
      final request = jsonDecode(payload) as Map;
      return jsonEncode(
        await handler!(
          request['method'] as String,
          Map<String, dynamic>.from(request['params'] as Map),
        ),
      );
    }
    return '{}';
  }
}

class _StudentApp extends DanshengController {
  _StudentApp({required super.client, this.account = '26300000000'});
  final String account;
  @override
  String? get activeAccountId => account;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Test Fixtures matching connectors core adapter shapes
  final semestersFixture = {
    'semesters': [
      {
        'external_id': '423',
        'name': '2026-2027学年第一学期',
        'starts_on': '2026-11-02',
      },
      {
        'external_id': '422',
        'name': '2025-2026学年第二学期',
        'starts_on': '2026-02-23',
      },
    ],
    'default_semester_id': '423',
  };

  final ugTimetableFixture = {
    'source': {
      'account_id': 'user-42',
      'source_id': 'fudan-timetable',
      'observed_at': '2026-11-08T00:00:00Z',
    },
    'semester': {
      'external_id': '423',
      'name': '2026-2027学年第一学期',
      'starts_on': '2026-11-02',
    },
    'timezone': 'Asia/Shanghai',
    'courses': [
      {
        'account_id': 'user-42',
        'source_id': 'fudan-timetable',
        'external_id': 'activity:700001',
        'observed_at': '2026-11-08T00:00:00Z',
        'payload': {
          'lesson_id': '700001',
          'course_code': 'SYNTH101.01',
          'name': '高等数学',
          'teachers': ['张教授', '李老师'],
          'room': '光华楼西主楼101',
          'weekday': 7, // Sunday
          'start_unit': 1,
          'end_unit': 2,
          'weeks': [1, 2, 3, 4],
        },
      },
      {
        'account_id': 'user-42',
        'source_id': 'fudan-timetable',
        'external_id': 'activity:700002',
        'observed_at': '2026-11-08T00:00:00Z',
        'payload': {
          'lesson_id': '700002',
          'course_code': 'SYNTH102.01',
          'name': '大学物理',
          'teachers': ['王教授'],
          'room': '二教201',
          'weekday': 1, // Monday
          'start_unit': 3,
          'end_unit': 4,
          'weeks': [1, 2, 3, 4],
        },
      },
      {
        'account_id': 'user-42',
        'source_id': 'fudan-timetable',
        'external_id': 'activity:700003',
        'observed_at': '2026-11-08T00:00:00Z',
        'payload': {
          'lesson_id': '700003',
          'course_code': 'SYNTH103.01',
          'name': '入学前导论课',
          'teachers': ['赵老师'],
          'room': '三教101',
          'weekday': 7, // Sunday spillover (week 0)
          'start_unit': 1,
          'end_unit': 2,
          'weeks': [0],
        },
      },
    ],
  };

  final pgTimetableFixture = {
    'source': {
      'account_id': 'user-42',
      'source_id': 'fudan-pg-timetable',
      'observed_at': '2026-11-08T00:00:00Z',
    },
    'semester': {
      'external_id': '423',
      'name': '2026-2027学年第一学期',
      'starts_on': '2026-11-02',
    },
    'timezone': 'Asia/Shanghai',
    'courses': [
      {
        'account_id': 'user-42',
        'source_id': 'fudan-pg-timetable',
        'external_id': 'pg:900001',
        'observed_at': '2026-11-08T00:00:00Z',
        'payload': {
          'lesson_id': '900001',
          'course_code': 'COMP801',
          'name': '高级算法设计',
          'teachers': ['陈教授'],
          'room': '交叉二号楼A301',
          'weekday': 7,
          'start_unit': 6,
          'end_unit': 8,
          'weeks': [1, 2, 3, 4],
        },
      },
    ],
  };

  final canvasCoursesFixture = [
    {
      'id': '81001',
      'name': '计算机系统导论',
      'course_code': 'CS-101',
      'workflow_state': 'available',
      'term': {'id': '91001', 'name': '2026秋季学期'},
    },
    {
      'id': '81002',
      'name': '算法与数据结构',
      'course_code': 'CS-102',
      'workflow_state': 'available',
    },
  ];

  final canvasAssignmentsFixture = [
    {
      'id': '82001',
      'course_id': '81001',
      'name': '第1次上机实验报告',
      'due_at': '2026-11-08T23:59:00+08:00',
      'points_possible': 100.0,
      'submission_types': ['online_upload'],
      'has_submitted_submissions': false,
      'locked_for_user': false,
      'description': '完成实验一的全部要求，附带代码与运行截图。',
    },
    {
      'id': '82002',
      'course_id': '81001',
      'name': '课后习题二',
      'due_at': '2026-11-15T23:59:00+08:00',
      'points_possible': 10.0,
      'submission_types': ['online_text_entry'],
      'has_submitted_submissions': true,
      'locked_for_user': false,
    },
  ];

  final canvasFoldersFixture = [
    {
      'id': '1001',
      'name': '课程课件与讲义',
      'parent_folder_id': null,
      'files_count': 1,
      'folders_count': 1,
    },
    {
      'id': '1002',
      'name': '第1周 绪论',
      'parent_folder_id': '1001',
      'files_count': 1,
      'folders_count': 0,
    },
  ];

  final canvasMaterialsFixture = [
    {
      'id': '83000',
      'course_id': '81001',
      'folder_id': null,
      'display_name': '课程指引.pdf',
      'filename': 'guide.pdf',
      'content-type': 'application/pdf',
      'size': 51200,
      'updated_at': '2026-10-30T00:00:00Z',
      'locked_for_user': false,
    },
    {
      'id': '83001',
      'course_id': '81001',
      'folder_id': '1001',
      'display_name': '课程大纲.pdf',
      'filename': 'syllabus.pdf',
      'content-type': 'application/pdf',
      'size': 102400,
      'updated_at': '2026-11-01T00:00:00Z',
      'locked_for_user': false,
    },
    {
      'id': '83002',
      'course_id': '81001',
      'folder_id': '1002',
      'display_name': '第1讲-绪论课件.pdf',
      'filename': 'lecture1.pdf',
      'content-type': 'application/pdf',
      'size': 2048000,
      'updated_at': '2026-11-02T00:00:00Z',
      'locked_for_user': false,
    },
  ];

  final canvasModulesFixture = [
    {
      'id': '92001',
      'course_id': '81001',
      'name': '第1模块：计算机系统概览',
      'position': 1,
      'items_count': 3,
      'state': 'completed',
    },
  ];

  final canvasAnnouncementsFixture = [
    {
      'id': '85001',
      'course_id': '81001',
      'title': '关于第1次实验的提交说明',
      'message': '请同学们在周日23:59前提交实验代码与报告PDF。',
      'posted_at': '2026-11-05T10:00:00Z',
      'user_name': '助教小张',
    },
  ];

  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(
      1080,
      2400,
    );
    binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });

  tearDown(() {
    _TestBridge.handler = null;
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.resetPhysicalSize();
    binding.platformDispatcher.views.first.resetDevicePixelRatio();
  });

  group('LearningPage Complete Test Suite', () {
    testWidgets(
      '1. Loads real data and displays calendar, schedule, courses, modules, and assignments',
      (tester) async {
        final List<String> calledMethods = [];

        _TestBridge.handler = (method, params) async {
          calledMethods.add(method);
          switch (method) {
            case 'fudan.semesters':
              return semestersFixture;
            case 'fudan.timetable.sync':
              return ugTimetableFixture;
            case 'canvas.courses.sync':
              return canvasCoursesFixture;
            case 'canvas.assignments.sync':
              if (params['course_id'] == '81001') {
                return canvasAssignmentsFixture;
              }
              return [];
            case 'canvas.folders.sync':
              if (params['course_id'] == '81001') {
                return canvasFoldersFixture;
              }
              return [];
            case 'canvas.materials.sync':
              if (params['course_id'] == '81001') {
                return canvasMaterialsFixture;
              }
              return [];
            case 'canvas.modules.sync':
              if (params['course_id'] == '81001') {
                return canvasModulesFixture;
              }
              return [];
            case 'canvas.announcements.sync':
              if (params['course_id'] == '81001') {
                return canvasAnnouncementsFixture;
              }
              return [];
            case 'canvas.quizzes.sync':
              if (params['course_id'] != '81001') return [];
              return [
                {
                  'id': '83001',
                  'course_id': '81001',
                  'title': '随堂测验一',
                  'due_at': '2026-11-20T12:00:00+08:00',
                  'time_limit': 30,
                  'question_count': 10,
                  'allowed_attempts': 1,
                  'published': true,
                },
                {
                  'id': '83002',
                  'course_id': '81001',
                  'title': '已计分测验',
                  'assignment_id': '82002',
                  'due_at': '2026-11-21T12:00:00+08:00',
                },
              ];
            case 'canvas.submission.self':
              return [
                {
                  'external_id': 'submission-self',
                  'payload': params['assignment_id'] == '82002'
                      ? {
                          'assignment_id': '82002',
                          'workflow_state': 'graded',
                          'submitted_at': '2026-11-07T10:00:00Z',
                          'score': 9.0,
                          'submission_comments': [
                            {
                              'id': '1',
                              'author_name': '王老师',
                              'comment': '<p>很好</p>',
                            },
                          ],
                        }
                      : {
                          'assignment_id': params['assignment_id'],
                          'workflow_state': 'unsubmitted',
                        },
                },
              ];
            case 'canvas.discussions.sync':
              if (params['course_id'] != '81001') return [];
              return [
                {
                  'id': '84001',
                  'title': '期中复习答疑',
                  'discussion_subentry_count': 2,
                  'read_state': 'unread',
                  'posted_at': '2026-11-05T08:00:00Z',
                },
              ];
            case 'canvas.grades.self':
              if (params['course_id'] != '81001') return [];
              return [
                {
                  'payload': {
                    'enrollment_id': '1',
                    'grades': {'current_score': 92.5, 'current_grade': 'A'},
                  },
                },
              ];
            case 'canvas.assignment_groups.sync':
              if (params['course_id'] != '81001') return [];
              return [
                {
                  'id': '1',
                  'name': '平时作业',
                  'group_weight': 40.0,
                  'position': 1,
                },
              ];
            case 'canvas.pages.sync':
              if (params['course_id'] != '81001') return [];
              return [
                {'page_slug': 'syllabus', 'title': '课程说明', 'front_page': true},
              ];
            default:
              return {};
          }
        };

        final client = DanshengClient(bridge: _TestBridge());
        final controller = _StudentApp(client: client);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: LearningPage(
              controller: controller,
              now: () => DateTime.utc(2026, 11, 8, 4),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Verify methods called
        expect(calledMethods, contains('fudan.semesters'));
        expect(calledMethods, contains('fudan.timetable.sync'));
        expect(calledMethods, contains('canvas.courses.sync'));

        // Check header title
        expect(find.text('课程学习'), findsOneWidget);

        // Check academic filter options
        expect(find.text('本科生'), findsNothing);
        expect(find.text('研究生'), findsNothing);
        expect(find.text('2026-2027学年第一学期'), findsNothing);

        // Check Calendar header
        expect(find.text('今天'), findsOneWidget);
        expect(find.text('周'), findsWidgets);
        expect(find.text('月'), findsWidgets);

        // On 2026-11-08 (Sunday, week 1), "高等数学" occurs
        expect(find.text('高等数学'), findsOneWidget);
        expect(find.text('光华楼西主楼101'), findsOneWidget);
        expect(find.textContaining('第1-2节'), findsOneWidget);

        // On 2026-11-08, "第1次上机实验报告" is due
        expect(find.text('第1次上机实验报告'), findsOneWidget);
        expect(find.textContaining('截止'), findsWidgets);
        // Own submission status, not the course-wide submission flag.
        expect(find.text('未提交'), findsOneWidget);
        expect(find.text('已提交'), findsOneWidget);
        expect(find.text('得分 9 / 10'), findsOneWidget);
        // A standalone quiz is a deadline; a graded quiz is already listed.
        expect(find.text('随堂测验一'), findsOneWidget);
        expect(find.text('已计分测验'), findsNothing);

        // Week grid shows the teaching week and the course block
        expect(find.text('第1周'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('timetable-block-7-1')),
          findsOneWidget,
        );

        // Canvas Enrolled Courses section
        expect(find.text('本学期课程'), findsOneWidget);
        expect(find.text('计算机系统导论'), findsWidgets);
        // Course files load only once the course page is opened
        expect(calledMethods, isNot(contains('canvas.modules.sync')));
        await tester.tap(find.text('计算机系统导论').last);
        await tester.pumpAndSettle();
        expect(calledMethods, contains('canvas.modules.sync'));
        expect(find.text('第1模块：计算机系统概览'), findsOneWidget);
        expect(find.text('课程说明'), findsOneWidget);
        await tester.tap(find.text('讨论(1)'));
        await tester.pumpAndSettle();
        expect(find.text('期中复习答疑'), findsOneWidget);
        expect(find.text('未读'), findsOneWidget);
        await tester.tap(find.text('成绩'));
        await tester.pumpAndSettle();
        expect(find.text('92.5 · A'), findsOneWidget);
        expect(find.text('40%'), findsOneWidget);
        expect(find.text('9 分 / 10'), findsOneWidget);
        await tester.tap(find.text('作业(3)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('课后习题二'));
        await tester.pumpAndSettle();
        expect(find.text('很好'), findsOneWidget);
      },
    );

    testWidgets('2. Calendar navigation and day selection updates schedule', (
      tester,
    ) async {
      _TestBridge.handler = (method, params) async {
        if (method == 'fudan.semesters') return semestersFixture;
        if (method == 'fudan.timetable.sync') return ugTimetableFixture;
        if (method == 'canvas.courses.sync') return canvasCoursesFixture;
        if (method == 'canvas.assignments.sync') {
          if (params['course_id'] == '81001') return canvasAssignmentsFixture;
          return [];
        }
        return {};
      };

      final client = DanshengClient(bridge: _TestBridge());
      final controller = _StudentApp(client: client);

      await tester.pumpWidget(
        MaterialApp(
          home: LearningPage(
            controller: controller,
            now: () => DateTime.utc(2026, 11, 8, 4),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Month view
      await tester.tap(find.text('月').first);
      await tester.pumpAndSettle();

      // In month view, tap day '2' (Monday, 2026-11-02)
      // On Monday, "大学物理" occurs
      final day2Finder = find.widgetWithText(InkWell, '2');
      if (day2Finder.evaluate().isNotEmpty) {
        await tester.tap(day2Finder.first);
        await tester.pumpAndSettle();

        expect(find.text('大学物理'), findsOneWidget);
        expect(find.text('二教201'), findsOneWidget);
        // Deadlines are listed for every date, not only the selected day.
        expect(find.text('第1次上机实验报告'), findsOneWidget);
        expect(find.text('课后习题二'), findsOneWidget);
        expect(find.text('11月15日 23:59 截止'), findsOneWidget);
      }

      // Tap "今天" button to return to today
      await tester.tap(find.text('今天'));
      await tester.pumpAndSettle();
      expect(find.text('高等数学'), findsOneWidget);
    });

    testWidgets(
      '3. Postgraduate timetable is selected from student number without controls',
      (tester) async {
        final List<Map<String, dynamic>> syncCalls = [];

        _TestBridge.handler = (method, params) async {
          if (method == 'fudan.postgraduate.semester') {
            return (semestersFixture['semesters'] as List).first;
          }
          if (method == 'fudan.postgraduate.sync') {
            syncCalls.add({'method': method, 'params': params});
            return pgTimetableFixture;
          }
          if (method == 'fudan.timetable.sync') return ugTimetableFixture;
          if (method == 'canvas.courses.sync') return canvasCoursesFixture;
          return {};
        };

        final client = DanshengClient(bridge: _TestBridge());
        final controller = _StudentApp(client: client, account: '26100000000');

        await tester.pumpWidget(
          MaterialApp(
            home: LearningPage(
              controller: controller,
              now: () => DateTime.utc(2026, 11, 8, 4),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(syncCalls, hasLength(1));
        expect(syncCalls.single['params']['endpoint'], 'primary');
        for (final label in ['本科生', '研究生', '主端', '次端', '课表设置']) {
          expect(find.text(label), findsNothing);
        }
        expect(find.text('高级算法设计'), findsOneWidget);
        expect(find.text('交叉二号楼A301'), findsOneWidget);
      },
    );

    testWidgets(
      '4. Nested folders, downloading with course_id and file_id, and opening file via parent bridge with actual asset_id',
      (tester) async {
        final List<Map<String, dynamic>> downloadCalls = [];
        final List<Map<String, dynamic>> openFileCalls = [];

        _TestBridge.handler = (method, params) async {
          switch (method) {
            case 'fudan.semesters':
              return semestersFixture;
            case 'fudan.timetable.sync':
              return ugTimetableFixture;
            case 'canvas.courses.sync':
              return canvasCoursesFixture;
            case 'canvas.assignments.sync':
              if (params['course_id'] == '81001') {
                return canvasAssignmentsFixture;
              }
              return [];
            case 'canvas.folders.sync':
              if (params['course_id'] == '81001') {
                return canvasFoldersFixture;
              }
              return [];
            case 'canvas.materials.sync':
              if (params['course_id'] == '81001') {
                return canvasMaterialsFixture;
              }
              return [];
            case 'canvas.modules.sync':
              if (params['course_id'] == '81001') {
                return canvasModulesFixture;
              }
              return [];
            case 'canvas.announcements.sync':
              if (params['course_id'] == '81001') {
                return canvasAnnouncementsFixture;
              }
              return [];
            case 'canvas.material.download':
              downloadCalls.add(params);
              return {
                'asset_id': 'asset_83001_exact_sha256',
                'name': '课程大纲.pdf',
                'size': 102400,
              };
            case 'campus.openFile':
              openFileCalls.add(params);
              return {'status': 'opened'};
            default:
              return {};
          }
        };

        final client = DanshengClient(bridge: _TestBridge());
        final controller = _StudentApp(client: client);

        await tester.pumpWidget(
          MaterialApp(
            home: LearningPage(
              controller: controller,
              now: () => DateTime.utc(2026, 11, 8, 4),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open the course page from the eLearning list
        await tester.tap(find.text('计算机系统导论').last);
        await tester.pumpAndSettle();

        // Root file "课程指引.pdf" should be visible
        expect(find.text('课程指引.pdf'), findsOneWidget);

        // Root folder "课程课件与讲义" should be visible
        expect(find.text('课程课件与讲义'), findsOneWidget);

        // Tap folder to expand it
        await tester.tap(find.text('课程课件与讲义'));
        await tester.pumpAndSettle();

        // Child folder "第1周 绪论" and file "课程大纲.pdf" should now be visible
        expect(find.text('课程大纲.pdf'), findsOneWidget);
        expect(find.text('第1周 绪论'), findsOneWidget);

        // Tap child folder to expand it
        await tester.tap(find.text('第1周 绪论'));
        await tester.pumpAndSettle();

        // Nested material "第1讲-绪论课件.pdf" should now be visible
        expect(find.text('第1讲-绪论课件.pdf'), findsOneWidget);

        // Find download button specifically within the "课程大纲.pdf" card
        final syllabusItem = find
            .ancestor(
              of: find.text('课程大纲.pdf'),
              matching: find.byType(Container),
            )
            .first;
        final downloadBtn = find.descendant(
          of: syllabusItem,
          matching: find.byTooltip('下载并打开'),
        );
        await tester.tap(downloadBtn);
        await tester.pumpAndSettle();

        // Verify canvas.material.download was called with course_id and file_id
        expect(downloadCalls.isNotEmpty, isTrue);
        expect(downloadCalls.last['course_id'], equals('81001'));
        expect(downloadCalls.last['file_id'], equals('83001'));

        // Verify campus.openFile was called passing the actual result asset_id
        expect(openFileCalls.isNotEmpty, isTrue);
        expect(
          openFileCalls.last['asset_id'],
          equals('asset_83001_exact_sha256'),
        );
        expect(openFileCalls.last['file_id'], equals('83001'));
        expect(openFileCalls.last['course_id'], equals('81001'));

        // Verify SnackBar feedback shown
        expect(find.textContaining('已打开文件：课程大纲.pdf'), findsOneWidget);
      },
    );

    testWidgets('5. Course announcements tab display', (tester) async {
      _TestBridge.handler = (method, params) async {
        if (method == 'fudan.semesters') return semestersFixture;
        if (method == 'fudan.timetable.sync') return ugTimetableFixture;
        if (method == 'canvas.courses.sync') return canvasCoursesFixture;
        if (method == 'canvas.announcements.sync') {
          return canvasAnnouncementsFixture;
        }
        return {};
      };

      final client = DanshengClient(bridge: _TestBridge());
      final controller = _StudentApp(client: client);

      await tester.pumpWidget(
        MaterialApp(
          home: LearningPage(
            controller: controller,
            now: () => DateTime.utc(2026, 11, 8, 4),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open the course page, then its '公告' sub-tab
      await tester.tap(find.text('计算机系统导论').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('公告').first);
      await tester.pumpAndSettle();

      // Check announcement content
      expect(find.text('关于第1次实验的提交说明'), findsOneWidget);
      expect(find.textContaining('请同学们在周日23:59前提交实验代码与报告PDF。'), findsOneWidget);
    });

    testWidgets(
      '6. Per-source auth isolation: Academic auth required does not block Canvas',
      (tester) async {
        bool loginAcademicCalled = false;

        _TestBridge.handler = (method, params) async {
          if (method == 'fudan.semesters' || method == 'fudan.timetable.sync') {
            throw Exception('AuthenticationRequired');
          }
          if (method == 'canvas.courses.sync') return canvasCoursesFixture;
          if (method == 'canvas.assignments.sync') {
            if (params['course_id'] == '81001') return canvasAssignmentsFixture;
            return [];
          }
          if (method == 'campus.login') {
            if (params['service'] == 'academic') loginAcademicCalled = true;
            return {'status': 'ok'};
          }
          return {};
        };

        final client = DanshengClient(bridge: _TestBridge());
        final controller = _StudentApp(client: client);

        await tester.pumpWidget(
          MaterialApp(
            home: LearningPage(
              controller: controller,
              now: () => DateTime.utc(2026, 11, 8, 4),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Academic banner shows sign-in prompt
        expect(find.text('登录教务系统以同步课表'), findsOneWidget);
        expect(find.text('登录教务'), findsOneWidget);

        // Canvas still renders enrolled courses and assignments (source isolation!)
        expect(find.text('计算机系统导论'), findsWidgets);
        expect(find.text('第1次上机实验报告'), findsOneWidget);

        // Tap "登录教务" button
        await tester.tap(find.text('登录教务'));
        await tester.pumpAndSettle();
        expect(loginAcademicCalled, isTrue);
      },
    );

    testWidgets(
      '7. Per-source auth isolation: Canvas auth required does not block Academic and avoids false "no homework"',
      (tester) async {
        bool loginCanvasCalled = false;

        _TestBridge.handler = (method, params) async {
          if (method == 'fudan.semesters') return semestersFixture;
          if (method == 'fudan.timetable.sync') return ugTimetableFixture;
          if (method == 'canvas.courses.sync') {
            throw Exception('ConfigurationRequired');
          }
          if (method == 'campus.login') {
            if (params['service'] == 'canvas') loginCanvasCalled = true;
            return {'status': 'ok'};
          }
          return {};
        };

        final client = DanshengClient(bridge: _TestBridge());
        final controller = _StudentApp(client: client);

        await tester.pumpWidget(
          MaterialApp(
            home: LearningPage(
              controller: controller,
              now: () => DateTime.utc(2026, 11, 8, 4),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Academic timetable renders normally
        expect(find.text('高等数学'), findsOneWidget);

        // In day schedule view: shows Canvas auth prompt instead of false "今日无截止作业"
        expect(find.text('学习平台需要登录以获取截止作业'), findsOneWidget);
        expect(find.text('今日无截止作业'), findsNothing);

        // In course files view: shows Canvas login prompt
        expect(find.text('学习平台需要登录以获取课程课件'), findsOneWidget);
        expect(find.text('登录 Canvas'), findsWidgets);

        // Tap "登录 Canvas"
        await tester.tap(find.text('登录 Canvas').first);
        await tester.pumpAndSettle();
        expect(loginCanvasCalled, isTrue);
      },
    );

    testWidgets('8. Cached data fallback via campus.cached', (tester) async {
      _TestBridge.handler = (method, params) async {
        if (method == 'campus.cached') {
          final targetMethod = params['method'];
          if (targetMethod == 'fudan.semesters') return semestersFixture;
          if (targetMethod == 'fudan.timetable.sync') return ugTimetableFixture;
          if (targetMethod == 'canvas.courses.sync') {
            return canvasCoursesFixture;
          }
          return {};
        }
        // Direct remote calls fail (offline)
        throw Exception('Network connection timed out');
      };

      final client = DanshengClient(bridge: _TestBridge());
      final controller = _StudentApp(client: client);

      await tester.pumpWidget(
        MaterialApp(
          home: LearningPage(
            controller: controller,
            now: () => DateTime.utc(2026, 11, 8, 4),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Successfully displays timetable from cache
      expect(find.text('高等数学'), findsOneWidget);
      // Shows offline cache badge
      expect(find.text('离线课表'), findsWidgets);
    });

    testWidgets('9. Error messages contain no admin jargon or raw JSON', (
      tester,
    ) async {
      _TestBridge.handler = (method, params) async {
        throw Exception(
          'CoreError: {"status": 500, "details": "admin_db_corrupt"}',
        );
      };

      final client = DanshengClient(bridge: _TestBridge());
      final controller = _StudentApp(client: client);

      await tester.pumpWidget(
        MaterialApp(
          home: LearningPage(
            controller: controller,
            now: () => DateTime.utc(2026, 11, 8, 4),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Must not display raw JSON
      expect(find.textContaining('admin_db_corrupt'), findsNothing);
      expect(find.textContaining('{"status": 500'), findsNothing);
      // Clean user friendly text
      expect(find.text('请求失败，请稍后重试'), findsWidgets);
    });

    testWidgets('10. No network on tab hidden and interactive detail modals', (
      tester,
    ) async {
      int callCount = 0;
      _TestBridge.handler = (method, params) async {
        callCount++;
        if (method == 'fudan.semesters') return semestersFixture;
        if (method == 'fudan.timetable.sync') return ugTimetableFixture;
        if (method == 'canvas.courses.sync') return canvasCoursesFixture;
        if (method == 'canvas.assignments.sync') {
          if (params['course_id'] == '81001') return canvasAssignmentsFixture;
          return [];
        }
        return {};
      };

      final client = DanshengClient(bridge: _TestBridge());
      final controller = _StudentApp(client: client);

      // Put LearningPage inside a hidden TickerMode (e.g. IndexedStack inactive tab)
      await tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: false,
            child: LearningPage(
              controller: controller,
              now: () => DateTime.utc(2026, 11, 8, 4),
            ),
          ),
        ),
      );
      await tester.pump();

      // No network calls should be made while tab is hidden
      expect(callCount, equals(0));

      // Now enable TickerMode (tab becomes active)
      await tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: true,
            child: LearningPage(
              controller: controller,
              now: () => DateTime.utc(2026, 11, 8, 4),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Calls are now triggered
      expect(callCount, greaterThan(0));

      // Tapping a course card opens its course page
      await tester.tap(find.text('高等数学'));
      await tester.pumpAndSettle();
      expect(find.text('SYNTH101.01'), findsOneWidget);
      expect(find.textContaining('第 1-4 周'), findsOneWidget);
      expect(find.text('eLearning 中暂未找到与这门课对应的课程'), findsOneWidget);

      // Back to the schedule
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Test tapping assignment card to view assignment details modal
      await tester.tap(find.text('第1次上机实验报告'));
      await tester.pumpAndSettle();
      expect(find.text('100 分'), findsOneWidget);
      expect(find.textContaining('完成实验一的全部要求'), findsOneWidget);
    });

    testWidgets(
      '11. Week grid pages between weeks and a course block opens the matched eLearning course',
      (tester) async {
        final List<Map<String, dynamic>> materialCalls = [];
        _TestBridge.handler = (method, params) async {
          switch (method) {
            case 'fudan.semesters':
              return semestersFixture;
            case 'fudan.timetable.sync':
              return ugTimetableFixture;
            case 'canvas.courses.sync':
              return [
                ...canvasCoursesFixture,
                {
                  'id': '81003',
                  'name': '高等数学 2026秋',
                  'course_code': 'SYNTH101.01',
                },
              ];
            case 'canvas.materials.sync':
              materialCalls.add(params);
              return params['course_id'] == '81003'
                  ? canvasMaterialsFixture
                  : [];
            default:
              return [];
          }
        };

        final client = DanshengClient(bridge: _TestBridge());
        final controller = _StudentApp(client: client);

        await tester.pumpWidget(
          MaterialApp(
            home: LearningPage(
              controller: controller,
              now: () => DateTime.utc(2026, 11, 8, 4),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The week before teaching week 1 holds the week-zero Sunday course
        await tester.tap(find.byTooltip('上一周'));
        await tester.pumpAndSettle();
        expect(find.text('第1周'), findsNothing);
        expect(find.textContaining('入学前导论课'), findsWidgets);

        await tester.tap(find.text('今天'));
        await tester.pumpAndSettle();
        expect(find.textContaining('入学前导论课'), findsNothing);

        // Tapping the block enters the course page of the matched course
        await tester.tap(find.byKey(const ValueKey('timetable-block-7-1')));
        await tester.pumpAndSettle();
        expect(materialCalls.single['course_id'], equals('81003'));
        expect(find.text('高等数学 2026秋'), findsOneWidget);
        expect(find.textContaining('光华楼西主楼101'), findsOneWidget);
        expect(find.text('课程指引.pdf'), findsOneWidget);
        expect(find.text('eLearning 中暂未找到与这门课对应的课程'), findsNothing);
      },
    );
  });
}
