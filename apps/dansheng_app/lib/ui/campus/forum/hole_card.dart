// SPDX-License-Identifier: GPL-3.0-or-later
// Layout adapted from DanXi lib/widget/forum/forum_widgets.dart (OTHoleWidget).
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'package:flutter/material.dart';

import 'forum_format.dart';
import 'forum_models.dart';

/// DanXi-style first-floor preview, latest reply and thread metadata.
class TeaHoleCard extends StatefulWidget {
  final TeaHole hole;
  final String? divisionName;
  final bool isPinned;
  final VoidCallback? onTap;
  final VoidCallback? onTapLatestReply;

  const TeaHoleCard({
    super.key,
    required this.hole,
    this.divisionName,
    this.isPinned = false,
    this.onTap,
    this.onTapLatestReply,
  });

  @override
  State<TeaHoleCard> createState() => _TeaHoleCardState();
}

class _TeaHoleCardState extends State<TeaHoleCard> {
  bool _expanded = false;

  @override
  void didUpdateWidget(TeaHoleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hole.holeId != widget.hole.holeId ||
        oldWidget.hole.tags.any(isHiddenForumTag) !=
            widget.hole.tags.any(isHiddenForumTag)) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hole = widget.hole;
    final colors = Theme.of(context).colorScheme;
    final first = hole.floors?.firstFloor;
    final last = hole.floors?.lastFloor;
    final folded = hole.tags.any(isHiddenForumTag);
    final showContent = !folded || _expanded;
    final infoStyle = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final labels = [
      if (widget.divisionName?.isNotEmpty == true) widget.divisionName!,
      ...hole.tags.where(isVisibleForumTag).map((tag) => '#$tag'),
      if (widget.isPinned) '置顶',
      if (hole.hidden) '已隐藏',
      if (hole.timeDeleted != null) '已删除',
      if (hole.locked) '已锁定',
      if (hole.frozen) '已冻结',
      if (first?.specialTag?.isNotEmpty == true) first!.specialTag!,
    ];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (labels.isNotEmpty) ...[
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final label in labels)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSecondaryContainer,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              if (folded)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  label: Text(_expanded ? '收起折叠帖子' : '帖子已折叠，点击展开'),
                ),
              if (showContent) ...[
                _FloorPreview(
                  key: ValueKey(('first', first?.floorId)),
                  floor: first,
                  fontSize: 16,
                  maxLines: 6,
                ),
                if (last != null && last.floorId != first?.floorId)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: InkWell(
                      onTap: widget.onTapLatestReply ?? widget.onTap,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(color: colors.outline, width: 2),
                          ),
                        ),
                        padding: const EdgeInsets.only(left: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '最新回复 · ${last.anonyname?.trim().isNotEmpty == true ? last.anonyname!.trim() : '热心同学'} · ${formatFriendlyTime(last.timeCreated)}',
                              style: TextStyle(
                                fontSize: 14,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            _FloorPreview(
                              key: ValueKey(('last', last.floorId)),
                              floor: last,
                              fontSize: 14,
                              maxLines: 1,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              DefaultTextStyle(
                style: infoStyle,
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 16,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('#${hole.holeId}'),
                      Text(formatFriendlyTime(hole.timeCreated)),
                      Text('${hole.reply} 回复'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloorPreview extends StatefulWidget {
  const _FloorPreview({
    super.key,
    this.floor,
    required this.fontSize,
    required this.maxLines,
  });

  final TeaFloor? floor;
  final double fontSize;
  final int maxLines;

  @override
  State<_FloorPreview> createState() => _FloorPreviewState();
}

class _FloorPreviewState extends State<_FloorPreview> {
  bool _expanded = false;

  @override
  void didUpdateWidget(_FloorPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.floor?.content != widget.floor?.content ||
        oldWidget.floor?.deleted != widget.floor?.deleted ||
        oldWidget.floor?.fold.join('\n') != widget.floor?.fold.join('\n')) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final floor = widget.floor;
    final deleted = floor?.deleted == true;
    final folded = !deleted && floor?.fold.isNotEmpty == true;
    final colors = Theme.of(context).colorScheme;
    final preview = deleted ? '该楼层已被删除' : cleanPreviewText(floor?.content);
    final text = Text(
      preview.isEmpty ? '（暂无正文）' : preview,
      maxLines: widget.maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: widget.fontSize,
        height: 1.4,
        color: deleted ? colors.onSurfaceVariant : null,
      ),
    );
    if (!folded) return text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            alignment: Alignment.centerLeft,
          ),
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          label: Text(
            '${_expanded ? '收起折叠内容' : '内容已折叠，点击展开'}：${floor!.fold.join('、')}',
          ),
        ),
        if (_expanded) text,
      ],
    );
  }
}
