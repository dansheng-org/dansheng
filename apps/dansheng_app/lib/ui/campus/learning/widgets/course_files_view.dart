// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../learning_controller.dart';
import '../models/canvas_models.dart';
import '../cloud/drive_picker.dart';
import 'course_content_pages.dart';
import 'day_schedule_view.dart';
import 'learning_common.dart';

/// eLearning content of one course: files, modules and pages, assignments
/// and quizzes, announcements, discussions and grades.
class CourseFilesView extends StatefulWidget {
  final LearningController controller;
  final String courseId;

  const CourseFilesView({
    super.key,
    required this.controller,
    required this.courseId,
  });

  @override
  State<CourseFilesView> createState() => _CourseFilesViewState();
}

class _CourseFilesViewState extends State<CourseFilesView> {
  // 0 = 资料, 1 = 作业, 2 = 公告, 3 = 讨论, 4 = 成绩
  int _tabIndex = 0;
  final Set<String> _expandedFolderIds = {};
  final Set<String> _expandedModuleIds = {};
  bool _gradesRequested = false;

  void _toggleFolder(String folderId) {
    setState(() {
      if (_expandedFolderIds.contains(folderId)) {
        _expandedFolderIds.remove(folderId);
      } else {
        _expandedFolderIds.add(folderId);
      }
    });
  }

  void _toggleModule(CanvasModule module) {
    final ctrl = widget.controller;
    setState(() {
      if (!_expandedModuleIds.remove(module.id)) {
        _expandedModuleIds.add(module.id);
        if (ctrl.moduleItems(widget.courseId, module.id) == null) {
          ctrl.loadModuleItems(widget.courseId, module.id);
        }
      }
    });
  }

