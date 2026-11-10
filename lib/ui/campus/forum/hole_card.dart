// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import 'forum_format.dart';
import 'forum_models.dart';

/// Clean Material card representing a Hole thread in the forum list.
class TeaHoleCard extends StatelessWidget {
  final TeaHole hole;
  final String? divisionName;
  final bool isPinned;
  final VoidCallback? onTap;

  const TeaHoleCard({
    super.key,
    required this.hole,
    this.divisionName,
    this.isPinned = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final firstFloor = hole.floors?.firstFloor;
    final isDeleted = firstFloor?.deleted ?? false;
    final rawContent = firstFloor?.content;
    final preview = isDeleted
        ? '该楼层已被删除'
        : (cleanPreviewText(rawContent).isNotEmpty
              ? cleanPreviewText(rawContent)
              : '（暂无正文）');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isPinned
              ? colorScheme.primary.withAlpha(120)
              : colorScheme.outlineVariant.withAlpha(100),
          width: isPinned ? 1.5 : 1,
        ),
      ),
      color: isPinned
          ? colorScheme.primaryContainer.withAlpha(40)
          : colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: #holeId, division, isPinned, time
              Row(
                children: [
                  if (isPinned) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '置顶',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    '#${hole.holeId}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                  if (divisionName != null && divisionName!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        divisionName!,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    formatFriendlyTime(hole.timeCreated),
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // First floor text preview
              Text(
                preview,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: isDeleted
                      ? colorScheme.outline
                      : colorScheme.onSurface,
                  fontStyle: isDeleted ? FontStyle.italic : FontStyle.normal,
                ),
              ),

              // Tags
              if (hole.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: hole.tags.map((tag) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '#$tag',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.primary,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],

              const SizedBox(height: 10),

              // Bottom row: Reply count, View count
              Row(
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${hole.reply}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (hole.view > 0) ...[
                    const SizedBox(width: 16),
                    Icon(
                      Icons.visibility_outlined,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${hole.view}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (hole.locked) ...[
                    const SizedBox(width: 16),
                    Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: colorScheme.error,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '已锁定',
                      style: TextStyle(fontSize: 11, color: colorScheme.error),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
