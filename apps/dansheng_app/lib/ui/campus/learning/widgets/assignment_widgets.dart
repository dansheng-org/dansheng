// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../campus_account_boundary.dart';

import '../learning_controller.dart';
import '../models/canvas_models.dart';

/// Colours of a submission status chip.
({Color fg, Color bg}) _statusColors(
  ColorScheme scheme,
  CanvasAssignment assignment,
  CanvasSubmission? submission,
) {
  final dark = scheme.brightness == Brightness.dark;
  MaterialColor tone;
  if (submission == null) {
    tone = assignment.isQuiz ? Colors.indigo : Colors.amber;
  } else if (submission.excused || submission.isDone && !submission.late) {
    tone = Colors.green;
  } else if (submission.late) {
    tone = Colors.orange;
  } else if (submission.missing) {
    tone = Colors.red;
  } else {
    tone = Colors.amber;
  }
  return (
    fg: dark ? tone.shade300 : tone.shade900,
    bg: tone.withValues(alpha: dark ? 0.18 : 0.14),
  );
}

/// One assignment or quiz row; used by the day schedule and a course page.
class AssignmentCard extends StatelessWidget {
  final CanvasAssignment assignment;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  /// The student's own submission; null while unknown.
  final CanvasSubmission? submission;
  final bool statusLoading;

  /// Show the due date as well as the time, and drop the course name.
  final bool inCourse;

  /// Show the due date as well as the time, keeping the course name.
  final bool showDate;

  const AssignmentCard({
    super.key,
    required this.assignment,
    required this.colorScheme,
    required this.onTap,
    this.submission,
    this.statusLoading = false,
    this.inCourse = false,
    this.showDate = false,
  });