  void _selectTab(int index) {
    setState(() => _tabIndex = index);
    if (index == 4 && !_gradesRequested) {
      // Per-assignment scores come from the student's own submissions.
      _gradesRequested = true;
      widget.controller.loadSubmissions(
        widget.controller.assignments[widget.courseId] ?? const [],
      );
    }
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? cs.error : cs.inverseSurface,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final ctrl = widget.controller;
    final id = widget.courseId;

    final folders = ctrl.folders[id] ?? const <CanvasFolder>[];
    final materials = ctrl.materials[id] ?? const <CanvasMaterial>[];
    final modules = ctrl.modules[id] ?? const <CanvasModule>[];
    final pages = ctrl.pagesFor(id);
    final work = ctrl.courseWork(id);
    final announcements =
        ctrl.announcements[id] ?? const <CanvasAnnouncement>[];
    final discussions = ctrl.discussionsFor(id);
    final loading = ctrl.isCourseLoading(id);
    final detailError = ctrl.detailsError(id);

    String counted(String label, int n) => n > 0 ? '$label($n)' : label;
    final tabs = [
      '资料',
      counted('作业', work.length),
      counted('公告', announcements.length),
      counted('讨论', discussions?.length ?? 0),
      '成绩',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detailError != null)
          InfoBanner(
            message: detailError,
            actionLabel: '重试',
            onAction: () => ctrl.loadCourseDetails(id),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < tabs.length; i++)
              ChoiceChip(
                label: Text(tabs[i], style: const TextStyle(fontSize: 12)),
                selected: _tabIndex == i,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => _selectTab(i),
              ),
          ],
        ),
        const SizedBox(height: 12),
        switch (_tabIndex) {
          0 =>
            loading &&
                    folders.isEmpty &&
                    materials.isEmpty &&
                    modules.isEmpty &&
                    pages.isEmpty
                ? const SectionSpinner()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _buildSummaryBadge(
                            colorScheme,
                            icon: Icons.folder_outlined,
                            label: '${folders.length} 文件夹',
                          ),
                          _buildSummaryBadge(
                            colorScheme,
                            icon: Icons.insert_drive_file_outlined,
                            label: '${materials.length} 课件文件',
                          ),
                          if (modules.isNotEmpty)
                            _buildSummaryBadge(
                              colorScheme,
                              icon: Icons.view_module_outlined,
                              label: '${modules.length} 学习模块',
                            ),
                          if (pages.isNotEmpty)
                            _buildSummaryBadge(
                              colorScheme,
                              icon: Icons.article_outlined,
                              label: '${pages.length} 页面',
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildMaterialsAndModulesTab(
                        context,
                        colorScheme,
                        courseId: id,
                        folders: folders,
                        materials: materials,
                        modules: modules,
                        pages: pages,
                      ),
                    ],
                  ),
          1 => _buildAssignmentsTab(context, colorScheme, work, loading),
          2 => _buildAnnouncementsTab(context, colorScheme, id),
          3 => _buildDiscussionsTab(context, colorScheme, discussions, loading),
          _ => _buildGradesTab(context, colorScheme, loading),
        },
      ],
    );
  }

  Widget _buildAssignmentsTab(
    BuildContext context,
    ColorScheme colorScheme,
    List<CanvasAssignment> assignments,
    bool loading,
  ) {
    if (assignments.isEmpty) {
      return loading
          ? const SectionSpinner()
          : const EmptyHint(
              icon: Icons.assignment_turned_in_outlined,
              text: '此课程暂无作业或测验',
            );
    }
    final ctrl = widget.controller;
    // Upcoming deadlines first (soonest on top), then undated, then past.
    final now = ctrl.currentTime();
    int rank(CanvasAssignment a) =>
        a.dueAt == null ? 1 : (a.dueAt!.isBefore(now) ? 2 : 0);
    final sorted = List<CanvasAssignment>.of(assignments)
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0 || a.dueAt == null || b.dueAt == null) return byRank;
        return rank(a) == 0
            ? a.dueAt!.compareTo(b.dueAt!)
            : b.dueAt!.compareTo(a.dueAt!);
      });
    return Column(
      children: [
        for (final assignment in sorted)
          AssignmentCard(
            assignment: assignment,
            colorScheme: colorScheme,
            inCourse: true,
            submission: ctrl.submissionFor(assignment),
            statusLoading: ctrl.isSubmissionLoading(assignment),
            onTap: () => showAssignmentDetails(context, ctrl, assignment),
          ),
      ],
    );
  }

  Widget _buildDiscussionsTab(
    BuildContext context,
    ColorScheme cs,
    List<CanvasDiscussionTopic>? topics,
    bool loading,
  ) {
    final ctrl = widget.controller;
    final id = widget.courseId;
    final error = ctrl.optionalError('canvas.discussions.sync', id);
    if (topics == null || topics.isEmpty) {
      if (loading) return const SectionSpinner();
      if (error != null) {
        return InfoBanner(
          message: error,
          actionLabel: '重试',
          onAction: () => ctrl.loadCourseDetails(id),
        );
      }
      return const EmptyHint(icon: Icons.forum_outlined, text: '此课程暂无讨论');
    }
    return Column(
      children: [
        for (final topic in topics)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: cs.surfaceContainerLowest,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: topic.unread
                      ? cs.primary.withValues(alpha: 0.5)
                      : cs.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _openDiscussion(topic),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        topic.locked
                            ? Icons.lock_outline_rounded
                            : Icons.forum_rounded,
                        size: 18,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              topic.title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              [
                                '${topic.replyCount} 条回复',
                                if (topic.activityAt != null)
                                  formatCampusTime(topic.activityAt),
                              ].join(' · '),
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (topic.unread) const SoftBadge('未读'),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _openDiscussion(CanvasDiscussionTopic topic) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionScreen(
          controller: widget.controller,
          courseId: widget.courseId,
          topic: topic,
        ),
      ),
    );
  }

  void _openPage(String slug, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CanvasPageScreen(
          controller: widget.controller,
          courseId: widget.courseId,
          slug: slug,
          title: title,
        ),
      ),
    );
  }

  Widget _buildGradesTab(BuildContext context, ColorScheme cs, bool loading) {
    final ctrl = widget.controller;
    final id = widget.courseId;
    final grade = ctrl.gradeFor(id);
    final groups = ctrl.assignmentGroupsFor(id);
    final graded = [
      for (final a in ctrl.assignments[id] ?? const <CanvasAssignment>[])
        if (ctrl.submissionFor(a)?.scoreLabel != null ||
            ctrl.submissionFor(a)?.excused == true)
          a,
    ];
    final pendingScores = (ctrl.assignments[id] ?? const <CanvasAssignment>[])
        .any(ctrl.isSubmissionLoading);
    final gradeError = ctrl.optionalError('canvas.grades.self', id);

    if (loading && grade == null && groups.isEmpty && graded.isEmpty) {
      return const SectionSpinner();
    }

    String score(double? value, String? letter) {
      final parts = [
        if (value != null) formatScore(value),
        if ((letter ?? '').isNotEmpty && letter != value?.toString()) letter!,
      ];
      return parts.isEmpty ? '—' : parts.join(' · ');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (grade != null)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _gradeFigure(
                    cs,
                    '当前成绩',
                    score(grade.currentScore, grade.currentGrade),
                  ),
                ),
                Expanded(
                  child: _gradeFigure(
                    cs,
                    '最终成绩',
                    score(grade.finalScore, grade.finalGrade),
                  ),
                ),
              ],
            ),
          )
        else if (gradeError != null)
          InfoBanner(message: gradeError)
        else
          const EmptyHint(
            icon: Icons.grade_outlined,
            text: '教师尚未在 eLearning 发布课程总成绩',
          ),
        if (grade != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '成绩由 eLearning 提供，可能未包含尚未公布的部分，以教务系统为准。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        if (groups.isNotEmpty) ...[
          const SizedBox(height: 16),
          _subHeading(cs, Icons.pie_chart_outline_rounded, '成绩构成'),
          const SizedBox(height: 6),
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        g.name,
                        if ((g.dropLowest ?? 0) > 0) '去掉最低 ${g.dropLowest} 项',
                        if ((g.dropHighest ?? 0) > 0) '去掉最高 ${g.dropHighest} 项',
                      ].join(' · '),
                      style: TextStyle(fontSize: 13, color: cs.onSurface),
                    ),
                  ),
                  if (g.weight != null && g.weight! > 0)
                    Text(
                      '${formatScore(g.weight!)}%',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 16),
        _subHeading(cs, Icons.grading_rounded, '作业得分'),
        const SizedBox(height: 6),
        if (graded.isEmpty)
          pendingScores
              ? const SectionSpinner()
              : Text(
                  '暂无已评分的作业',
                  style: TextStyle(fontSize: 13, color: cs.outline),
                )
        else
          for (final a in graded)
            InkWell(
              onTap: () => showAssignmentDetails(context, ctrl, a),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        a.name,
                        style: TextStyle(fontSize: 13, color: cs.onSurface),
                      ),
                    ),
                    Text(
                      ctrl.submissionFor(a)!.excused
                          ? '已免除'
                          : [
                              ctrl.submissionFor(a)!.scoreLabel!,
                              if (a.pointsPossible != null)
                                '/ ${formatScore(a.pointsPossible!)}',
                            ].join(' '),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Widget _gradeFigure(ColorScheme cs, String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      const SizedBox(height: 2),
      Text(
        value,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: cs.onPrimaryContainer,
        ),
      ),
    ],
  );

  Widget _subHeading(ColorScheme cs, IconData icon, String text) => Row(
    children: [
      Icon(icon, size: 16, color: cs.primary),
      const SizedBox(width: 6),
      Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _buildSummaryBadge(
    ColorScheme colorScheme, {
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildMaterialsAndModulesTab(
    BuildContext context,
    ColorScheme colorScheme, {
    required String courseId,
    required List<CanvasFolder> folders,
    required List<CanvasMaterial> materials,
    required List<CanvasModule> modules,
    required List<CanvasPageSummary> pages,
  }) {
    if (folders.isEmpty &&
        materials.isEmpty &&
        modules.isEmpty &&
        pages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 28,
                color: colorScheme.outline,
              ),
              const SizedBox(height: 6),
              Text(
                '此课程暂无文件或资料',
                style: TextStyle(fontSize: 13, color: colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    // Build hierarchy preserving exact IDs (without flattening)
    final folderMap = {for (var f in folders) f.id: f};
    final rootFolders = folders.where((f) {
      return f.parentFolderId == null ||
          !folderMap.containsKey(f.parentFolderId);
    }).toList();

    final rootMaterials = materials.where((m) {
      return m.folderId == null || !folderMap.containsKey(m.folderId);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (modules.isNotEmpty) ...[
          _subHeading(colorScheme, Icons.view_module_rounded, '教学模块'),
          const SizedBox(height: 6),
          ...modules.map((mod) => _buildModuleCard(context, colorScheme, mod)),
          const Divider(height: 20),
        ],
        if (pages.isNotEmpty) ...[
          _subHeading(colorScheme, Icons.article_rounded, '课程页面'),
          const SizedBox(height: 6),
          for (final page in pages)
            _contentRow(
              colorScheme,
              icon: page.frontPage
                  ? Icons.home_rounded
                  : Icons.article_outlined,
              title: page.title,
              subtitle: page.frontPage
                  ? '课程首页'
                  : (page.updatedAt == null
                        ? null
                        : '更新于 ${formatCampusTime(page.updatedAt)}'),
              locked: page.lockedForUser,
              onTap: () => _openPage(page.slug, page.title),
            ),
          const Divider(height: 20),
        ],
        if (folders.isNotEmpty || materials.isNotEmpty) ...[
          _subHeading(colorScheme, Icons.folder_copy_rounded, '课件目录'),
          const SizedBox(height: 8),
          ...rootMaterials.map(
            (m) => _buildFileRow(
              context,
              colorScheme,
              courseId: courseId,
              material: m,
              indent: 0,
            ),
          ),
          ...rootFolders.map(
            (f) => _buildFolderTree(
              context,
              colorScheme,
              courseId: courseId,
              folder: f,
              allFolders: folders,
              allMaterials: materials,
              level: 0,
            ),
          ),
        ],
      ],
    );
  }

  Widget _contentRow(
    ColorScheme cs, {
    required IconData icon,
    required String title,
    String? subtitle,
    bool locked = false,
    double indent = 0,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: EdgeInsets.only(left: indent, bottom: 4),
      child: Material(
        color: cs.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: locked ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 18, color: locked ? cs.outline : cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: locked ? cs.outline : cs.onSurface,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (locked)
                  Icon(Icons.lock_outline_rounded, size: 16, color: cs.outline)
                else if (onTap != null)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: cs.outline,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModuleCard(
    BuildContext context,
    ColorScheme colorScheme,
    CanvasModule module,
  ) {
    final ctrl = widget.controller;
    final expanded = _expandedModuleIds.contains(module.id);
    final items = ctrl.moduleItems(widget.courseId, module.id);
    final busy = ctrl.isModuleLoading(widget.courseId, module.id);
    final error = ctrl.optionalError(
      'canvas.module_items.sync',
      '${widget.courseId}:${module.id}',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _toggleModule(module),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.book_outlined,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      module.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (module.itemsCount > 0)
                    Text(
                      '${module.itemsCount} 项内容',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 6),
            child: items == null
                ? (busy
                      ? const SectionSpinner()
                      : InfoBanner(
                          message: error ?? '模块内容暂时无法加载',
                          actionLabel: '重试',
                          onAction: () =>
                              ctrl.loadModuleItems(widget.courseId, module.id),
                        ))
                : items.isEmpty
                ? Text(
                    '模块为空',
                    style: TextStyle(fontSize: 12, color: colorScheme.outline),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in items)
                        _buildModuleItem(colorScheme, item),
                    ],
                  ),
          ),
      ],
    );
  }

  Widget _buildModuleItem(ColorScheme cs, CanvasModuleItem item) {
    final indent = item.indent.clamp(0, 4) * 14.0;
    if (item.type == 'SubHeader') {
      return Padding(
        padding: EdgeInsets.only(left: indent, top: 6, bottom: 4),
        child: Text(
          item.title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: cs.onSurfaceVariant,
          ),
        ),
      );
    }
    final (icon, label) = switch (item.type) {
      'File' => (Icons.insert_drive_file_outlined, '文件'),
      'Page' => (Icons.article_outlined, '页面'),
      'Assignment' => (Icons.assignment_outlined, '作业'),
      'Quiz' => (Icons.quiz_outlined, '测验'),
      'Discussion' => (Icons.forum_outlined, '讨论'),
      'ExternalUrl' || 'ExternalTool' => (Icons.link_rounded, '外部链接'),
      _ => (Icons.description_outlined, null),
    };
    final downloading =
        item.type == 'File' &&
        widget.controller.downloadingFileIds.contains(item.contentId);
    return _contentRow(
      cs,
      icon: downloading ? Icons.downloading_rounded : icon,
      title: item.title.isEmpty ? (label ?? '内容') : item.title,
      subtitle: label,
      indent: indent,
      onTap: () => _openModuleItem(item),
    );
  }

  void _openModuleItem(CanvasModuleItem item) {
    final ctrl = widget.controller;
    final courseId = widget.courseId;
    final contentId = item.contentId;
    switch (item.type) {
      case 'File' when contentId != null:
        ctrl.downloadAndOpenFile(
          courseId: courseId,
          fileId: contentId,
          fileName: item.title,
          showFeedback: (msg, {isError = false}) => _snack(msg, error: isError),
        );
      case 'Page' when (item.pageSlug ?? '').isNotEmpty:
        _openPage(item.pageSlug!, item.title);
      case 'Assignment' when contentId != null:
        final match = ctrl
            .courseWork(courseId)
            .where((a) => !a.isQuiz && a.id == contentId);
        if (match.isEmpty) {
          _snack('这项作业暂未开放或已隐藏');
        } else {
          showAssignmentDetails(context, ctrl, match.first);
        }
      case 'Quiz' when contentId != null:
        final match = ctrl
            .courseWork(courseId)
            .where((a) => a.isQuiz && a.id == contentId);
        showAssignmentDetails(
          context,
          ctrl,
          match.firstOrNull ??
              CanvasAssignment(
                id: contentId,
                courseId: courseId,
                name: item.title,
                isQuiz: true,
              ),
        );
      case 'Discussion' when contentId != null:
        _openDiscussion(
          ctrl
                  .discussionsFor(courseId)
                  ?.where((t) => t.id == contentId)
                  .firstOrNull ??
              CanvasDiscussionTopic(id: contentId, title: item.title),
        );
      case 'ExternalUrl' || 'ExternalTool'
          when (item.externalUrl ?? '').isNotEmpty:
        _showLink(item.title, item.externalUrl!);
      default:
        _snack('请在 eLearning 网页中查看此内容');
    }
  }

  /// External links are shown for copying rather than opened directly.
  void _showLink(String title, String url) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title.isEmpty ? '外部链接' : title),
        content: SelectableText(url),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              Navigator.of(ctx).pop();
              _snack('链接已复制');
            },
            child: const Text('复制链接'),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderTree(
    BuildContext context,
    ColorScheme colorScheme, {
    required String courseId,
    required CanvasFolder folder,
    required List<CanvasFolder> allFolders,
    required List<CanvasMaterial> allMaterials,
    required int level,
  }) {
    final isExpanded = _expandedFolderIds.contains(folder.id);
    final childFolders = allFolders
        .where((f) => f.parentFolderId == folder.id)
        .toList();
    final childMaterials = allMaterials
        .where((m) => m.folderId == folder.id)
        .toList();
    final totalItems = childFolders.length + childMaterials.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => _toggleFolder(folder.id),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.only(
              left: level * 16.0 + 4,
              top: 6,
              bottom: 6,
              right: 8,
            ),
            child: Row(
              children: [
                Icon(
                  isExpanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    folder.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                if (totalItems > 0)
                  Text(
                    '$totalItems 项',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded) ...[
          // Sub-folders
          ...childFolders.map(
            (sub) => _buildFolderTree(
              context,
              colorScheme,
              courseId: courseId,
              folder: sub,
              allFolders: allFolders,
              allMaterials: allMaterials,
              level: level + 1,
            ),
          ),
          // Sub-files
          ...childMaterials.map(
            (m) => _buildFileRow(
              context,
              colorScheme,
              courseId: courseId,
              material: m,
              indent: level + 1,
            ),
          ),
          if (totalItems == 0)
            Padding(
              padding: EdgeInsets.only(
                left: (level + 1) * 16.0 + 12,
                top: 4,
                bottom: 4,
              ),
              child: Text(
                '文件夹为空',
                style: TextStyle(fontSize: 12, color: colorScheme.outline),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildFileRow(
    BuildContext context,
    ColorScheme colorScheme, {
    required String courseId,
    required CanvasMaterial material,
    required int indent,
  }) {
    final isDownloading = widget.controller.downloadingFileIds.contains(
      material.id,
    );
    final isDownloaded = widget.controller.downloadedFileIds.contains(
      material.id,
    );

    return Padding(
      padding: EdgeInsets.only(
        left: indent * 16.0 + 8,
        top: 4,
        bottom: 4,
        right: 4,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            _getFileIcon(material.filename, colorScheme),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    material.displayName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (material.sizeFormatted.isNotEmpty)
                    Text(
                      material.sizeFormatted,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (!isDownloading)
              IconButton(
                icon: Icon(
                  Icons.cloud_upload_outlined,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                tooltip: '存到云盘',
                visualDensity: VisualDensity.compact,
                onPressed: () => saveAssetToDrive(
                  context,
                  widget.controller.api,
                  name: material.displayName,
                  assetId: () async {
                    final result = await widget.controller.api.call(
                      'canvas.material.download',
                      {
                        'course_id': material.courseId ?? courseId,
                        'file_id': material.id,
                      },
                    );
                    final id = result is Map
                        ? result['asset_id']?.toString()
                        : null;
                    if (id == null) throw StateError('FileUnavailable');
                    return id;
                  },
                ),
              ),
            if (isDownloading)
              const SizedBox(
                width: 28,
                height: 28,
                child: Padding(
                  padding: EdgeInsets.all(4.0),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                icon: Icon(
                  isDownloaded
                      ? Icons.open_in_new_rounded
                      : Icons.download_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                tooltip: isDownloaded ? '打开文件' : '下载并打开',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  widget.controller.downloadAndOpenFile(
                    courseId: material.courseId ?? courseId,
                    fileId: material.id,
                    fileName: material.displayName,
                    showFeedback: (msg, {isError = false}) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          backgroundColor: isError
                              ? colorScheme.error
                              : colorScheme.inverseSurface,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _getFileIcon(String filename, ColorScheme colorScheme) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return const Icon(
        Icons.picture_as_pdf_rounded,
        size: 22,
        color: Colors.redAccent,
      );
    }
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) {
      return const Icon(
        Icons.description_rounded,
        size: 22,
        color: Colors.blueAccent,
      );
    }
    if (lower.endsWith('.ppt') || lower.endsWith('.pptx')) {
      return const Icon(
        Icons.slideshow_rounded,
        size: 22,
        color: Colors.orangeAccent,
      );
    }
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx')) {
      return const Icon(
        Icons.table_chart_rounded,
        size: 22,
        color: Colors.green,
      );
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.rar') ||
        lower.endsWith('.7z')) {
      return const Icon(
        Icons.folder_zip_rounded,
        size: 22,
        color: Colors.amber,
      );
    }
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg')) {
      return const Icon(Icons.image_rounded, size: 22, color: Colors.teal);
    }
    return Icon(
      Icons.insert_drive_file_rounded,
      size: 22,
      color: colorScheme.onSurfaceVariant,
    );
  }

  Widget _buildAnnouncementsTab(
    BuildContext context,
    ColorScheme colorScheme,
    String courseId,
  ) {
    final announcements = widget.controller.announcements[courseId] ?? [];

    if (announcements.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.campaign_outlined,
                size: 28,
                color: colorScheme.outline,
              ),
              const SizedBox(height: 6),
              Text(
                '暂无课程公告',
                style: TextStyle(fontSize: 13, color: colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: announcements.map((ann) {
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.campaign_rounded,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ann.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (ann.postedAtFormatted.isNotEmpty)
                    Text(
                      ann.postedAtFormatted,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (ann.message != null && ann.message!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _cleanMessage(ann.message!),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }

  String _cleanMessage(String raw) {
    return raw.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }
}
