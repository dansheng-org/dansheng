// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math';

import 'package:dansheng_app/ui/campus/ehall/board/board_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void expectNoOverlap(BoardPacking packing, int columns) {
  final taken = <(int, int)>{};
  for (final cell in packing.cells) {
    expect(cell.column, greaterThanOrEqualTo(0));
    expect(cell.column + cell.columns, lessThanOrEqualTo(columns));
    expect(cell.row + cell.rows, lessThanOrEqualTo(packing.rows));
    for (var r = cell.row; r < cell.row + cell.rows; r++) {
      for (var c = cell.column; c < cell.column + cell.columns; c++) {
        expect(taken.add((c, r)), isTrue, reason: 'cell $c,$r taken twice');
      }
    }
  }
}

void main() {
  group('saved layout', () {
    test('standard layout lists every service once in the familiar order', () {
      final layout = BoardLayout.standard();
      expect([for (final slot in layout.slots) slot.tile], EHallTile.values);
      expect(layout.hidden, isEmpty);
      expect(
        [for (final tile in EHallTile.values) tile.title],
        [
          '校园卡',
          '教室空位',
          '寝室电量',
          '场馆预约',
          '图书馆客流',
          '食堂实时客流',
          '校车班次时刻',
          '校园邮箱',
          '教务公告',
          '课程成绩',
          '学分与绩点',
          '考试安排',
          '院系通知',
        ],
      );
    });

    test(
      'survives a JSON round trip with sizes, order, hiding and options',
      () {
        final layout = BoardLayout.standard()
            .resize(EHallTile.bus, TileSize.large)
            .show(EHallTile.mail, false)
            .withOption(EHallTile.dining, 'area', 2)
            .moveShown(EHallTile.exams, 0);
        final restored = BoardLayout.fromJson(
          jsonDecode(jsonEncode(layout.toJson())),
        );
        expect(restored, layout);
        expect(restored.shown.first.tile, EHallTile.exams);
        expect(restored.slot(EHallTile.bus).size, TileSize.large);
        expect(restored.slot(EHallTile.mail).shown, isFalse);
        expect(restored.slot(EHallTile.dining).options, {'area': 2});
      },
    );

    test('anything that is not a saved layout falls back to the standard', () {
      for (final junk in [
        null,
        'text',
        42,
        <dynamic>[],
        <String, dynamic>{},
        {'result': 'ok'},
        {'tiles': 'no'},
      ]) {
        expect(BoardLayout.fromJson(junk), BoardLayout.standard());
      }
    });

    test('reads leniently: unknown, repeated and missing entries', () {
      final layout = BoardLayout.fromJson({
        'v': 99,
        'tiles': [
          {'id': 'bus', 'size': 'large'},
          {'id': 'from-a-newer-build', 'size': 'small'},
          'junk',
          {'id': 'bus', 'size': 'icon', 'shown': false},
          {'id': 'power', 'size': 'no-such-size', 'shown': false},
          {
            'id': 'rooms',
            'size': 'wide',
            'options': {
              'building': 'H3',
              'nested': {'dropped': true},
              7: 'dropped',
            },
          },
        ],
      });
      expect(layout.slots.length, EHallTile.values.length);
      expect(layout.slots[0].tile, EHallTile.bus);
      expect(layout.slots[0].size, TileSize.large);
      expect(layout.slots[0].shown, isTrue);
      expect(layout.slots[1].tile, EHallTile.power);
      expect(layout.slots[1].size, BoardLayout.standardSize(EHallTile.power));
      expect(layout.slots[1].shown, isFalse);
      expect(layout.slots[2].options, {'building': 'H3'});
      // Services the saved layout did not know follow in their usual order.
      expect(
        [for (final slot in layout.slots.skip(3)) slot.tile],
        [
          for (final tile in EHallTile.values)
            if (![
              EHallTile.bus,
              EHallTile.power,
              EHallTile.rooms,
            ].contains(tile))
              tile,
        ],
      );
    });

    test('moving counts shown tiles only and keeps every tile', () {
      var layout = BoardLayout.standard()
          .show(EHallTile.rooms, false)
          .show(EHallTile.power, false);
      // Shown order now: ecard, venues, library, ...
      layout = layout.moveShown(EHallTile.library, 1);
      expect(
        [for (final slot in layout.shown.take(3)) slot.tile],
        [EHallTile.ecard, EHallTile.library, EHallTile.venues],
      );
      layout = layout.moveShown(EHallTile.ecard, 999);
      expect(layout.shown.last.tile, EHallTile.ecard);
      expect(layout.slots.toSet().length, EHallTile.values.length);
      expect(layout.hidden.length, 2);
    });

    test('removing an option leaves no empty entry behind', () {
      final layout = BoardLayout.standard()
          .withOption(EHallTile.bus, 'from', '邯郸')
          .withOption(EHallTile.bus, 'from', null);
      expect(layout, BoardLayout.standard());
      expect(layout.slot(EHallTile.bus).toJson().containsKey('options'), false);
    });
  });

  group('packing', () {
    test('a later small tile fills the gap a wide one left', () {
      final packing = packBoard([
        TileSize.small,
        TileSize.wide,
        TileSize.small,
      ], 4);
      expect(packing.cells, const [
        TileCell(0, 0, 2, 1),
        TileCell(0, 1, 4, 1),
        TileCell(2, 0, 2, 1),
      ]);
      expect(packing.rows, 2);
    });

    test('icons flow around a two-row tile', () {
      final packing = packBoard([
        TileSize.medium,
        TileSize.icon,
        TileSize.icon,
        TileSize.icon,
        TileSize.icon,
        TileSize.icon,
      ], 4);
      expect(packing.cells, const [
        TileCell(0, 0, 2, 2),
        TileCell(2, 0, 1, 1),
        TileCell(3, 0, 1, 1),
        TileCell(2, 1, 1, 1),
        TileCell(3, 1, 1, 1),
        TileCell(0, 2, 1, 1),
      ]);
      expect(packing.rows, 3);
    });

    test('the standard layout fills a phone grid without holes', () {
      final sizes = [for (final s in BoardLayout.standard().shown) s.size];
      final packing = packBoard(sizes, 4);
      expectNoOverlap(packing, 4);
      final area = packing.cells.fold(0, (sum, c) => sum + c.columns * c.rows);
      expect(area, packing.rows * 4);
    });

    test('narrow boards halve footprints and wide boards keep them', () {
      expect(
        [for (final size in TileSize.values) tileColumns(size, 2)],
        [1, 1, 2, 1, 2],
      );
      expect(
        [for (final size in TileSize.values) tileColumns(size, 8)],
        [1, 2, 4, 2, 4],
      );
      final narrow = packBoard(TileSize.values, 2);
      expectNoOverlap(narrow, 2);
      final wide = packBoard(TileSize.values, 8);
      expectNoOverlap(wide, 8);
      expect(wide.rows, lessThan(narrow.rows));
    });

    test('never overlaps or leaves the grid for arbitrary arrangements', () {
      final random = Random(20261114);
      for (var round = 0; round < 300; round++) {
        final columns = [2, 4, 6, 8][random.nextInt(4)];
        final sizes = [
          for (var i = 0; i < random.nextInt(13); i++)
            TileSize.values[random.nextInt(TileSize.values.length)],
        ];
        final packing = packBoard(sizes, columns);
        expect(packing.cells.length, sizes.length);
        expectNoOverlap(packing, columns);
      }
      expect(packBoard(const [], 4).rows, 0);
    });
  });

  group('metrics', () {
    test('column count follows width and text scale and stays even', () {
      expect(BoardMetrics.fit(328).columns, 4);
      expect(BoardMetrics.fit(288).columns, 4);
      expect(BoardMetrics.fit(208).columns, 2);
      expect(BoardMetrics.fit(328, textScale: 1.8).columns, 2);
      expect(BoardMetrics.fit(768).columns, 8);
      expect(BoardMetrics.fit(568).columns, 6);
      expect(BoardMetrics.fit(0).columns, 2);
      for (var width = 0.0; width < 1400; width += 37) {
        for (final scale in [1.0, 1.3, 1.8, 3.0]) {
          final metrics = BoardMetrics.fit(width, textScale: scale);
          expect(metrics.columns.isEven, isTrue);
          expect(metrics.cellWidth, greaterThanOrEqualTo(0));
          // Every tile is at least as tall as an Android touch target.
          expect(metrics.rowHeight, greaterThanOrEqualTo(48));
          final full = metrics.rect(TileCell(0, 0, metrics.columns, 1));
          expect(full.width, closeTo(width < 10 ? full.width : width, 0.001));
        }
      }
    });

    test('rectangles tile the board with the gap between them', () {
      const metrics = BoardMetrics(
        columns: 4,
        cellWidth: 70,
        rowHeight: 80,
        gap: 10,
      );
      expect(
        metrics.rect(const TileCell(2, 1, 2, 2)),
        const Rect.fromLTWH(160, 90, 150, 170),
      );
      expect(metrics.height(0), 0);
      expect(metrics.height(3), 260);
    });
  });

  group('drag target', () {
    const metrics = BoardMetrics(
      columns: 4,
      cellWidth: 70,
      rowHeight: 70,
      gap: 10,
    );
    // Rows: [small small] [wide] [small small]
    const others = [
      TileSize.small,
      TileSize.wide,
      TileSize.small,
      TileSize.small,
    ];

    int target(Offset center, {int? current}) => nearestInsertion(
      others: others,
      dragged: TileSize.small,
      metrics: metrics,
      center: center,
      current: current,
    );

    Rect cellAt(int index) {
      final sizes = [...others]..insert(index, TileSize.small);
      return metrics.rect(packBoard(sizes, 4).cells[index]);
    }

    test('lands where the lifted tile is held', () {
      // Top left half-row.
      expect(target(const Offset(75, 35)), 0);
      // Bottom right half-row.
      expect(target(const Offset(235, 195), current: 0), 4);
    });

    test('the same position gives the same place wherever it came from', () {
      for (final point in const [
        Offset(75, 35),
        Offset(235, 35),
        Offset(150, 100),
        Offset(75, 195),
        Offset(235, 195),
        Offset(170, 400),
      ]) {
        final first = target(point);
        for (var current = 0; current <= others.length; current++) {
          expect(
            cellAt(target(point, current: current)),
            cellAt(first),
            reason: '$point from $current',
          );
        }
      }
    });

    test('a finger held still never makes tiles trade back and forth', () {
      // Includes points exactly between two places, where the current place
      // must win instead of flipping.
      for (var x = 0.0; x <= 320; x += 16) {
        for (var y = 0.0; y <= 420; y += 11.5) {
          final point = Offset(x, y);
          for (var current = 0; current <= others.length; current++) {
            final settled = target(point, current: current);
            expect(
              target(point, current: settled),
              settled,
              reason: '$point from $current',
            );
          }
        }
      }
      // The middle of the wide row is equally far from the half-row places
      // above and below it: whichever the tile already has is kept.
      const between = Offset(235, 115);
      expect(cellAt(target(between, current: 0)), isNot(cellAt(4)));
      expect(target(between, current: 4), 4);
    });

    test('keeps the current order when several places look the same', () {
      // With dense packing a half tile inserted at 1 or 2 fills the same gap.
      final a = target(const Offset(235, 35), current: 1);
      final b = target(const Offset(235, 35), current: 2);
      expect(a, 1);
      expect(b, 2);
    });
  });
}
