import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Rendering only: values and calendar buckets are aggregated by Core.
class UsageBarChart extends StatefulWidget {
  const UsageBarChart({super.key, required this.buckets, required this.period});
  final List<Map> buckets;
  final String period;
  @override
  State<UsageBarChart> createState() => _UsageBarChartState();
}

class _UsageBarChartState extends State<UsageBarChart> {
  List<Map> get buckets => widget.buckets;
  String get period => widget.period;
  final _scroll = ScrollController();
  bool _latest = true, _scheduled = false;
  String get _signature =>
      '$period:${buckets.length}:${buckets.isEmpty ? '' : buckets.last['start']}';
  @override
  void didUpdateWidget(UsageBarChart old) {
    super.didUpdateWidget(old);
    final previous =
        '${old.period}:${old.buckets.length}:${old.buckets.isEmpty ? '' : old.buckets.last['start']}';
    if (previous != _signature) _latest = true;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void revealLatest() {
    if (!_latest || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
        _latest = false;
      }
    });
  }

  String number(double n) =>
      n.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');
  String label(Map row) {
    final start = DateTime.parse(row['start'].toString());
    return switch (period) {
      'year' => '${start.year}',
      'month' => '${start.year}\n${start.month}月',
      _ => '${start.year}\n${start.month}/${start.day}',
    };
  }

  @override
  Widget build(BuildContext context) {
    if (buckets.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('暂无用电统计记录'),
      );
    }
    final values = buckets
        .map((r) => double.tryParse(r['amount_kwh'].toString()))
        .toList();
    if (values.any((v) => v == null || !v.isFinite || v < 0)) {
      return const Text('无法显示用电统计数据');
    }
    final maximum = values.cast<double>().reduce(math.max);
    final power = maximum <= 0
        ? 1.0
        : math.pow(10, (math.log(maximum) / math.ln10).floor()).toDouble();
    final normalized = maximum / power;
    final top =
        (normalized <= 1
            ? 1
            : normalized <= 2
            ? 2
            : normalized <= 5
            ? 5
            : 10) *
        power;
    final style = Theme.of(context).textTheme.labelSmall!;
    final scaler = MediaQuery.textScalerOf(context);
    double width(String text) {
      final p = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      return p.width;
    }

    final yLabels = [number(top), number(top / 2), '0'];
    final axisWidth = yLabels.map(width).reduce(math.max) + 12;
    final minSlot =
        math.max(
          buckets.map((b) => width(label(b))).reduce(math.max),
          values.map((v) => width(number(v!))).reduce(math.max),
        ) +
        20;
    final topHeight = scaler.scale(24), labelHeight = scaler.scale(38);
    const plotHeight = 120.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        revealLatest();
        final area = math.max(1.0, constraints.maxWidth - axisWidth);
        final slotWidth = math.max(
          math.max(64.0, minSlot),
          area / buckets.length,
        );
        return Semantics(
          label: '用电柱状图，单位千瓦时',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: axisWidth,
                child: Padding(
                  padding: EdgeInsets.only(top: topHeight),
                  child: SizedBox(
                    height: plotHeight,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var i = 0; i < 3; i++)
                          Positioned(
                            top: plotHeight * i / 2 - scaler.scale(7),
                            right: 8,
                            child: Text(yLabels[i], style: style),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scroll,
                  key: const Key('usage_chart_scroll'),
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < buckets.length; i++)
                        SizedBox(
                          width: slotWidth,
                          child: Column(
                            children: [
                              SizedBox(
                                height: topHeight + plotHeight,
                                child: Stack(
                                  children: [
                                    Positioned(
                                      bottom: plotHeight * values[i]! / top + 4,
                                      left: 0,
                                      right: 0,
                                      child: Text(
                                        number(values[i]!),
                                        style: style,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: Container(
                                        key: ValueKey('usage_bar_$i'),
                                        width: 28,
                                        height: plotHeight * values[i]! / top,
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          borderRadius:
                                              const BorderRadius.vertical(
                                                top: Radius.circular(4),
                                              ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                height: labelHeight,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    label(buckets[i]),
                                    key: ValueKey('usage_axis_$i'),
                                    style: style,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
