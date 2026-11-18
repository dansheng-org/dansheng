// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:dansheng_app/agent/agent_campus_link.dart';
import 'package:dansheng_app/agent/agent_session.dart';
import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/agent/campus_tools.dart';
import 'package:dansheng_app/ui/campus/agent/agent_campus_navigation.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui/test_helpers.dart';

const _origin = 'dansheng://agent';

AgentCampusLink? _parse(String href) =>
    AgentCampusLink.fromJson({'title': '来源', 'url': href});

void main() {
  test('parses only canonical, typed campus destinations', () {
    final forum = _parse('$_origin/forum/23/45') as AgentForumLink;
    expect((forum.holeId, forum.floorId), (23, 45));
    expect(_parse('$_origin/forum/23'), isA<AgentForumLink>());
    expect(_parse('$_origin/course/123'), isA<AgentCourseLink>());
    final assignment =
        _parse('$_origin/assignment/123/456') as AgentAssignmentLink;
    expect((assignment.courseId, assignment.assignmentId), ('123', '456'));
    expect(_parse('$_origin/library'), isA<AgentLibraryLink>());
    expect(assignment.toJson(), {
      'title': '来源',
      'url': '$_origin/assignment/123/456',
    });
    const noticeUrl = 'https://jwc.fudan.edu.cn/2026/1118/c1a2/page.htm';
    final notice =
        AgentCampusLink.fromNotice('教务公告', noticeUrl) as AgentNoticeLink;
    expect(
      notice.uri.toString(),
      '$_origin/notice/jwc/2026/1118/c1a2/page.htm',
    );
    expect(notice.noticeUrl.toString(), noticeUrl);
    for (final href in [
      'https://agent/forum/23',
      'dansheng://someone@agent/forum/23',
      'dansheng://agent:0/forum/23',
      '$_origin/forum/023',
      '$_origin/forum/23/0',
      '$_origin/forum/18446744073709551616',
      '$_origin/forum/%32%33',
      '$_origin/forum/%FF',
      '$_origin/forum/../course/23',
      '$_origin/course/23/',
      '$_origin/course/23?',
      '$_origin/course/23#',
      '$_origin/assignment/23',
      '$_origin/notice/canvas/page.htm',
      '$_origin/notice/jwc//page.htm',
    ]) {
      expect(_parse(href), isNull, reason: href);
    }
  });

  test('projects actual destinations within the encoded tool budget', () async {
    final extra = AgentTool(
      spec: const AgentToolSpec('campus_extra', '额外工具', {}),
      source: AgentSourceKind.campus,
      label: '额外工具',
      read: (_) async => {},
    );
    final registry = campusToolRegistry(
      activeAccount: () => 'account',
      forumEnabled: () => true,
      extraTools: [extra],
      read: (method, _) async => (
        switch (method) {
          'canvas.courses.sync' => [
            for (var i = 1; i <= 25; i++)
              {
                'id': i,
                'name': '"' * 140,
                'term': {'name': '"' * 140},
              },
          ],
          'canvas.assignments.sync' => [
            {'id': 31, 'name': '实际作业'},
            {'name': '缺失 ID 的作业'},
            {'id': 32, 'name': '其他课程作业', 'course_id': 2},
          ],
          'community.tea.search' => [
            {'hole_id': 40, 'floor_id': 41, 'content': '实际回复'},
            {'hole_id': 40, 'floor_id': 41, 'content': '重复回复'},
            {'floor_id': 42, 'content': '缺失帖子 ID 的回复'},
          ],
          _ => throw StateError('Unexpected campus query'),
        },
        false,
      ),
    );
    final tools = registry.forSources(AgentSourceKind.values.toSet()).toList();
    expect(tools.last, same(extra));
    Future<Json> read(String name, Json args) =>
        tools.firstWhere((tool) => tool.spec.name == name).read(args);

    final courses = await read('campus_courses', {'include_archive': true});
    expect(courses['truncated'], isTrue);
    expect(jsonEncode(courses).length, lessThanOrEqualTo(12000));
    final links = courses['campus_links'] as List;
    final records = courses['records'] as List;
    expect(links, isNotEmpty);
    expect(links.length, records.length);
    for (var i = 0; i < records.length; i++) {
      expect(records[i]['link'], '$_origin/course/${i + 1}');
      expect(links[i]['url'], records[i]['link']);
    }

    final assignments = await read('campus_assignments', {'course_id': '1'});
    expect(assignments['campus_links'], [
      {'title': '实际作业', 'url': '$_origin/assignment/1/31'},
    ]);
    expect((assignments['records'] as List).map((row) => row['link']), [
      '$_origin/assignment/1/31',
      null,
      null,
    ]);
    final forum = await read('campus_forum_search', {'query': '实际回复'});
    expect(forum['campus_links'], [
      {'title': '树洞 #40 · 楼层 #41', 'url': '$_origin/forum/40/41'},
    ]);
  });

  testWidgets('exact assignment closes on Back and on account change', (
    tester,
  ) async {
    final bridge = MockDanshengBridge();
    final controller = DanshengController(
      client: DanshengClient(bridge: bridge),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final calls = <String>[];
    bridge.campusHandler = (method, params) async {
      if (method == 'campus.loginStatus') return {'uis': true};
      calls.add(method);
      expect(params['account_id'], 'user_001');
      expect(params['course_id'], '123');
      if (method == 'canvas.assignments.sync') {
        return [
          {'id': 456, 'name': '其他课程同编号', 'course_id': 234},
          {'id': 455, 'name': '同课程其他作业'},
          {
            'payload': {'id': 456, 'name': '精确作业'},
          },
        ];
      }
      expect(method, 'canvas.submission.self');
      expect(params['assignment_id'], '456');
      return <Json>[];
    };
    final link = _parse('$_origin/assignment/123/456')!;
    const label = '原 Agent 会话';
    late Future<void> opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  opened = openAgentCampusLink(context, controller, link),
              child: const Text(label),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.text('精确作业'), findsOneWidget);
    expect(find.text('其他课程同编号'), findsNothing);
    expect(calls, ['canvas.assignments.sync', 'canvas.submission.self']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await opened;
    expect(find.text('精确作业'), findsNothing);
    expect(find.text(label), findsOneWidget);

    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.text('精确作业'), findsOneWidget);
    await controller.switchAccount('user_002');
    await tester.pumpAndSettle();
    await opened;
    expect(find.text('精确作业'), findsNothing);
    expect(find.text(label), findsOneWidget);
  });
}
