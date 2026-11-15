import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Footprint of a tile, in cells of the four-column phone grid.
enum TileSize {
  icon('icon', '图标', 1, 1),
  small('small', '小', 2, 1),
  wide('wide', '横条', 4, 1),
  medium('medium', '中', 2, 2),
  large('large', '大', 4, 2);

  const TileSize(this.id, this.label, this.columns, this.rows);

  /// Stored in the saved layout; never rename.
  final String id;
  final String label;
  final int columns, rows;

  String get footprint => '$columns×$rows';

  static TileSize? byId(Object? id) {
    for (final size in values) {
      if (size.id == id) return size;
    }
    return null;
  }
}

/// The services of the eHall home, in their default order.
enum EHallTile {
  ecard('ecard', '校园卡', Icons.receipt_long_outlined),
  rooms('rooms', '教室空位', Icons.meeting_room_outlined),
  power('power', '寝室电量', Icons.bolt_outlined),
  venues('venues', '场馆预约', Icons.sports_tennis_outlined),
  library('library', '图书馆客流', Icons.local_library_outlined),
  dining('dining', '食堂实时客流', Icons.restaurant_outlined),
  bus('bus', '校车班次时刻', Icons.directions_bus_outlined),
  mail('mail', '校园邮箱', Icons.mail_outline),
  notices('notices', '教务公告', Icons.campaign_outlined),
  grades('grades', '课程成绩', Icons.checklist_outlined),
  gpa('gpa', '学分与绩点', Icons.school_outlined),
  exams('exams', '考试安排', Icons.event_note_outlined);

  const EHallTile(this.id, this.title, this.icon);

  /// Stored in the saved layout; never rename.
  final String id;
  final String title;
  final IconData icon;

  static EHallTile? byId(Object? id) {
    for (final tile in values) {
      if (tile.id == id) return tile;
    }
    return null;
  }
}

/// One tile's place in the arrangement. Hidden tiles keep their turn in the
/// order, so showing one again returns it to where it was.
@immutable
class TileSlot {
  const TileSlot(
    this.tile, {
    required this.size,
    this.shown = true,
    this.options = const {},
  });

  final EHallTile tile;
  final TileSize size;
  final bool shown;

  /// Per-tile choices such as a campus or a building. Values are JSON scalars.
  final Map<String, Object> options;

  TileSlot copyWith({
    TileSize? size,
    bool? shown,
    Map<String, Object>? options,
  }) => TileSlot(
    tile,
    size: size ?? this.size,
    shown: shown ?? this.shown,
    options: options ?? this.options,
  );

  Map<String, dynamic> toJson() => {
    'id': tile.id,
    'size': size.id,
    'shown': shown,
    if (options.isNotEmpty) 'options': options,
  };

  @override
  bool operator ==(Object other) =>
      other is TileSlot &&
      other.tile == tile &&
      other.size == size &&
      other.shown == shown &&
      _sameOptions(other.options, options);

  @override
  int get hashCode => Object.hash(tile, size, shown, options.length);

