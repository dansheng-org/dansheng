// SPDX-License-Identifier: GPL-3.0-or-later
// Review and course cards adapted from DanXi lib/widget/danke
// (course_review_widget.dart, course_widgets.dart, random_review_widgets.dart).
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'package:flutter/material.dart';

import '../forum_content.dart';
import 'danke_models.dart';

/// DanXi `wordColor`, worst to best.
const dankeWordColors = <Color>[
  Colors.red,
  Colors.orange,
  Colors.yellow,
  Colors.lightGreen,
  Colors.green,
];

/// DanXi's rating words (zh_CN), each from grade 1 to 5.
const dankeOverallWords = ['特别差评', '差评', '中等', '好评', '特别好评'];
const dankeContentWords = ['硬核', '较难', '中等', '容易', '非常容易'];
const dankeWorkloadWords = ['非常大', '较大', '中等', '较小', '非常小'];
const dankeAssessmentWords = ['非常严格', '严格', '中等', '宽松', '非常宽松'];

/// A 1–5 grade as DanXi's word and colour, or "未知".
Widget dankeGrade(List<String> words, int? grade, {double fontSize = 12}) {
  final i = (grade ?? 0) - 1;
  if (i < 0 || i >= words.length) {
    return Text(
      '未知',
      style: TextStyle(color: Colors.grey, fontSize: fontSize),
    );
  }
  return Text(
    words[i],
    style: TextStyle(color: dankeWordColors[i], fontSize: fontSize),
  );
}

class DankeChip extends StatelessWidget {
  const DankeChip({super.key, required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 12)),
  );
}

/// DanXi `CourseGroupCardWidget`: one course in the search results.
class DankeGroupCard extends StatelessWidget {
  const DankeGroupCard({super.key, required this.group, this.onTap});
  final DankeCourseGroup group;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final info = TextStyle(color: Theme.of(context).hintColor, fontSize: 12);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 13, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.fullName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          group.code,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Wrap(
                    direction: Axis.vertical,
                    spacing: 5,
                    children: [
                      for (final c in group.credits)
                        DankeChip(
                          label: '${c.toStringAsFixed(1)} 学分',
                          color: Colors.orange,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 5, thickness: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 3, 13, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Row(
                    children: [
                      Icon(Icons.file_copy, size: 12, color: info.color),
                      const SizedBox(width: 3),
                      Text('${group.courseCount ?? '-'}', style: info),
                    ],
                  ),
                  Row(
                    children: [
                      Icon(Icons.comment, size: 12, color: info.color),
                      const SizedBox(width: 3),
                      Text('${group.reviewCount ?? '-'}', style: info),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// DanXi `RandomReviewWidgets`: the review shown on the home page.
class DankeRandomCard extends StatelessWidget {
  const DankeRandomCard({super.key, required this.review, this.onTap});
  final DankeReview review;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final course = review.course;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (course != null) ...[
                Text(course.code, style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 4),
                Text(
                  '${course.department} / ${course.name}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (course?.credit != null)
                    DankeChip(
                      label: '${course!.credit!.toStringAsFixed(1)} 学分',
                      color: Colors.orange,
                    )
                  else
                    const SizedBox.shrink(),
                  Row(
                    children: [
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 12,
                        color: Theme.of(context).hintColor,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${review.remark}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.sms_outlined, color: Theme.of(context).hintColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      review.content,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// DanXi `CourseReviewWidget` (read-only): votes, header, text and grades.
class DankeReviewCard extends StatelessWidget {
  const DankeReviewCard({
    super.key,
    required this.review,
    this.highlight = false,
  });
  final DankeReview review;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final course = review.course;
    const label = TextStyle(color: Colors.grey, fontSize: 12);
    Widget grade(String title, List<String> words, int? value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: label),
        const SizedBox(width: 6),
        dankeGrade(words, value),
      ],
    );
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        side: highlight
            ? BorderSide(color: colors.primary, width: 2)
            : BorderSide.none,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // DanXi's vote column, shown as the count (voting needs sign-in writes).
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                children: [
                  Icon(
                    Icons.thumb_up_outlined,
                    size: 16,
                    color: Theme.of(context).hintColor,
                  ),
                  const SizedBox(height: 2),
                  Text('${review.remark}', style: label),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const ColoredBox(
                        color: Colors.deepOrange,
                        child: SizedBox(width: 2, height: 12),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'User ${review.reviewerId ?? '-'}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  if (course != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Wrap(
                        spacing: 3,
                        runSpacing: 2,
                        children: [
                          DankeChip(
                            label: course.teachers,
                            color: Colors.deepPurpleAccent,
                          ),
                          DankeChip(label: course.time, color: Colors.green),
                        ],
                      ),
                    ),
                  Text(
                    review.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const Divider(),
                  ForumContent(content: review.content, selectable: false),
                  const Divider(),
                  Wrap(
                    spacing: 20,
                    runSpacing: 6,
                    children: [
                      grade('总体评价', dankeOverallWords, review.rank.overall),
                      grade('课程风格', dankeContentWords, review.rank.content),
                      grade('工作量', dankeWorkloadWords, review.rank.workload),
                      grade(
                        '考核要求',
                        dankeAssessmentWords,
                        review.rank.assessment,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
