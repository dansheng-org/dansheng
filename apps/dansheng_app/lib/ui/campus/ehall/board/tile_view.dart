import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'board_layout.dart';
import 'tile_facts.dart';

/// The face of one tile at one size: the service name and as much of its
/// [facts] as the size has room for. Purely presentational; it never
/// overflows, whatever the text scale, and drops detail before it clips.
class TileFace extends StatelessWidget {
  const TileFace({
    super.key,
    required this.tile,
    required this.size,
    this.facts,
    this.status,
    this.alert = false,
    this.stale = false,
    this.age,
  });

  final EHallTile tile;
  final TileSize size;
  final TileFacts? facts;

  /// Stands in for missing data, or explains why it could not be renewed.
  final String? status;

  /// Whether [status] needs the person to act, such as signing in.
  final bool alert;

  /// The facts are older than this service stays current.
  final bool stale;

  /// When the facts were read, in words such as "3 分钟前".
  final String? age;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => ClipRect(
      child: switch (size) {
        TileSize.icon => _icon(context),
        TileSize.small => _small(context, box),
        TileSize.wide => _wide(context, box),
        TileSize.medium => _medium(context, box),
        TileSize.large => _large(context, box),
      },
    ),
  );

  bool get _hasFigure => facts?.value != null;

  /// The line under the title: context for the figure, or the reason there
  /// is none.
  String? get _note => status ?? facts?.note;

  static double _line(BuildContext context, TextStyle style) =>
      MediaQuery.textScalerOf(context).scale(style.fontSize ?? 14) *
      (style.height ?? 1.25);

  TextStyle _titleStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.labelLarge!.copyWith(
      fontSize: 13,
      height: 18 / 13,
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  TextStyle _noteStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall!.copyWith(
      height: 16 / 12,
      color: alert
          ? theme.colorScheme.onTertiaryContainer
          : theme.colorScheme.onSurfaceVariant,
    );
  }

  TextStyle _figureStyle(BuildContext context, double fontSize) {
    final theme = Theme.of(context);
    return theme.textTheme.headlineSmall!.copyWith(
      fontSize: fontSize,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      color: stale
          ? theme.colorScheme.onSurfaceVariant
          : theme.colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  Widget _heading(BuildContext context, {String? trailing, double? width}) {
    final style = _titleStyle(context);
    // The age only joins the title when both fit comfortably.
    if (width != null &&
        width < 70 + MediaQuery.textScalerOf(context).scale(13) * 7) {
      trailing = null;
    }
    return Row(
      children: [
        Icon(tile.icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            tile.title,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              trailing,
              style: _noteStyle(context).copyWith(fontSize: 11),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
            ),
          ),
        ],
      ],
    );
  }

  /// The figure with its unit, shrunk rather than cut when it is long.
  Widget _figure(
    BuildContext context,
    double fontSize, {
    Alignment alignment = Alignment.centerLeft,
  }) {
    final style = _figureStyle(context, fontSize);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text.rich(
        TextSpan(
          text: facts!.value,
          children: [
            if (facts!.unit != null)
              TextSpan(
                text: ' ${facts!.unit}',
                style: style.copyWith(
                  fontSize: math.max(11, fontSize * 0.5),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        style: style,
        maxLines: 1,
      ),
    );
  }

  Widget _noteText(BuildContext context, {int maxLines = 1}) => Text(
    _note!,
    style: _noteStyle(context),
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
  );

  Widget _icon(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(tile.icon, size: 24, color: theme.colorScheme.primary),
          const SizedBox(height: 5),
          Flexible(
            child: Text(
              tile.title,
              style: theme.textTheme.labelMedium!.copyWith(
                fontSize: 11.5,
                height: 1.2,
                color: theme.colorScheme.onSurface,
              ),
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _small(BuildContext context, BoxConstraints box) {
    const pad = EdgeInsets.fromLTRB(12, 9, 12, 9);
    final inner = box.maxHeight - pad.vertical;
    final title = _line(context, _titleStyle(context));
    // Room left for one more line under the title.
    final second = inner - title - 2;
    return Padding(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context),
          if (_hasFigure)
            Expanded(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: _figure(context, math.min(21, math.max(15, second))),
              ),
            )
          else if (_note != null &&
              second >= _line(context, _noteStyle(context)))
            Expanded(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: _noteText(context),
              ),
            ),
        ],
      ),
    );
  }

  Widget _wide(BuildContext context, BoxConstraints box) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium!.copyWith(
      fontSize: 15,
      height: 20 / 15,
    );
    final twoLines =
        _note != null &&
        box.maxHeight >=
            _line(context, titleStyle) +
                _line(context, _noteStyle(context)) +
                8;
    final badge = math.min(40.0, box.maxHeight - 16);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          if (badge >= 28) ...[
            Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.6,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                tile.icon,
                size: badge * 0.55,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    tile.title,
                    style: titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (twoLines) Flexible(child: _noteText(context)),
              ],
            ),
          ),
          if (_hasFigure) ...[
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.42),
              child: _figure(context, 22, alignment: Alignment.centerRight),
            ),
          ],
        ],
      ),
    );
  }

  Widget _medium(BuildContext context, BoxConstraints box) {
    const pad = EdgeInsets.all(12);
    final inner = box.maxHeight - pad.vertical;
    final noteLine = _line(context, _noteStyle(context));
    var left = inner - _line(context, _titleStyle(context)) - 6;
    final figure = _hasFigure && left >= 24;
    if (figure) left -= _line(context, _figureStyle(context, 28));
    final noteLines = _note == null
        ? 0
        : math.min(figure ? 1 : 3, (left / noteLine).floor());
    left -= noteLines * noteLine;
    final rows = _fitRows(context, left - 8);
    return Padding(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            context,
            trailing: age,
            width: box.maxWidth - pad.horizontal,
          ),
          const SizedBox(height: 6),
          if (figure) _figure(context, 28),
          if (noteLines > 0) _noteText(context, maxLines: noteLines),
          if (rows.isNotEmpty) ...[const Spacer(), ...rows],
        ],
      ),
    );
  }

  Widget _large(BuildContext context, BoxConstraints box) {
    const pad = EdgeInsets.fromLTRB(14, 12, 14, 12);
    final inner = box.maxHeight - pad.vertical;
    final noteLine = _line(context, _noteStyle(context));
    var left = inner - _line(context, _titleStyle(context)) - 6;
    final figure = _hasFigure && left >= 24;
    if (figure) left -= _line(context, _figureStyle(context, 30));
    final noteLines = _note == null
        ? 0
        : math.min(figure ? 2 : 4, (left / noteLine).floor());
    final bars = facts?.bars ?? const <TileBar>[];
    final chart = bars.length >= 2 && inner >= 96;
    final chartHeight = chart ? math.min(92.0, inner * 0.62) : 0.0;
    final rows = _fitRows(context, chart ? inner - chartHeight - 6 : inner);
    final detail = chart || rows.isNotEmpty;
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(context, trailing: detail ? null : age),
        const SizedBox(height: 6),
        if (figure) _figure(context, 30),
        if (noteLines > 0) _noteText(context, maxLines: noteLines),
        if (detail && age != null) ...[
          const Spacer(),
          Text(
            age!,
            style: _noteStyle(context).copyWith(fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
    return Padding(
      padding: pad,
      child: !detail
          ? summary
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: summary),
                const SizedBox(width: 14),
                Expanded(
                  flex: 7,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (chart)
                        SizedBox(
                          height: chartHeight,
                          child: MiniBars(
                            bars: bars,
                            caption: facts?.barsCaption,
                          ),
                        ),
                      if (chart && rows.isNotEmpty) const SizedBox(height: 6),
                      ...rows,
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// As many detail rows as fit in [height], most useful first.
  List<Widget> _fitRows(BuildContext context, double height) {
    final all = facts?.rows ?? const <TileFact>[];
    if (all.isEmpty) return const [];
    final style = _noteStyle(context)
        .copyWith(color: Theme.of(context).colorScheme.onSurface);
    final line = _line(context, style);
    const gap = 5.0;
    final rows = <Widget>[];
    var used = 0.0;
    for (final fact in all) {
      final needed = line + (fact.level == null ? 0 : 6) + gap;
      if (used + needed - gap > height) break;
      used += needed;
      rows.add(_FactRow(fact: fact, style: style, gap: gap));
    }
    return rows;
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.fact, required this.style, required this.gap});
  final TileFact fact;
  final TextStyle style;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final level = fact.level;
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                Expanded(
                  child: Text(
                    fact.label,
                    style: style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (fact.value != null) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * 0.55),
                    child: Text(
                      fact.value!,
                      style: style.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (level != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: level.clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: colors.surfaceContainerHigh,
                  color: level >= 0.85 ? colors.error : colors.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A compact bar series: no scrolling, labels only where they fit.
class MiniBars extends StatelessWidget {
  const MiniBars({super.key, required this.bars, this.caption});
  final List<TileBar> bars;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = theme.textTheme.labelSmall!.copyWith(
      fontSize: 10,
      height: 1.2,
      color: colors.onSurfaceVariant,
    );
    final top = bars.fold<double>(0, (m, b) => math.max(m, b.value));
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, box) {
          final line = MediaQuery.textScalerOf(context).scale(10) * 1.2;
          final showCaption = caption != null && box.maxHeight >= line * 2 + 30;
          // Label every bar when there is room, else only the ends.
          final every = box.maxWidth / bars.length >= 22;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showCaption)
                Text(
                  caption!,
                  style: label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final bar in bars)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1.5),
                          child: FractionallySizedBox(
                            heightFactor: top <= 0
                                ? 0.04
                                : math.max(0.04, bar.value / top),
                            alignment: Alignment.bottomCenter,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: bar.marked
                                    ? colors.primary
                                    : colors.primary.withValues(alpha: 0.35),
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  for (var i = 0; i < bars.length; i++)
                    Expanded(
                      child: Text(
                        every || i == 0 || i == bars.length - 1
                            ? bars[i].label
                            : '',
                        style: bars[i].marked
                            ? label.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              )
                            : label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
