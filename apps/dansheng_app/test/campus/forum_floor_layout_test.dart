// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dansheng_app/ui/campus/forum/forum_content.dart';
import 'package:dansheng_app/ui/campus/forum/forum_floor_tile.dart';
import 'package:dansheng_app/ui/campus/forum/forum_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _op = TeaFloor(floorId: 11, holeId: 7, anonyname: '合成洞主');

Future<void> _pumpFloor(
  WidgetTester tester,
  TeaFloor floor, {
  TeaFloor? firstFloor = _op,
  int? index = 20,
  ValueChanged<int>? onTapFloor,
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
          child: ForumFloorTile(
            floor: floor,
            firstFloor: firstFloor,
            index: index,
            showHoleId: true,
            onTapFloor: onTapFloor,
            tags: const ['默认', '合成标签'],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('later replies by anonymous OP retain OP badge and actual rank', (
    tester,
  ) async {
    await _pumpFloor(
      tester,
      const TeaFloor(
        floorId: 55,
        holeId: 7,
        content: '**Synthetic reply**',
        anonyname: '合成洞主',
        ranking: 42,
      ),
    );
    expect(find.text('洞主'), findsOneWidget);
    expect(find.text('43楼'), findsOneWidget);
    expect(find.text('21楼'), findsNothing);
    expect(
      tester.widget<ForumContent>(find.byType(ForumContent)).content,
      '**Synthetic reply**',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('matching first floor ID marks OP even without name', (
    tester,
  ) async {
    await _pumpFloor(
      tester,
      const TeaFloor(
        floorId: 11,
        holeId: 7,
        content: 'Synthetic first',
        ranking: 0,
      ),
    );
    expect(find.text('洞主'), findsOneWidget);
    expect(find.text('首楼'), findsOneWidget);
  });

  testWidgets('missing ranking uses full pagination index not floor ID', (
    tester,
  ) async {
    await _pumpFloor(
      tester,
      const TeaFloor(
        floorId: 98765,
        holeId: 7,
        content: 'Synthetic page two',
        anonyname: '其他合成用户',
      ),
      index: 21,
    );
    expect(find.text('22楼'), findsOneWidget);
    expect(find.text('98765楼'), findsNothing);
    expect(find.text('##98765'), findsOneWidget);
    expect(find.text('洞主'), findsNothing);
  });

  testWidgets('unknown names never establish OP identity', (tester) async {
    await _pumpFloor(
      tester,
      const TeaFloor(floorId: 12, holeId: 7, content: 'Synthetic unknown'),
      firstFloor: const TeaFloor(floorId: 11, holeId: 7),
      index: 0,
    );
    expect(find.text('洞主'), findsNothing);
    expect(find.text('首楼'), findsOneWidget);
  });

  testWidgets(
    'folded floor builds real content only after expand and collapses again',
    (tester) async {
      await _pumpFloor(
        tester,
        const TeaFloor(
          floorId: 12,
          holeId: 7,
          content: '**Synthetic folded body**',
          fold: ['合成原因'],
        ),
      );
      expect(find.byType(ForumContent), findsNothing);
      await tester.tap(find.textContaining('内容已折叠，点击展开'));
      await tester.pumpAndSettle();
      expect(find.byType(ForumContent), findsOneWidget);
      expect(
        tester.widget<ForumContent>(find.byType(ForumContent)).content,
        '**Synthetic folded body**',
      );
      await tester.tap(find.textContaining('收起折叠内容'));
      await tester.pump();
      expect(find.byType(ForumContent), findsNothing);
    },
  );

  testWidgets(
    'deleted floor never builds content or reveals tags or reply preview',
    (tester) async {
      await _pumpFloor(
        tester,
        const TeaFloor(
          floorId: 12,
          holeId: 7,
          content: 'Deleted synthetic body',
          deleted: true,
          fold: ['合成原因'],
          replyTo: 11,
        ),
      );
      expect(find.byType(ForumContent), findsNothing);
      expect(find.text('该楼层已被删除'), findsOneWidget);
      expect(find.textContaining('点击展开'), findsNothing);
      expect(find.text('Deleted synthetic body'), findsNothing);
      expect(find.text('#合成标签'), findsNothing);
      expect(find.text('回复 ##11'), findsNothing);
    },
  );

  testWidgets(
    'long anonymous names and special tags fit narrow scaled layout',
    (tester) async {
      final longText = List.filled(10, '合成超长匿名名LongName').join();
      await _pumpFloor(
        tester,
        TeaFloor(
          floorId: 12,
          holeId: 7,
          content: 'Synthetic content',
          anonyname: longText,
          specialTag: longText,
        ),
      );
      expect(find.text(longText), findsNWidgets(2));
      expect(find.text('#默认'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reply target delegates the floor ID and body remains intact', (
    tester,
  ) async {
    int? target;
    await _pumpFloor(
      tester,
      const TeaFloor(
        floorId: 12,
        holeId: 7,
        content: '> Synthetic quote\n\n**bold**',
        replyTo: 11,
      ),
      onTapFloor: (id) => target = id,
    );
    await tester.tap(find.text('回复 ##11'));
    expect(target, 11);
    expect(
      tester.widget<ForumContent>(find.byType(ForumContent)).preview,
      false,
    );
  });
}
