// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../learning_controller.dart';
import '../models/canvas_models.dart';
import '../models/timetable_models.dart';

/// Shows the courses and due assignments for the currently selected date,
/// with per-source auth/error isolation and interactive summary details.
class DayScheduleView extends StatelessWidget {
  final LearningController controller;

  const DayScheduleView({super.key, required this.controller});

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
    final assignments = controller.assignmentsOnSelectedDate;

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

          // Academic Auth/Error Banners (Per-source isolation)
          if (controller.academicAuthRequired)
            _buildAuthBanner(
              context,
              colorScheme,
              message: '教务系统需要登录以同步课表',
              buttonText: '登录教务',
              onLogin: controller.loginAcademic,
            )
          else if (controller.academicError != null)
            _buildErrorBanner(
              context,
              colorScheme,
              error: controller.academicError!,
              onRetry: controller.loadAcademic,
            ),

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
        else if (courses.isEmpty)
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
              onTap: () => _showCourseDetails(context, c),
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
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${assignments.length}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.amber.shade900,
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
            text: '今日无截止作业',
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
            (a) => _AssignmentCard(
              assignment: a,
              colorScheme: colorScheme,
              onTap: () => _showAssignmentDetails(context, a),
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

  void _showCourseDetails(BuildContext context, TimetableCourse course) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                course.name,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              if (course.courseCode != null)
                Text(
                  '课程代码: ${course.courseCode}',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              const Divider(height: 24),
              _buildDetailItem(
                ctx,
                Icons.access_time_rounded,
                '上课时间',
                course.timeSpanFormatted,
              ),
              if (course.room != null)
                _buildDetailItem(ctx, Icons.room_rounded, '上课地点', course.room!),
              if (course.teachers.isNotEmpty)
                _buildDetailItem(
                  ctx,
                  Icons.person_outline_rounded,
                  '授课教师',
                  course.teachers.join(', '),
                ),
              if (course.weeks.isNotEmpty)
                _buildDetailItem(
                  ctx,
                  Icons.date_range_rounded,
                  '授课周次',
                  '第 ${course.weeks.join(', ')} 周',
                ),
            ],
          ),
        );
      },
    );
  }

  void _showAssignmentDetails(
    BuildContext context,
    CanvasAssignment assignment,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                assignment.name,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              if (assignment.courseName != null)
                Text(
                  assignment.courseName!,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              const Divider(height: 24),
              _buildDetailItem(
                ctx,
                Icons.schedule_rounded,
                '截止时间',
                assignment.fullDueFormatted,
              ),
              if (assignment.pointsPossible != null)
                _buildDetailItem(
                  ctx,
                  Icons.score_rounded,
                  '满分分值',
                  '${assignment.pointsPossible} 分',
                ),
              _buildDetailItem(
                ctx,
                assignment.hasSubmittedSubmissions
                    ? Icons.check_circle_rounded
                    : Icons.pending_rounded,
                '提交状态',
                assignment.hasSubmittedSubmissions ? '已提交' : '待提交',
              ),
              if (assignment.description != null &&
                  assignment.description!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '作业要求说明:',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  assignment.description!
                      .replaceAll(RegExp(r'<[^>]+>'), '')
                      .trim(),
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailItem(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CourseCard extends StatelessWidget {
  final TimetableCourse course;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _CourseCard({
    required this.course,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    course.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    course.timeSpanFormatted,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                if (course.room != null && course.room!.isNotEmpty) ...[
                  Icon(
                    Icons.room_rounded,
                    size: 14,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    course.room!,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                if (course.teachers.isNotEmpty) ...[
                  Icon(
                    Icons.person_outline_rounded,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      course.teachers.join(', '),
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignmentCard extends StatelessWidget {
  final CanvasAssignment assignment;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _AssignmentCard({
    required this.assignment,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSubmitted = assignment.hasSubmittedSubmissions;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSubmitted
                ? colorScheme.outlineVariant.withValues(alpha: 0.4)
                : Colors.amber.shade300,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isSubmitted
                  ? Icons.check_circle_rounded
                  : Icons.pending_actions_rounded,
              size: 20,
              color: isSubmitted
                  ? Colors.green.shade600
                  : Colors.amber.shade700,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    assignment.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (assignment.courseName != null &&
                          assignment.courseName!.isNotEmpty) ...[
                        Text(
                          assignment.courseName!,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        assignment.dueTimeFormatted,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.amber.shade900,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (assignment.pointsPossible != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${assignment.pointsPossible}分',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isSubmitted
                    ? Colors.green.shade50
                    : Colors.amber.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                isSubmitted ? '已提交' : '待提交',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isSubmitted
                      ? Colors.green.shade800
                      : Colors.amber.shade900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
