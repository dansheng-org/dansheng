// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../learning_controller.dart';
import '../models/timetable_models.dart';
import 'week_timetable.dart';
import 'learning_common.dart';

/// Browsable schedule card: the week timetable grid or a month calendar,
/// with period paging, jumping to today and day selection.
class CalendarHeader extends StatelessWidget {
  final LearningController controller;

  /// Called when a course block of the week grid is tapped.
  final void Function(List<TimetableCourse> courses)? onOpenCourses;

  const CalendarHeader({
    super.key,
    required this.controller,
    this.onOpenCourses,
  });

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
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _buildNavigationRow(context, colorScheme),
            ),
            const SizedBox(height: 8),
            if (controller.academicAuthRequired)
              InfoBanner(
                signIn: true,
                message: '登录教务系统以同步课表',
                actionLabel: '登录教务',
                onAction: controller.loginAcademic,
              )
            else if (controller.academicError != null)
              InfoBanner(
                message: controller.academicError!,
                actionLabel: '重试课表',
                onAction: controller.loadAcademic,
              ),
            if (controller.academicLoading) const LinearProgressIndicator(),
            if (controller.calendarViewMode == 'week')
              WeekTimetable(
                controller: controller,
                onOpenCourses: onOpenCourses,
              )
            else
              _buildMonthView(context, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationRow(BuildContext context, ColorScheme colorScheme) {
    final isWeek = controller.calendarViewMode == 'week';
    final monthDate = isWeek
        ? controller.selectedDate
        : controller.calendarMonth;
    final title = '${monthDate.year}年${monthDate.month}月';
    final week = isWeek ? controller.weekOf(controller.selectedDate) : null;

    final heading = Wrap(
      spacing: 8,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        if (week != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '第$week周',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
      ],
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
          tooltip: '上一${isWeek ? '周' : '月'}',
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: controller.prevCalendarPeriod,
        ),
        TextButton(onPressed: controller.jumpToToday, child: const Text('今天')),
        IconButton(
          tooltip: '下一${isWeek ? '周' : '月'}',
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
    final today = controller.today;

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
              return Expanded(
                child: _DayItem(
                  dayNumber: dayNum,
                  isSelected:
                      day.year == sel.year &&
                      day.month == sel.month &&
                      day.day == sel.day,
                  isToday:
                      day.year == today.year &&
                      day.month == today.month &&
                      day.day == today.day,
                  hasCourse: controller.hasCoursesOn(day),
                  hasAssign: controller.hasAssignmentsOn(day),
                  colorScheme: colorScheme,
                  onTap: () => controller.selectDate(day),
                ),
              );
            }),
          );
        }),
        const SizedBox(height: 6),
        Wrap(
          spacing: 14,
          alignment: WrapAlignment.center,
          children: [
            _legend(colorScheme.primary, '有课', colorScheme),
            _legend(Colors.amber.shade700, '作业截止', colorScheme),
          ],
        ),
      ],
    );
  }

  Widget _legend(Color dot, String label, ColorScheme colorScheme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _DayItem extends StatelessWidget {
  final int dayNumber;
  final bool isSelected;
  final bool isToday;
  final bool hasCourse;
  final bool hasAssign;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _DayItem({
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
        constraints: const BoxConstraints(minHeight: 42),
        margin: const EdgeInsets.all(1),
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
