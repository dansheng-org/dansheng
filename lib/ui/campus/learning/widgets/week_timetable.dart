// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../learning_controller.dart';
import '../models/timetable_models.dart';
import 'learning_common.dart';

/// Week timetable grid: a unit/time rail on the left, one column per weekday
/// and one tinted block per course spanning its teaching units.
class WeekTimetable extends StatelessWidget {
  final LearningController controller;

  /// Called with the course (or the courses sharing one slot) that was tapped.
  final void Function(List<TimetableCourse> courses)? onOpenCourses;

  const WeekTimetable({
    super.key,
    required this.controller,
    this.onOpenCourses,
  });

  static const _labels = ['一', '二', '三', '四', '五', '六', '日'];
  static const _railWidth = 34.0;
  static const _headerHeight = 52.0;
  static const _rowHeight = 50.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final monday = controller.weekStart;
    final days = [
      for (var i = 0; i < 7; i++)
        DateTime(monday.year, monday.month, monday.day + i),
    ];
    final units = controller.visibleUnits;

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: LayoutBuilder(
        builder: (context, box) {
          final dayWidth = (box.maxWidth - _railWidth) / 7;
          final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
          return SizedBox(
            height: _headerHeight + _rowHeight * units,
            child: Stack(
              children: [
                for (var unit = 1; unit <= units; unit++)
                  Positioned(
                    left: 0,
                    top: _headerHeight + (unit - 1) * _rowHeight,
                    width: _railWidth,
                    height: _rowHeight,
                    child: _UnitLabel(unit: unit, scheme: scheme),
                  ),
                for (var i = 0; i < 7; i++) ...[
                  Positioned(
                    left: _railWidth + i * dayWidth,
                    top: 0,
                    width: dayWidth,
                    height: _headerHeight,
                    child: _DayHeader(
                      label: _labels[i],
                      day: days[i],
                      selected: _same(days[i], controller.selectedDate),
                      today: _same(days[i], controller.today),
                      hasAssignment: controller.hasAssignmentsOn(days[i]),
                      scheme: scheme,
                      onTap: () => controller.selectDate(days[i]),
                    ),
                  ),
                  Positioned(
                    left: _railWidth + i * dayWidth,
                    top: _headerHeight,
                    width: dayWidth,
                    height: _rowHeight * units,
                    child: _DayLane(
                      units: units,
                      selected: _same(days[i], controller.selectedDate),
                      scheme: scheme,
                      onTap: () => controller.selectDate(days[i]),
                    ),
                  ),
                  ..._blocks(days[i], i, dayWidth, units, scale, scheme),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  static bool _same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<Widget> _blocks(
    DateTime day,
    int column,
    double dayWidth,
    int units,
    double scale,
    ColorScheme scheme,
  ) {
    // Courses that share the very same units collapse into one block.
    final slots = <String, List<TimetableCourse>>{};
    for (final course in controller.coursesOn(day)) {
      final start = course.startUnit.clamp(1, units);
      final end = course.endUnit.clamp(start, units);
      slots.putIfAbsent('$start-$end', () => []).add(course);
    }
    return [
      for (final entry in slots.entries)
        _block(entry.value, column, dayWidth, units, scale, scheme),
    ];
  }

  Widget _block(
    List<TimetableCourse> courses,
    int column,
    double dayWidth,
    int units,
    double scale,
    ColorScheme scheme,
  ) {
    final first = courses.first;
    final start = first.startUnit.clamp(1, units);
    final end = first.endUnit.clamp(start, units);
    final height = (end - start + 1) * _rowHeight;
    final tint = courseTint(first.name, scheme);
    final room = first.room ?? '';
    final lines = ((height - 10) / (10 * 1.25 * scale)).floor().clamp(1, 12);
    final title = courses.length > 1
        ? '${first.name} 等${courses.length}门'
        : first.name;

    return Positioned(
      left: _railWidth + column * dayWidth,
      top: _headerHeight + (start - 1) * _rowHeight,
      width: dayWidth,
      height: height,
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: Material(
          color: tint.background,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('timetable-block-${first.weekday}-$start'),
            onTap: onOpenCourses == null ? null : () => onOpenCourses!(courses),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(3, 4, 3, 2),
              child: Align(
                alignment: Alignment.topLeft,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (room.isNotEmpty)
                        TextSpan(
                          text: '\n$room',
                          style: TextStyle(
                            color: tint.foreground.withValues(alpha: 0.78),
                          ),
                        ),
                    ],
                  ),
                  maxLines: lines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.25,
                    color: tint.foreground,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnitLabel extends StatelessWidget {
  final int unit;
  final ColorScheme scheme;

  const _UnitLabel({required this.unit, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final time = TeachingUnit.get(unit);
    final faint = TextStyle(fontSize: 8.5, color: scheme.outline, height: 1.2);
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$unit',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (time != null) ...[
              Text(time.startTimeFormatted, style: faint),
              Text(time.endTimeFormatted, style: faint),
            ],
          ],
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  final String label;
  final DateTime day;
  final bool selected;
  final bool today;
  final bool hasAssignment;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _DayHeader({
    required this.label,
    required this.day,
    required this.selected,
    required this.today,
    required this.hasAssignment,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? scheme.onPrimaryContainer
        : (today ? scheme.primary : scheme.onSurface);
    return Padding(
      padding: const EdgeInsets.fromLTRB(1.5, 0, 1.5, 4),
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: today && !selected
              ? BorderSide(
                  color: scheme.primary.withValues(alpha: 0.5),
                  width: 1.2,
                )
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: selected
                          ? scheme.onPrimaryContainer
                          : (today ? scheme.primary : scheme.onSurfaceVariant),
                    ),
                  ),
                  Text(
                    day.day == 1 ? '${day.month}/1' : '${day.day}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected || today
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: color,
                    ),
                  ),
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.only(top: 1),
                    decoration: BoxDecoration(
                      color: hasAssignment
                          ? Colors.amber.shade700
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty cells of one weekday; tapping them selects that day.
class _DayLane extends StatelessWidget {
  final int units;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _DayLane({
    required this.units,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cell = selected
        ? scheme.primary.withValues(alpha: 0.10)
        : scheme.onSurface.withValues(alpha: 0.05);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        children: [
          for (var unit = 0; unit < units; unit++)
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  color: cell,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