  @override
  Widget build(BuildContext context) {
    final done = submission?.isDone == true;
    final dark = colorScheme.brightness == Brightness.dark;
    final amber = dark ? Colors.amber.shade300 : Colors.amber.shade900;
    final courseName = assignment.courseName ?? '';
    final colors = _statusColors(colorScheme, assignment, submission);
    final status = submission?.statusLabel ?? (assignment.isQuiz ? '测验' : null);
    // "9" for points, otherwise a posted letter grade.
    final raw = submission?.score;
    final score = raw != null
        ? formatScore(raw)
        : ((submission?.grade ?? '').isEmpty ? null : submission!.grade);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: done
                ? colorScheme.outlineVariant.withValues(alpha: 0.4)
                : Colors.amber.shade300.withValues(alpha: dark ? 0.5 : 1),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  done
                      ? Icons.check_circle_rounded
                      : assignment.isQuiz
                      ? Icons.quiz_outlined
                      : Icons.pending_actions_rounded,
                  size: 20,
                  color: done ? Colors.green.shade600 : Colors.amber.shade700,
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
                      Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        children: [
                          if (!inCourse && courseName.isNotEmpty)
                            Text(
                              courseName,
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          Text(
                            inCourse || showDate
                                ? (assignment.dueAt == null
                                      ? '无截止时间'
                                      : '${assignment.fullDueFormatted} 截止')
                                : assignment.dueTimeFormatted,
                            style: TextStyle(
                              fontSize: 12,
                              color: amber,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (score != null)
                            Text(
                              assignment.pointsPossible == null
                                  ? '得分 $score'
                                  : '得分 $score / ${formatScore(assignment.pointsPossible!)}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: colorScheme.primary,
                              ),
                            )
                          else if (assignment.pointsPossible != null)
                            Text(
                              '${formatScore(assignment.pointsPossible!)}分',
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (status != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colors.bg,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      status,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: colors.fg,
                      ),
                    ),
                  )
                else if (statusLoading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet with the full details of one assignment or quiz, including
/// the student's own submission, score and teacher comments.
void showAssignmentDetails(
  BuildContext context,
  LearningController controller,
  CanvasAssignment assignment,
) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => CampusAccountBoundary(
      api: controller.api,
      child: _AssignmentSheet(controller: controller, assignment: assignment),
    ),
  );
}

class _AssignmentSheet extends StatefulWidget {
  final LearningController controller;
  final CanvasAssignment assignment;
  const _AssignmentSheet({required this.controller, required this.assignment});

  @override
  State<_AssignmentSheet> createState() => _AssignmentSheetState();
}

class _AssignmentSheetState extends State<_AssignmentSheet> {
  late CanvasAssignment _assignment = widget.assignment;

  @override
  void initState() {
    super.initState();
    if (_assignment.isQuiz) {
      widget.controller
          .readQuiz(_assignment)
          .then((fresh) {
            if (mounted) setState(() => _assignment = fresh);
          })
          .catchError((Object _) {});
    } else {
      // Always refresh: the student may have just handed it in.
      widget.controller.loadSubmissions([_assignment], refresh: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final a = _assignment;
    final ctrl = widget.controller;
    final submission = ctrl.submissionFor(a);
    final loading = ctrl.isSubmissionLoading(a);
    final description = plainText(a.description);
    final colors = _statusColors(cs, a, submission);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              a.name,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: cs.onSurface,
              ),
            ),
            if (a.courseName != null)
              Text(
                a.courseName!,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            const Divider(height: 24),
            _detailItem(
              context,
              Icons.schedule_rounded,
              '截止时间',
              a.fullDueFormatted,
            ),
            if (a.pointsPossible != null)
              _detailItem(
                context,
                Icons.score_rounded,
                '满分分值',
                '${formatScore(a.pointsPossible!)} 分',
              ),
            if (a.isQuiz) ...[
              _detailItem(context, Icons.quiz_outlined, '类型', '测验'),
              if (a.timeLimitMinutes != null)
                _detailItem(
                  context,
                  Icons.timer_outlined,
                  '限时',
                  '${a.timeLimitMinutes} 分钟',
                ),
              if (a.questionCount != null)
                _detailItem(
                  context,
                  Icons.format_list_numbered_rounded,
                  '题目数',
                  '${a.questionCount} 题',
                ),
              if (a.allowedAttempts != null)
                _detailItem(
                  context,
                  Icons.replay_rounded,
                  '作答次数',
                  a.allowedAttempts! < 0 ? '不限' : '${a.allowedAttempts} 次',
                ),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      submission?.isDone == true
                          ? Icons.check_circle_rounded
                          : Icons.pending_rounded,
                      size: 16,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 70,
                      child: Text(
                        '提交状态',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (submission != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.bg,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          submission.statusLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: colors.fg,
                          ),
                        ),
                      )
                    else if (loading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    else
                      Text(
                        '暂时无法获取',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            if (submission?.submittedAt != null)
              _detailItem(
                context,
                Icons.upload_rounded,
                '提交时间',
                [
                  formatCampusTime(submission!.submittedAt),
                  if ((submission.attempt ?? 0) > 1)
                    '第 ${submission.attempt} 次提交',
                ].join(' · '),
              ),
            if (submission?.scoreLabel != null)
              _detailItem(
                context,
                Icons.grading_rounded,
                '得分',
                submission!.scoreLabel!,
              ),
            if (submission != null && submission.attachmentNames.isNotEmpty)
              _detailItem(
                context,
                Icons.attach_file_rounded,
                '提交附件',
                submission.attachmentNames.join('\n'),
              ),
            if (submission != null && submission.comments.isNotEmpty) ...[
              const SizedBox(height: 12),
              _heading(cs, '教师评语'),
              for (final c in submission.comments)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          c.authorName ?? '教师',
                          if (c.createdAt != null)
                            formatCampusTime(c.createdAt),
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        c.text,
                        style: TextStyle(fontSize: 13, color: cs.onSurface),
                      ),
                    ],
                  ),
                ),
            ],
            if (description.isNotEmpty) ...[
              const SizedBox(height: 12),
              _heading(cs, a.isQuiz ? '测验说明' : '作业要求说明'),
              const SizedBox(height: 4),
              SelectableText(
                description,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _heading(ColorScheme cs, String text) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.bold,
      color: cs.onSurface,
    ),
  );
}

Widget _detailItem(
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
