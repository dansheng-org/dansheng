// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dansheng_app/ui/campus/forum/forum_models.dart';
import 'package:dansheng_app/ui/campus/forum/hole_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = TeaFloor(
  floorId: 11,
  holeId: 7,
  content: 'Synthetic first floor',
  anonyname: '合成匿名名',
);
const _last = TeaFloor(
  floorId: 12,
  holeId: 7,
  content: 'Synthetic latest reply',
  anonyname: '合成回复人',
  timeCreated: '2026-01-01T00:00:00Z',
);

Future<void> _pumpCard(
  WidgetTester tester,
  TeaHole hole, {
  String? divisionName,
  VoidCallback? onTap,
  VoidCallback? onTapLatestReply,
}) async {
  tester.view.physicalSize = const Size(320, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.4)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: TeaHoleCard(
            hole: hole,
            divisionName: divisionName,
            onTap: onTap,
            onTapLatestReply: onTapLatestReply,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('latest reply has an independent navigation callback', (
    tester,
  ) async {
    var cardTaps = 0;
    var replyTaps = 0;
    await _pumpCard(
      tester,
      const TeaHole(
        holeId: 7,
        divisionId: 1,
        floors: TeaFloorPreview(firstFloor: _first, lastFloor: _last),
      ),
      onTap: () => cardTaps++,
      onTapLatestReply: () => replyTaps++,
    );
    await tester.tap(find.text('Synthetic latest reply'));
    expect(replyTaps, 1);
    expect(cardTaps, 0);
    await tester.tap(find.text('Synthetic first floor'));
    expect(cardTaps, 1);
  });

  testWidgets('star-prefixed hidden tag folds card and resets expanded state', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      const TeaHole(
        holeId: 7,
        divisionId: 1,
        floors: TeaFloorPreview(firstFloor: _first, lastFloor: _last),
      ),
    );
    await _pumpCard(
      tester,
      const TeaHole(
        holeId: 7,
        divisionId: 1,
        tags: ['*合成折叠标记', '默认'],
        floors: TeaFloorPreview(firstFloor: _first, lastFloor: _last),
      ),
    );
    expect(find.text('Synthetic first floor'), findsNothing);
    expect(find.textContaining('最新回复'), findsNothing);
    expect(find.text('#*合成折叠标记'), findsNothing);
    await tester.tap(find.text('帖子已折叠，点击展开'));
    await tester.pump();
    expect(find.text('Synthetic first floor'), findsOneWidget);
    await _pumpCard(
      tester,
      const TeaHole(
        holeId: 8,
        divisionId: 1,
        tags: ['*另一个标记'],
        floors: TeaFloorPreview(firstFloor: _first),
      ),
    );
    expect(find.text('Synthetic first floor'), findsNothing);
  });

  test('optional floor fields round-trip and preserve ranking zero', () {
    final floor = TeaFloor.fromJson({
      'floor_id': 11,
      'hole_id': 7,
      'ranking': '0',
      'reply_to': '12',
      'special_tag': '合成标签',
    });
    expect(floor.ranking, 0);
    expect(floor.replyTo, 12);
    expect(floor.specialTag, '合成标签');
    expect(TeaFloor.fromJson(floor.toJson()).ranking, 0);
    expect(TeaFloor.fromJson({'floor_id': 11, 'hole_id': 7}).ranking, isNull);
    expect(TeaFloor.fromJson({'ranking': 'invalid'}).ranking, isNull);
  });

  test('body references never become inferred tags', () {
    final hole = TeaHole.fromJson({
      'hole_id': 7,
      'first_floor': {
        'floor_id': 11,
        'content': 'Reference #123 and ##456 #ordinary',
      },
    });
    final search = ForumSearchResult.fromJson({
      'hole_id': 7,
      'content': 'Reference #123 and ##456 #ordinary',
    });
    expect(hole.tags, isEmpty);
    expect(search.tags, isEmpty);
    expect(
      TeaHole.fromJson({
        'tags': [
          {'name': '真实标签'},
        ],
      }).tags,
      ['真实标签'],
    );
  });

  test('search preserves moderation and optional floor metadata', () {
    final result = ForumSearchResult.fromJson({
      'hole_id': 7,
      'ranking': 22,
      'reply_to': 11,
      'special_tag': '合成标签',
      'fold': ['合成折叠原因'],
    });
    expect(result.ranking, 22);
    expect(result.replyTo, 11);
    expect(result.specialTag, '合成标签');
    expect(result.fold, ['合成折叠原因']);
  });

  testWidgets('card uses six-line 16px first floor and latest reply summary', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      const TeaHole(
        holeId: 7,
        divisionId: 1,
        reply: 3,
        floors: TeaFloorPreview(firstFloor: _first, lastFloor: _last),
      ),
    );
    final firstText = tester.widget<Text>(find.text('Synthetic first floor'));
    expect(firstText.style?.fontSize, 16);
    expect(firstText.maxLines, 6);
    final lastText = tester.widget<Text>(find.text('Synthetic latest reply'));
    expect(lastText.style?.fontSize, 14);
    expect(lastText.maxLines, 1);
    expect(find.textContaining('最新回复 · 合成回复人'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('#7')).dy,
      greaterThan(tester.getBottomLeft(find.text('Synthetic latest reply')).dy),
    );
    expect(find.text('3 回复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'same first and last ID hides latest reply despite different objects',
    (tester) async {
      await _pumpCard(
        tester,
        const TeaHole(
          holeId: 7,
          divisionId: 1,
          floors: TeaFloorPreview(
            firstFloor: _first,
            lastFloor: TeaFloor(
              floorId: 11,
              holeId: 7,
              content: 'Duplicate latest',
            ),
          ),
        ),
      );
      expect(find.textContaining('最新回复'), findsNothing);
      expect(find.text('Duplicate latest'), findsNothing);
    },
  );

  testWidgets('star tag folds the whole card including latest reply', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      const TeaHole(
        holeId: 7,
        divisionId: 1,
        tags: ['*', '默认', '合成标签'],
        floors: TeaFloorPreview(firstFloor: _first, lastFloor: _last),
      ),
    );
    expect(find.text('Synthetic first floor'), findsNothing);
    expect(find.textContaining('最新回复'), findsNothing);
    expect(find.text('#默认'), findsNothing);
    expect(find.text('#*'), findsNothing);
    await tester.tap(find.text('帖子已折叠，点击展开'));
    await tester.pump();
    expect(find.text('Synthetic first floor'), findsOneWidget);
    expect(find.text('Synthetic latest reply'), findsOneWidget);
    await tester.tap(find.text('收起折叠帖子'));
    await tester.pump();
    expect(find.text('Synthetic first floor'), findsNothing);
  });

  testWidgets(
    'folded preview opens locally and deleted preview never reveals body',
    (tester) async {
      await _pumpCard(
        tester,
        const TeaHole(
          holeId: 7,
          divisionId: 1,
          floors: TeaFloorPreview(
            firstFloor: TeaFloor(
              floorId: 11,
              holeId: 7,
              content: 'Folded synthetic body',
              fold: ['合成原因'],
            ),
            lastFloor: TeaFloor(
              floorId: 12,
              holeId: 7,
              content: 'Deleted synthetic body',
              deleted: true,
              fold: ['合成原因'],
            ),
          ),
        ),
      );
      expect(find.text('Folded synthetic body'), findsNothing);
      expect(find.text('Deleted synthetic body'), findsNothing);
      await tester.tap(find.textContaining('内容已折叠，点击展开'));
      await tester.pump();
      expect(find.text('Folded synthetic body'), findsOneWidget);
      expect(find.text('Deleted synthetic body'), findsNothing);
      expect(find.text('该楼层已被删除'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long tags division and anonymous name fit 320px at scale 1.4', (
    tester,
  ) async {
    final longText = List.filled(12, '合成超长文字LongText').join();
    await _pumpCard(
      tester,
      TeaHole(
        holeId: 123456789,
        divisionId: 1,
        tags: [longText, '默认'],
        floors: TeaFloorPreview(
          firstFloor: _first,
          lastFloor: TeaFloor(
            floorId: 12,
            holeId: 7,
            content: 'Synthetic reply',
            anonyname: longText,
          ),
        ),
      ),
      divisionName: longText,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('#默认'), findsNothing);
  });
}
