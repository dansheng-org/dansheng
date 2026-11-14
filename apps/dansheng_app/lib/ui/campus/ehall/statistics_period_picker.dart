import 'package:flutter/material.dart';

Future<DateTime?> showStatisticsPeriodPicker(
  BuildContext context, {
  required String period,
  required DateTime selected,
  required DateTime today,
}) => showDialog<DateTime>(
  context: context,
  builder: (_) =>
      _PeriodPicker(period: period, selected: selected, today: today),
);

class _PeriodPicker extends StatefulWidget {
  const _PeriodPicker({
    required this.period,
    required this.selected,
    required this.today,
  });
  final String period;
  final DateTime selected, today;
  @override
  State<_PeriodPicker> createState() => _PeriodPickerState();
}

class _PeriodPickerState extends State<_PeriodPicker> {
  late int year = widget.selected.year, month = widget.selected.month;
  late bool choosingYear = widget.period == 'year';
  @override
  Widget build(BuildContext context) {
    final title = widget.period == 'week'
        ? '选择整周'
        : widget.period == 'month'
        ? '选择月份'
        : '选择年份';
    return AlertDialog(
      key: ValueKey('statistics_picker_${widget.period}'),
      title: Text(title),
      content: SizedBox(
        width: 340,
        height: 360,
        child: Column(
          children: [
            if (!choosingYear)
              Row(
                children: [
                  IconButton(
                    tooltip: '上一个',
                    onPressed:
                        year == 2020 && (widget.period != 'week' || month == 1)
                        ? null
                        : () => shift(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => setState(() => choosingYear = true),
                      child: Text(
                        widget.period == 'week' ? '$year年 $month月' : '$year年',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '下一个',
                    onPressed:
                        year == widget.today.year &&
                            (widget.period != 'week' ||
                                month == widget.today.month)
                        ? null
                        : () => shift(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            Expanded(
              child: choosingYear
                  ? YearPicker(
                      firstDate: DateTime(2020),
                      lastDate: widget.today,
                      selectedDate: DateTime(year),
                      onChanged: (date) {
                        if (widget.period == 'year') {
                          Navigator.pop(context, DateTime(date.year));
                        } else {
                          setState(() {
                            year = date.year;
                            month = year == widget.today.year
                                ? month.clamp(1, widget.today.month)
                                : month;
                            choosingYear = false;
                          });
                        }
                      },
                    )
                  : widget.period == 'month'
                  ? GridView.count(
                      crossAxisCount: 3,
                      childAspectRatio: 1.6,
                      children: [
                        for (var m = 1; m <= 12; m++)
                          TextButton(
                            key: ValueKey('statistics_month_$m'),
                            onPressed:
                                year == widget.today.year &&
                                    m > widget.today.month
                                ? null
                                : () =>
                                      Navigator.pop(context, DateTime(year, m)),
                            child: Text('$m月'),
                          ),
                      ],
                    )
                  : weekCalendar(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }

  void shift(int direction) {
    setState(() {
      if (widget.period == 'week') {
        final d = DateTime(year, month + direction);
        year = d.year;
        month = d.month;
      } else {
        year += direction;
      }
    });
  }

  Widget weekCalendar() {
    final first = DateTime(year, month);
    final monday = DateTime(year, month, 2 - first.weekday);
    final rows = ((DateTime(year, month + 1, 0).day + first.weekday - 1) / 7)
        .ceil();
    final selected = DateTime(
      widget.selected.year,
      widget.selected.month,
      widget.selected.day - widget.selected.weekday + 1,
    );
    return Column(
      children: [
        Row(
          children: [
            for (final day in ['一', '二', '三', '四', '五', '六', '日'])
              Expanded(child: Text(day, textAlign: TextAlign.center)),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              for (var row = 0; row < rows; row++)
                Builder(
                  builder: (context) {
                    final start = DateTime(
                      monday.year,
                      monday.month,
                      monday.day + row * 7,
                    );
                    final active =
                        start.year == selected.year &&
                        start.month == selected.month &&
                        start.day == selected.day;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: OutlinedButton(
                        key: ValueKey('statistics_week_$row'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 2,
                          ),
                          backgroundColor: active
                              ? Theme.of(context).colorScheme.primaryContainer
                              : null,
                        ),
                        onPressed:
                            DateTime.utc(
                              start.year,
                              start.month,
                              start.day,
                            ).isAfter(
                              DateTime.utc(
                                widget.today.year,
                                widget.today.month,
                                widget.today.day,
                              ),
                            )
                            ? null
                            : () => Navigator.pop(context, start),
                        child: Row(
                          children: [
                            for (var col = 0; col < 7; col++)
                              Expanded(
                                child: Text(
                                  '${DateTime(start.year, start.month, start.day + col).day}',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
