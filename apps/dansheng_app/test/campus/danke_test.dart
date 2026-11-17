import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/campus/forum/danke/danke_page.dart';
import 'package:dansheng_app/ui/campus/forum/danke/danke_widgets.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _review(int id, String title, {int overall = 4}) => {
  'id': id,
  'reviewer_id': 700 + id,
  'title': title,
  'content': '$title 的正文',
  'timeCreated': '2026-11-01T10:00:00Z',
  'rank': {'overall': overall, 'content': 3, 'workload': 2, 'assessment': 5},
  'remark': 3,
  'deleted': false,
};

const _course = {
  'id': 401,
  'name': '合成数学',
  'code': 'MATH101',
  'credit': 3.0,
  'department': '数学学院',
  'teachers': '张老师',
  'year': 2025,
  'semester': 1,
};

class _Bridge implements DanshengBridge {
  final calls = <(String, Map)>[];

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final request = jsonDecode(payload) as Map;
    final method = request['method'] as String;
    final params = request['params'] as Map;
    calls.add((method, params));
    return jsonEncode(switch (method) {
      'community.danke.random' => {
        'payload': {
          ..._review(601, '随机评价'),
          'group_id': 301,
          'course': _course,
        },
      },
      'community.danke.search' => {
        'records': [
          {
            'payload': {
              'id': 301,
              'name': '合成数学',
              'code': 'MATH101',
              'department': '数学学院',
              'credits': [3.0],
              'course_count': 2,
              'review_count': 2,
            },
          },
        ],
        'coverage': {
          'Page': {'next': null, 'total': null},
        },
      },
      'community.danke.group' => {
        'payload': {
          'id': 301,
          'name': '合成数学',
          'code': 'MATH101',
          'department': '数学学院',
          'credits': [3.0],
          'course_list': [
            {
              ..._course,
              'review_list': [_review(601, '随机评价', overall: 5)],
            },
            {
              ..._course,
              'id': 402,
              'teachers': '李老师',
              'year': 2024,
              'semester': 3,
              'review_list': [_review(602, '李老师的课', overall: 3)],
            },
          ],
        },
      },
      _ => throw PlatformException(code: 'MethodUnavailable'),
    });
  }
}

Future<_Bridge> _pump(WidgetTester tester) async {
  final bridge = _Bridge();
  await tester.pumpWidget(
    MaterialApp(
      home: DankePage(api: CampusApi(DanshengClient(bridge: bridge))),
    ),
  );
  await tester.pumpAndSettle();
  return bridge;
}

void main() {
  testWidgets('home shows a random review that opens its course', (
    tester,
  ) async {
    final bridge = await _pump(tester);
    expect(find.text('数学学院 / 合成数学'), findsOneWidget);
    expect(find.text('3.0 学分'), findsOneWidget);
    expect(find.text('随机评价 的正文'), findsOneWidget);

    await tester.tap(find.byType(DankeRandomCard));
    await tester.pumpAndSettle();
    expect(bridge.calls.last.$1, 'community.danke.group');
    expect(bridge.calls.last.$2['group_id'], 301);
    expect(find.text('课程详情'), findsOneWidget);
    // The review it came from is outlined.
    final card = tester.widget<DankeReviewCard>(
      find.ancestor(
        of: find.text('随机评价'),
        matching: find.byType(DankeReviewCard),
      ),
    );
    expect(card.highlight, isTrue);
  });

  testWidgets('course page: average, grades in DanXi words, filters', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byType(DankeRandomCard));
    await tester.pumpAndSettle();

    // (5 + 3) ~/ 2 = 4 → 好评, as DanXi computes it.
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('平均评价'), matching: find.byType(Row)),
        matching: find.text('好评'),
      ),
      findsOneWidget,
    );
    expect(find.text('特别好评'), findsOneWidget);
    expect(find.text('非常宽松'), findsNWidgets(2));
    expect(find.text('随机评价'), findsOneWidget);
    expect(find.text('李老师的课'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '李老师'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '李老师'));
    await tester.pumpAndSettle();
    expect(find.text('随机评价'), findsNothing);
    expect(find.text('李老师的课'), findsOneWidget);

    await tester.ensureVisible(
      find.widgetWithText(ChoiceChip, '2025~2026学年-秋季'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '2025~2026学年-秋季'));
    await tester.pumpAndSettle();
    expect(find.text('该课程还没有评论'), findsOneWidget);
  });

  testWidgets('searching lists courses that open their reviews', (
    tester,
  ) async {
    final bridge = await _pump(tester);
    await tester.enterText(find.byKey(const Key('danke-search')), '数学');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final search = bridge.calls.lastWhere(
      (c) => c.$1 == 'community.danke.search',
    );
    expect(search.$2['query'], '数学');
    expect(find.byType(DankeGroupCard), findsOneWidget);
    expect(find.text('已经到底了'), findsOneWidget);

    await tester.tap(find.byType(DankeGroupCard));
    await tester.pumpAndSettle();
    expect(find.text('课程详情'), findsOneWidget);
  });
}
