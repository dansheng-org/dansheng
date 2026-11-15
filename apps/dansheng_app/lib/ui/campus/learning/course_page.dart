// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import 'learning_controller.dart';
import 'people/course_people_page.dart';
import 'chat/learning_chat_page.dart';
import 'models/canvas_models.dart';
import 'models/timetable_models.dart';
import 'widgets/course_files_view.dart';
import 'widgets/learning_common.dart';

/// One course: its weekly sessions from the timetable on top, and the
/// eLearning files, assignments and announcements of the matched course below.
class CoursePage extends StatefulWidget {
  final LearningController controller;

  /// The timetable course this page was opened from, if any.
  final TimetableCourse? session;

  /// The eLearning course to show; resolved from [session] when absent.
  final String? canvasCourseId;

  const CoursePage({
    super.key,
    required this.controller,
    this.session,
    this.canvasCourseId,
  });

  @override
  State<CoursePage> createState() => _CoursePageState();
}

class _CoursePageState extends State<CoursePage> {
  static const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  CanvasCourse? get _canvas {
    final ctrl = widget.controller;
    final session = widget.session;
    return ctrl.courseById(widget.canvasCourseId) ??
        (session == null ? null : ctrl.canvasCourseFor(session));
  }

  /// A course that only got matched after this page opened (e.g. after
  /// signing in) still has to be selected so its files are fetched.
  void _ensureSelected(CanvasCourse? canvas) {
    if (canvas == null || widget.controller.selectedCourseId == canvas.id) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.selectedCourseId != canvas.id) {
        widget.controller.selectCourse(canvas.id);
      }
    });
  }

  Future<void> _refresh() {
    final canvas = _canvas;
    return canvas == null
        ? widget.controller.loadCanvas()
        : widget.controller.loadCourseDetails(canvas.id);
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final session = widget.session;
        final canvas = _canvas;
        _ensureSelected(canvas);
        final sessions = session != null
            ? ctrl.sessionsNamed(session.name)
            : (canvas == null
                  ? const <TimetableCourse>[]
                  : ctrl.sessionsFor(canvas));
        final lead = session ?? (sessions.isEmpty ? null : sessions.first);
        final name = lead?.name ?? canvas?.name ?? '课程';

        return Scaffold(
          appBar: AppBar(
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
            ),
            actions: [
              if (canvas != null)
                IconButton(
                  tooltip: '课程聊天',
                  icon: const Icon(Icons.forum_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          LearningChatPage(controller: ctrl, course: canvas),
                    ),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '刷新',
                onPressed: _refresh,
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _buildSummary(scheme, name, lead, sessions, canvas),
                if (canvas != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.people_outline),
                      label: const Text('课程人员'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => CoursePeoplePage(
                            controller: ctrl,
                            course: canvas,
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                SectionHeader(
                  icon: Icons.school_rounded,
                  title: 'eLearning',
                  trailing: [
                    if (canvas != null && ctrl.canvasFromCache)
                      const SoftBadge('离线缓存'),
                  ],
                ),
                const SizedBox(height: 10),
                if (canvas != null)
                  CourseFilesView(
                    key: ValueKey(canvas.id),
                    controller: ctrl,
                    courseId: canvas.id,
                  )
                else if (ctrl.canvasAuthRequired)
                  InfoBanner(
                    signIn: true,
                    message: '学习平台需要登录以获取课程课件',
                    actionLabel: '登录 Canvas',
                    onAction: ctrl.loginCanvas,
                  )
                else if (ctrl.canvasLoading)
                  const SectionSpinner()
                else if (ctrl.canvasError != null)
                  InfoBanner(
                    message: ctrl.canvasError!,
                    actionLabel: '重试',
                    onAction: ctrl.loadCanvas,
                  )
                else
                  const EmptyHint(
                    icon: Icons.link_off_rounded,
                    text: 'eLearning 中暂未找到与这门课对应的课程',
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSummary(
    ColorScheme scheme,
    String name,
    TimetableCourse? lead,
    List<TimetableCourse> sessions,
    CanvasCourse? canvas,
  ) {
    final tint = courseTint(name, scheme);
    final teachers = <String>{for (final s in sessions) ...s.teachers};
    final tags = <String>{
      if ((lead?.courseCode ?? '').isNotEmpty) lead!.courseCode!,
      if ((canvas?.courseCode ?? '').isNotEmpty) canvas!.courseCode!,
      if ((canvas?.termName ?? '').isNotEmpty) canvas!.termName!,
    };

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: tint.background,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: tint.foreground,
                  ),
                ),
                if (canvas != null && canvas.name != name) ...[
                  const SizedBox(height: 2),
                  Text(
                    canvas.name,
                    style: TextStyle(
                      fontSize: 12,
                      color: tint.foreground.withValues(alpha: 0.8),
                    ),
                  ),
                ],
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final tag in tags)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: tint.foreground.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            tag,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: tint.foreground,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (teachers.isNotEmpty)
                  _row(scheme, Icons.person_outline_rounded, [
                    teachers.join('、'),
                  ]),
                for (final s in sessions)
                  _row(scheme, Icons.access_time_rounded, [
                    '${_weekdays[(s.weekday - 1).clamp(0, 6)]} ${s.timeSpanFormatted}',
                    if ((s.room ?? '').isNotEmpty) s.room!,
                    if (s.weeks.isNotEmpty) '第 ${formatWeeks(s.weeks)} 周',
                  ]),
                if (sessions.isEmpty)
                  _row(scheme, Icons.event_busy_outlined, ['本学期课表中没有这门课的上课安排']),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ColorScheme scheme, IconData icon, List<String> lines) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: scheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lines.first,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                if (lines.length > 1)
                  Text(
                    lines.skip(1).join(' · '),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
