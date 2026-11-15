import 'package:flutter/foundation.dart';

/// What a tile can say about its service beyond its name. A larger tile
/// shows more of it; nothing here decides how it is drawn.
@immutable
class TileFacts {
  const TileFacts({
    this.value,
    this.unit,
    this.note,
    this.rows = const [],
    this.bars = const [],
    this.barsCaption,
  });

  /// The one figure worth a glance, such as a balance or a departure time.
  final String? value;
  final String? unit;

  /// One line that puts [value] in context.
  final String? note;

  /// Further lines, most useful first.
  final List<TileFact> rows;

  /// A small series for the largest size, oldest or first on the left.
  final List<TileBar> bars;
  final String? barsCaption;

  bool get isEmpty =>
      value == null && note == null && rows.isEmpty && bars.isEmpty;

  /// A sentence for screen readers.
  String get spoken => [
    if (value != null) '$value${unit == null ? '' : ' $unit'}',
    ?note,
    for (final row in rows.take(4))
      row.value == null ? row.label : '${row.label} ${row.value}',
  ].join('，');
}

@immutable
class TileFact {
  const TileFact(this.label, {this.value, this.level});

  final String label;
  final String? value;

  /// Share of capacity in use, 0 to 1, drawn as a bar when present.
  final double? level;
}

@immutable
class TileBar {
  const TileBar(this.label, this.value, {this.marked = false});

  final String label;

  /// Not negative. Bars are drawn relative to the largest one.
  final double value;

  /// Draws attention to this bar, such as the current period.
  final bool marked;
}
