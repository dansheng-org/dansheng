// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../learning_controller.dart';
import '../models/canvas_models.dart';
import 'learning_common.dart';

/// Every enrolled eLearning course, each one opening its own course page.
class CourseListView extends StatelessWidget {
  final LearningController controller;
  final void Function(CanvasCourse course) onOpen;
  final List<CanvasCourse>? courses;
  final String title;
  final VoidCallback? onOpenArchive;

  const CourseListView({
    super.key,
    required this.controller,
    required this.onOpen,
    this.courses,
    this.title = '本学期课程',
    this.onOpenArchive,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ctrl = controller;
    final visibleCourses = courses ?? ctrl.courses;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.school_rounded,
            title: title,
            trailing: [
              if (visibleCourses.isNotEmpty)
                SoftBadge(
                  '${visibleCourses.length}',
                  background: scheme.primaryContainer,
                  foreground: scheme.onPrimaryContainer,
                ),
              if (ctrl.canvasFromCache) const SoftBadge('离线缓存'),
            ],
          ),
          if (onOpenArchive != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onOpenArchive,
                icon: const Icon(Icons.history, size: 18),
                label: const Text('过往学期与其他课程'),
              ),
            ),
          const SizedBox(height: 10),
          if (ctrl.canvasAuthRequired)
            InfoBanner(
              signIn: true,
              message: '学习平台需要登录以获取课程课件',
              actionLabel: '登录 Canvas',
              onAction: ctrl.loginCanvas,
            )
          else if (ctrl.canvasError != null)
            InfoBanner(
              message: ctrl.canvasError!,
              actionLabel: '重试',
              onAction: ctrl.loadCanvas,
            ),
          if (visibleCourses.isEmpty) ...[
            if (ctrl.canvasLoading)
              const SectionSpinner()
            else if (!ctrl.canvasAuthRequired && ctrl.canvasError == null)
              const EmptyHint(icon: Icons.menu_book_rounded, text: '暂无本学期课程'),
          ] else
            for (final course in visibleCourses)
              _CourseTile(
                course: course,
                controller: ctrl,
                onTap: () => onOpen(course),
              ),
        ],
      ),
    );
  }
}

class _CourseTile extends StatelessWidget {
  final CanvasCourse course;
  final LearningController controller;
  final VoidCallback onTap;

  const _CourseTile({
    required this.course,
    required this.controller,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = courseTint(course.name, scheme);
    final now = controller.currentTime();
    final pending = [
      for (final a
          in controller.assignments[course.id] ?? const <CanvasAssignment>[])
        if (!a.hasSubmittedSubmissions &&
            a.dueAt != null &&
            a.dueAt!.isAfter(now))
          a,
    ]..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
    final notices = controller.announcements[course.id]?.length ?? 0;
    final subtitle = [
      if ((course.courseCode ?? '').isNotEmpty) course.courseCode!,
      if ((course.termName ?? '').isNotEmpty) course.termName!,
    ].join(' · ');
    final dark = scheme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tint.background,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    course.name.isEmpty ? '课' : course.name.characters.first,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: tint.foreground,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        course.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      if (pending.isNotEmpty || notices > 0) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 10,
                          runSpacing: 2,
                          children: [
                            if (pending.isNotEmpty)
                              Text(
                                '${pending.length} 项待交 · 最近 ${pending.first.fullDueFormatted}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: dark
                                      ? Colors.amber.shade300
                                      : Colors.amber.shade900,
                                ),
                              ),
                            if (notices > 0)
                              Text(
                                '$notices 条公告',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
