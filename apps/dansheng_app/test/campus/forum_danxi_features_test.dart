// SPDX-License-Identifier: GPL-3.0-or-later
// Verification of DanXi-aligned features: Clean mode filter, FoldBehavior,
// tag filtering, hidden posts, floor mention caching, and modal quote preview.
import 'package:dansheng_app/ui/campus/forum/forum_chips.dart';
import 'package:dansheng_app/ui/campus/forum/forum_filter_settings.dart';
import 'package:dansheng_app/ui/campus/forum/forum_mention_support.dart';
import 'package:dansheng_app/ui/campus/forum/forum_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    ForumPreferences.instance.setCleanMode(false);
    ForumPreferences.instance.setFoldBehavior(FoldBehavior.fold);
    ForumPreferences.instance.clearHiddenHoles();
    ForumPreferences.instance.setTagFilter(null);
    for (final tag in ForumPreferences.instance.hiddenTags) {
      ForumPreferences.instance.removeHiddenTag(tag);
    }
  });

  group('CleanModeFilter tests', () {
    test('removes unfriendly emojis while preserving normal text', () {
      const input = '今天天气不错😅大家加油😄！别生气😡哦';
      final cleaned = CleanModeFilter.cleanText(input);
      expect(cleaned, isNot(contains('😅')));
      expect(cleaned, isNot(contains('😄')));
      expect(cleaned, isNot(contains('😡')));
      expect(cleaned, contains('今天天气不错'));
      expect(cleaned, contains('大家加油'));
      expect(cleaned, contains('哦'));
    });

    test('cleanMode preference toggles content filtering', () {
      final prefs = ForumPreferences.instance;
      const text = '测试😅表情';
      expect(prefs.filterContent(text), '测试😅表情');
      prefs.setCleanMode(true);
      expect(prefs.filterContent(text), '测试 表情');
      prefs.setCleanMode(false);
      expect(prefs.filterContent(text), '测试😅表情');
    });
  });

  group('FoldBehavior and Hidden Holes/Tags tests', () {
    const normalHole = TeaHole(
      holeId: 101,
      divisionId: 1,
      tags: ['日常'],
      floors: TeaFloorPreview(
        firstFloor: TeaFloor(floorId: 1, holeId: 101, content: '正常帖子'),
      ),
    );

    const foldedHole = TeaHole(
      holeId: 102,
      divisionId: 1,
      tags: ['*敏感话题'],
      floors: TeaFloorPreview(
        firstFloor: TeaFloor(floorId: 2, holeId: 102, content: '折叠帖子'),
      ),
    );

    test('FoldBehavior.fold shows folded hole with shouldHideHole == false', () {
      final prefs = ForumPreferences.instance;
      prefs.setFoldBehavior(FoldBehavior.fold);
      expect(prefs.shouldHideHole(normalHole), isFalse);
      expect(prefs.shouldHideHole(foldedHole), isFalse);
    });

    test('FoldBehavior.hide completely hides folded hole', () {
      final prefs = ForumPreferences.instance;
      prefs.setFoldBehavior(FoldBehavior.hide);
      expect(prefs.shouldHideHole(normalHole), isFalse);
      expect(prefs.shouldHideHole(foldedHole), isTrue);
    });

    test('hiddenHoles hides specifically blocked hole IDs', () {
      final prefs = ForumPreferences.instance;
      expect(prefs.shouldHideHole(normalHole), isFalse);
      prefs.hideHole(101);
      expect(prefs.shouldHideHole(normalHole), isTrue);
      prefs.unhideHole(101);
      expect(prefs.shouldHideHole(normalHole), isFalse);
    });

    test('hiddenTags hides any hole matching blocked tag', () {
      final prefs = ForumPreferences.instance;
      expect(prefs.shouldHideHole(normalHole), isFalse);
      prefs.addHiddenTag('日常');
      expect(prefs.shouldHideHole(normalHole), isTrue);
      prefs.removeHiddenTag('日常');
      expect(prefs.shouldHideHole(normalHole), isFalse);
    });

    test('selectedTagFilter filters out holes lacking selected tag', () {
      final prefs = ForumPreferences.instance;
      prefs.setTagFilter('日常');
      expect(prefs.shouldHideHole(normalHole), isFalse);
      expect(prefs.shouldHideHole(foldedHole), isTrue);
      prefs.setTagFilter(null);
      expect(prefs.shouldHideHole(foldedHole), isFalse);
    });
  });

  group('DanXi color palette and chip tests', () {
    test('getHashColor produces consistent colors matching DanXi palette', () {
      final c1 = getHashColor('树洞');
      final c2 = getHashColor('树洞');
      final c3 = getHashColor('日常');
      expect(c1, equals(c2));
      expect(c1, isNot(equals(c3)));
      expect(getHashColor('*敏感'), equals(Colors.red));
      expect(getHashColor(''), equals(Colors.red));
    });

    testWidgets('RectangularChip and LeadingChip render cleanly', (tester) async {
      var tagTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                LeadingChip(label: '置顶', color: Colors.blue),
                RectangularChip(
                  label: '学习交流',
                  onTap: () => tagTapped = true,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('#学习交流'), findsOneWidget);
      await tester.tap(find.text('#学习交流'));
      expect(tagTapped, isTrue);
    });
  });

  group('ForumFloorCache and Floor Mention Support tests', () {
    test('ForumFloorCache stores and retrieves floors and holes', () {
      final cache = ForumFloorCache.instance;
      const floor = TeaFloor(floorId: 999, holeId: 888, content: '被引用楼层');
      cache.putFloor(floor);
      expect(cache.getFloor(999), isNotNull);
      expect(cache.getFloor(999)!.content, '被引用楼层');

      const hole = TeaHole(
        holeId: 888,
        divisionId: 1,
        floors: TeaFloorPreview(firstFloor: floor),
      );
      cache.putHole(hole);
      expect(cache.getHole(888), isNotNull);
      expect(cache.getFloor(999), isNotNull);
    });

    testWidgets('showFloorDetailModal renders complete quoted floor and action buttons', (
      tester,
    ) async {
      var jumped = false;
      var quoted = false;
      const floor = TeaFloor(
        floorId: 200,
        holeId: 100,
        anonyname: '引用楼主',
        ranking: 3,
        content: '被引用的详细讨论内容',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showFloorDetailModal(
                  context,
                  floor: floor,
                  onJumpToFloor: () => jumped = true,
                  onQuoteReply: () => quoted = true,
                ),
                child: const Text('打开引用详情'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开引用详情'));
      await tester.pumpAndSettle();

      expect(find.textContaining('引用楼主'), findsOneWidget);
      expect(find.text('4楼'), findsOneWidget);
      expect(find.textContaining('被引用的详细讨论内容'), findsOneWidget);
      expect(find.text('跳转至该楼'), findsOneWidget);
      expect(find.text('引用此楼'), findsOneWidget);

      await tester.tap(find.text('跳转至该楼'));
      await tester.pumpAndSettle();
      expect(jumped, isTrue);
      expect(quoted, isFalse);
    });
  });
}
