// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../learning_controller.dart';

/// Compact browsable calendar widget supporting week/month toggle,
/// month paging, jumping to today, and day selection with course/assignment dots.
class CalendarHeader extends StatelessWidget {
  final LearningController controller;

  const CalendarHeader({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildNavigationRow(context, colorScheme),
            const SizedBox(height: 8),
            if (controller.calendarViewMode == 'week')
              _buildWeekView(context, colorScheme)
            else
              _buildMonthView(context, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationRow(BuildContext context, ColorScheme colorScheme) {
    final monthDate = controller.calendarViewMode == 'week'
        ? controller.selectedDate
        : controller.calendarMonth;
    final title = '${monthDate.year}年${monthDate.month}月';

    final heading = Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
    );
    final toggle = SegmentedButton<String>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: 'week', label: Text('周')),
        ButtonSegment(value: 'month', label: Text('月')),
      ],
      selected: {controller.calendarViewMode},
      onSelectionChanged: (v) => controller.setCalendarViewMode(v.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
    final paging = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '上一${controller.calendarViewMode == 'week' ? '周' : '月'}',
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: controller.prevCalendarPeriod,
        ),
        TextButton(onPressed: controller.jumpToToday, child: const Text('今天')),
        IconButton(
          tooltip: '下一${controller.calendarViewMode == 'week' ? '周' : '月'}',
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: controller.nextCalendarPeriod,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (box.maxWidth >= 460 * scale) {
          return Row(
            children: [
              Expanded(child: heading),
              paging,
              const SizedBox(width: 6),
              toggle,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [heading, toggle],
            ),
            Align(alignment: Alignment.center, child: paging),
          ],
        );
      },
    );
  }

  Widget _buildWeekView(BuildContext context, ColorScheme colorScheme) {
    // Find Monday of the current selectedDate week
    final sel = controller.selectedDate;
    final monday = sel.subtract(Duration(days: sel.weekday - 1));

    final weekDays = List.generate(7, (i) => monday.add(Duration(days: i)));
    const weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: List.generate(7, (i) {
        final day = weekDays[i];
        final isSelected =
            day.year == sel.year &&
            day.month == sel.month &&
            day.day == sel.day;
        final isToday = _isToday(day);
        final hasCourse = controller.hasCoursesOn(day);
        final hasAssign = controller.hasAssignmentsOn(day);

        return Expanded(
          child: _DayItem(
            weekdayLabel: weekdayLabels[i],
            dayNumber: day.day,
            isSelected: isSelected,
            isToday: isToday,
            hasCourse: hasCourse,
            hasAssign: hasAssign,
            colorScheme: colorScheme,
            onTap: () => controller.selectDate(day),
          ),
        );
      }),
    );
  }

  /// Month calendar grid with weekday headers.
  Widget _buildMonthView(BuildContext context, ColorScheme colorScheme) {
    final firstDayOfMonth = controller.calendarMonth;
    final daysInMonth = DateTime(
      firstDayOfMonth.year,
      firstDayOfMonth.month + 1,
      0,
    ).day;

    // Start with Monday padding
    final startOffset = firstDayOfMonth.weekday - 1; // 0 for Mon, 6 for Sun
    final totalCells = startOffset + daysInMonth;
    final totalRows = (totalCells / 7).ceil();

    const weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];
    final sel = controller.selectedDate;

    return Column(
      children: [
        // Weekday header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: weekdayLabels.map((lbl) {
            return Expanded(
              child: Center(
                child: Text(
                  lbl,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 4),
        // Grid
        ...List.generate(totalRows, (row) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(7, (col) {
              final cellIndex = row * 7 + col;
              final dayNum = cellIndex - startOffset + 1;

              if (dayNum < 1 || dayNum > daysInMonth) {
                return const Expanded(child: SizedBox(height: 44));
              }

              final day = DateTime(
                firstDayOfMonth.year,
                firstDayOfMonth.month,
                dayNum,
              );
              final isSelected =
                  day.year == sel.year &&
                  day.month == sel.month &&
                  day.day == sel.day;
              final isToday = _isToday(day);
              final hasCourse = controller.hasCoursesOn(day);
              final hasAssign = controller.hasAssignmentsOn(day);

              return Expanded(
                child: _DayItem(
                  weekdayLabel: null,
                  dayNumber: dayNum,
                  isSelected: isSelected,
                  isToday: isToday,
                  hasCourse: hasCourse,
                  hasAssign: hasAssign,
                  colorScheme: colorScheme,
                  onTap: () => controller.selectDate(day),
                ),
              );
            }),
          );
        }),
      ],
    );
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }
}

class _DayItem extends StatelessWidget {
  final String? weekdayLabel;
  final int dayNumber;
  final bool isSelected;
  final bool isToday;
  final bool hasCourse;
  final bool hasAssign;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _DayItem({
    this.weekdayLabel,
    required this.dayNumber,
    required this.isSelected,
    required this.isToday,
    required this.hasCourse,
    required this.hasAssign,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isSelected
        ? colorScheme.primaryContainer
        : (isToday ? colorScheme.surfaceContainerHighest : Colors.transparent);
    final textColor = isSelected
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: BoxConstraints(minHeight: weekdayLabel != null ? 54 : 42),
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: isToday && !isSelected
              ? Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.5),
                  width: 1.2,
                )
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (weekdayLabel != null) ...[
              Text(
                weekdayLabel!,
                style: TextStyle(
                  fontSize: 11,
                  color: isSelected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
            ],
            Text(
              '$dayNumber',
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected || isToday
                    ? FontWeight.bold
                    : FontWeight.normal,
                color: textColor,
              ),
            ),
            const SizedBox(height: 2),
            // Event indicators
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (hasCourse)
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                if (hasAssign)
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade700,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
