// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../learning_controller.dart';
import '../models/canvas_models.dart';
import '../models/timetable_models.dart';
import 'assignment_widgets.dart';
import 'learning_common.dart';

export 'assignment_widgets.dart';

/// Shows the courses and due assignments for the currently selected date,
/// with per-source auth/error isolation and interactive summary details.
class DayScheduleView extends StatelessWidget {
  final LearningController controller;

  /// Opens the eLearning page of a timetable course.
  final void Function(TimetableCourse course)? onOpenCourse;

  const DayScheduleView({
    super.key,
    required this.controller,
    this.onOpenCourse,
  });

  static const List<String> _weekdays = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sel = controller.selectedDate;
    final weekdayStr = _weekdays[sel.weekday - 1];
    final dateStr = '${sel.month}月${sel.day}日 $weekdayStr';

    final courses = controller.coursesOnSelectedDate;
    final assignments = controller.deadlineAssignments;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header with date
          Row(
            children: [
              Icon(
                Icons.event_note_rounded,
                size: 18,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                dateStr,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              if (controller.academicFromCache) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '离线课表',
                    style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (controller.canvasFromCache) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '离线作业',
                    style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // Courses Section
          _buildCoursesSection(context, colorScheme, courses),
          const SizedBox(height: 16),

          // Assignments Section with strict auth-failure isolation (no false 'no homework')
          _buildAssignmentsSection(context, colorScheme, assignments),
        ],
      ),
    );
  }

  Widget _buildCoursesSection(
    BuildContext context,
    ColorScheme colorScheme,
    List<TimetableCourse> courses,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '当日课程',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${courses.length}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (controller.academicLoading && courses.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (courses.isEmpty &&
            !controller.academicAuthRequired &&
            controller.academicError == null)
          _buildEmptyPlaceholder(
            context,
            colorScheme,
            icon: Icons.calendar_today_outlined,
            text: '今日暂无课程安排',
          )
        else
          ...courses.map(
            (c) => _CourseCard(
              course: c,
              colorScheme: colorScheme,
              onTap: onOpenCourse == null ? null : () => onOpenCourse!(c),
            ),
          ),
      ],
    );
  }

  Widget _buildAssignmentsSection(
    BuildContext context,
    ColorScheme colorScheme,
    List<CanvasAssignment> assignments,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '截止作业',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${assignments.length}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.brightness == Brightness.dark
                      ? Colors.amber.shade300
                      : Colors.amber.shade900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // No false 'no homework' after auth failure
        if (controller.canvasAuthRequired)
          _buildAuthBanner(
            context,
            colorScheme,
            message: '学习平台需要登录以获取截止作业',
            buttonText: '登录 Canvas',
            onLogin: controller.loginCanvas,
          )
        else if (controller.canvasLoading && assignments.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if ((controller.canvasError ?? controller.assignmentError) !=
                null &&
            assignments.isEmpty)
          _buildErrorBanner(
            context,
            colorScheme,
            error: (controller.canvasError ?? controller.assignmentError)!,
            onRetry: controller.loadCanvas,
          )
        else if (assignments.isEmpty)
          _buildEmptyPlaceholder(
            context,
            colorScheme,
            icon: Icons.assignment_turned_in_outlined,
            text: '暂无截止作业',
          )
        else ...[
          if ((controller.canvasError ?? controller.assignmentError) != null)
            _buildErrorBanner(
              context,
              colorScheme,
              error: (controller.canvasError ?? controller.assignmentError)!,
              onRetry: controller.loadCanvas,
            ),
          ...assignments.map(
            (a) => AssignmentCard(
              assignment: a,
              colorScheme: colorScheme,
              showDate: true,
              submission: controller.submissionFor(a),
              statusLoading: controller.isSubmissionLoading(a),
              onTap: () => showAssignmentDetails(context, controller, a),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAuthBanner(
    BuildContext context,
    ColorScheme colorScheme, {
    required String message,
    required String buttonText,
    required VoidCallback onLogin,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 20, color: colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
          FilledButton.tonal(
            onPressed: onLogin,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(
    BuildContext context,
    ColorScheme colorScheme, {
    required String error,
    required VoidCallback onRetry,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              error,
              style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyPlaceholder(
    BuildContext context,
    ColorScheme colorScheme, {
    required IconData icon,
    required String text,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          Icon(icon, size: 24, color: colorScheme.outline),
          const SizedBox(height: 4),
          Text(
            text,
            style: TextStyle(fontSize: 13, color: colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

class _CourseCard extends StatelessWidget {
  final TimetableCourse course;
  final ColorScheme colorScheme;
  final VoidCallback? onTap;

  const _CourseCard({
    required this.course,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tint = courseTint(course.name, colorScheme);
    final room = course.room ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 5, color: tint.accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 4, 11),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          course.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          course.timeSpanFormatted,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.primary,
                          ),
                        ),
                        if (room.isNotEmpty || course.teachers.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 14,
                            runSpacing: 2,
                            children: [
                              if (room.isNotEmpty)
                                _meta(Icons.room_rounded, room),
                              if (course.teachers.isNotEmpty)
                                _meta(
                                  Icons.person_outline_rounded,
                                  course.teachers.join(', '),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (onTap != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