  static bool _sameOptions(Map<String, Object> a, Map<String, Object> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// The saved arrangement of the eHall home: every tile exactly once.
@immutable
class BoardLayout {
  BoardLayout._(List<TileSlot> slots) : slots = List.unmodifiable(slots);

  static const version = 1;

  final List<TileSlot> slots;

  /// The services in their familiar order, sized so the board is useful
  /// before anyone arranges it.
  factory BoardLayout.standard() => BoardLayout._([
    for (final tile in EHallTile.values)
      TileSlot(tile, size: standardSize(tile)),
  ]);

  static TileSize standardSize(EHallTile tile) => switch (tile) {
    EHallTile.ecard => TileSize.wide,
    EHallTile.rooms || EHallTile.power => TileSize.medium,
    EHallTile.mail || EHallTile.grades => TileSize.icon,
    _ => TileSize.small,
  };

  /// Reads a saved layout leniently: unknown tiles and sizes are dropped,
  /// repeated tiles keep their first entry, and services this build knows but
  /// the saved layout does not are appended in their standard form.
  factory BoardLayout.fromJson(Object? json) {
    final saved = json is Map ? json['tiles'] : null;
    if (saved is! List) return BoardLayout.standard();
    final slots = <TileSlot>[];
    final seen = <EHallTile>{};
    for (final entry in saved) {
      if (entry is! Map) continue;
      final tile = EHallTile.byId(entry['id']);
      if (tile == null || !seen.add(tile)) continue;
      final options = <String, Object>{};
      final rawOptions = entry['options'];
      if (rawOptions is Map) {
        for (final option in rawOptions.entries) {
          final value = option.value;
          if (option.key is String &&
              (value is String || value is num || value is bool)) {
            options[option.key as String] = value as Object;
          }
        }
      }
      slots.add(
        TileSlot(
          tile,
          size: TileSize.byId(entry['size']) ?? standardSize(tile),
          shown: entry['shown'] != false,
          options: options,
        ),
      );
    }
    for (final tile in EHallTile.values) {
      if (seen.add(tile)) slots.add(TileSlot(tile, size: standardSize(tile)));
    }
    return BoardLayout._(slots);
  }

  Map<String, dynamic> toJson() => {
    'v': version,
    'tiles': [for (final slot in slots) slot.toJson()],
  };

  List<TileSlot> get shown => [
    for (final slot in slots)
      if (slot.shown) slot,
  ];

  List<TileSlot> get hidden => [
    for (final slot in slots)
      if (!slot.shown) slot,
  ];

  TileSlot slot(EHallTile tile) => slots.firstWhere((s) => s.tile == tile);

  BoardLayout _replace(EHallTile tile, TileSlot Function(TileSlot) change) =>
      BoardLayout._([
        for (final slot in slots)
          if (slot.tile == tile) change(slot) else slot,
      ]);

  BoardLayout resize(EHallTile tile, TileSize size) =>
      _replace(tile, (slot) => slot.copyWith(size: size));

  BoardLayout show(EHallTile tile, bool shown) =>
      _replace(tile, (slot) => slot.copyWith(shown: shown));

  BoardLayout withOption(EHallTile tile, String key, Object? value) =>
      _replace(tile, (slot) {
        final options = Map<String, Object>.of(slot.options);
        if (value == null) {
          options.remove(key);
        } else {
          options[key] = value;
        }
        return slot.copyWith(options: options);
      });

  /// Moves [tile] so that it is the [index]-th of the shown tiles. Hidden
  /// tiles stay next to the shown neighbour they followed.
  BoardLayout moveShown(EHallTile tile, int index) {
    final moving = slot(tile);
    final rest = [
      for (final slot in slots)
        if (slot.tile != tile) slot,
    ];
    var at = rest.length;
    var passed = 0;
    for (var i = 0; i < rest.length; i++) {
      if (!rest[i].shown) continue;
      if (passed == index) {
        at = i;
        break;
      }
      passed++;
    }
    rest.insert(at, moving);
    return BoardLayout._(rest);
  }

  @override
  bool operator ==(Object other) {
    if (other is! BoardLayout || other.slots.length != slots.length) {
      return false;
    }
    for (var i = 0; i < slots.length; i++) {
      if (other.slots[i] != slots[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(slots);
}

/// Cell rectangle of a packed tile.
@immutable
class TileCell {
  const TileCell(this.column, this.row, this.columns, this.rows);
  final int column, row, columns, rows;

  @override
  bool operator ==(Object other) =>
      other is TileCell &&
      other.column == column &&
      other.row == row &&
      other.columns == columns &&
      other.rows == rows;

  @override
  int get hashCode => Object.hash(column, row, columns, rows);

  @override
  String toString() => 'TileCell($column,$row ${columns}x$rows)';
}

class BoardPacking {
  const BoardPacking(this.cells, this.rows);

  /// One cell per packed size, in the order given.
  final List<TileCell> cells;
  final int rows;
}

/// Width in cells of [size] on a board of [columns]. Boards narrower than
/// the four-column reference scale footprints down; wider ones keep them, so
/// more tiles sit side by side.
int tileColumns(TileSize size, int columns) {
  if (columns >= 4) return math.min(size.columns, columns);
  return math.max(1, (size.columns * columns / 4).round());
}

/// Packs tiles in reading order. Each takes the first free place where it
/// fits, so a later small tile may fill a gap an earlier wide one left.
BoardPacking packBoard(List<TileSize> sizes, int columns) {
  assert(columns > 0);
  final taken = <List<bool>>[];
  bool free(int column, int row, int w, int h) {
    for (var r = row; r < row + h; r++) {
      if (r >= taken.length) continue;
      for (var c = column; c < column + w; c++) {
        if (taken[r][c]) return false;
      }
    }
    return true;
  }

  final cells = <TileCell>[];
  for (final size in sizes) {
    final w = tileColumns(size, columns);
    final h = size.rows;
    placing:
    for (var row = 0; ; row++) {
      for (var column = 0; column + w <= columns; column++) {
        if (!free(column, row, w, h)) continue;
        while (taken.length < row + h) {
          taken.add(List.filled(columns, false));
        }
        for (var r = row; r < row + h; r++) {
          for (var c = column; c < column + w; c++) {
            taken[r][c] = true;
          }
        }
        cells.add(TileCell(column, row, w, h));
        break placing;
      }
    }
  }
  return BoardPacking(cells, taken.length);
}

/// Pixel geometry of a board.
@immutable
class BoardMetrics {
  const BoardMetrics({
    required this.columns,
    required this.cellWidth,
    required this.rowHeight,
    required this.gap,
  });

  /// Chooses the column count for [width] so cells stay comfortably
  /// touchable at the given text scale. Always even, so half-width tiles pair.
  factory BoardMetrics.fit(double width, {double textScale = 1}) {
    const gap = 10.0;
    final scale = math.min(1.6, math.max(1.0, textScale));
    final least = 64.0 * scale;
    final fitting = ((width + gap) / (least + gap)).floor();
    final columns = math.min(8, math.max(2, fitting - fitting % 2));
    final cellWidth = math.max(0.0, (width - gap * (columns - 1)) / columns);
    return BoardMetrics(
      columns: columns,
      cellWidth: cellWidth,
      rowHeight: math.min(92.0 * scale, math.max(72.0 * scale, cellWidth)),
      gap: gap,
    );
  }

  final int columns;
  final double cellWidth, rowHeight, gap;

  Rect rect(TileCell cell) => Rect.fromLTWH(
    cell.column * (cellWidth + gap),
    cell.row * (rowHeight + gap),
    cell.columns * cellWidth + (cell.columns - 1) * gap,
    cell.rows * rowHeight + (cell.rows - 1) * gap,
  );

  double height(int rows) =>
      rows <= 0 ? 0 : rows * rowHeight + (rows - 1) * gap;
}

/// Where a dragged tile should sit among [others] (the shown tiles without
/// it, in order) so that its packed place lies nearest to [center], the
/// middle of the lifted tile in board coordinates.
///
/// A place has to be strictly nearer than the [current] one to replace it,
/// so a finger held still, even exactly between two places, never makes
/// tiles trade back and forth, and the order changes only when the tile
/// actually lands elsewhere.
int nearestInsertion({
  required List<TileSize> others,
  required TileSize dragged,
  required BoardMetrics metrics,
  required Offset center,
  int? current,
}) {
  var best = 0;
  var bestDistance = double.infinity;
  for (var index = 0; index <= others.length; index++) {
    final sizes = [...others]..insert(index, dragged);
    final cell = packBoard(sizes, metrics.columns).cells[index];
    final distance = (metrics.rect(cell).center - center).distanceSquared;
    final better = distance < bestDistance - 0.5;
    final tie = (distance - bestDistance).abs() <= 0.5;
    if (better || (tie && index == current)) {
      best = index;
      bestDistance = math.min(distance, bestDistance);
    }
  }
  return best;
}
