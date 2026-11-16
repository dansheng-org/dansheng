// SPDX-License-Identifier: GPL-3.0-or-later
// Layout adapted from DanXi lib/widget/forum/forum_widgets.dart (OTHoleWidget).
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'package:flutter/material.dart';

import 'forum_chips.dart';
import 'forum_filter_settings.dart';
import 'forum_format.dart';
import 'forum_models.dart';

/// DanXi-style first-floor preview, latest reply and thread metadata.
class TeaHoleCard extends StatefulWidget {
  final TeaHole hole;
  final String? divisionName;
  final bool isPinned;
  final VoidCallback? onTap;
  final VoidCallback? onTapLatestReply;
  final ValueChanged<String>? onTapTag;

  const TeaHoleCard({
    super.key,
    required this.hole,
    this.divisionName,
    this.isPinned = false,
    this.onTap,
    this.onTapLatestReply,
    this.onTapTag,
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

  void _showContextMenu(BuildContext context) {
    final prefs = ForumPreferences.instance;
    final hole = widget.hole;

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text('屏蔽此贴 (#${hole.holeId})'),
              subtitle: const Text('屏蔽后该帖子将不再在列表中显示'),
              onTap: () {
                prefs.hideHole(hole.holeId);
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已屏蔽帖子 #${hole.holeId}')),
                );
              },
            ),
            for (final tag in hole.tags.where(isVisibleForumTag))
              ListTile(
                leading: const Icon(Icons.label_off_outlined),
                title: Text('屏蔽标签 #$tag'),
                onTap: () {
                  prefs.addHiddenTag(tag);
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已屏蔽标签 #$tag')),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hole = widget.hole;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final first = hole.floors?.firstFloor;
    final last = hole.floors?.lastFloor;

    final hasStarTag = hole.tags.any(isHiddenForumTag);
    final showContent = !hasStarTag || _expanded;
    final infoStyle = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);

    // Tags
    final visibleTags = hole.tags.where(isVisibleForumTag).toList();

    // Badges matching DanXi
    final badges = <Widget>[
      if (widget.divisionName?.isNotEmpty == true)
        LeadingChip(
          label: widget.divisionName!,
          color: colors.primary,
        ),
      if (widget.isPinned)
        LeadingChip(
          label: '置顶',
          color: colors.primary,
        ),
      if (hole.hidden)
        const LeadingChip(
          label: '已隐藏',
          color: Colors.red,
        ),
      if (hole.timeDeleted != null)
        const LeadingChip(
          label: '已删除',
          color: Colors.red,
        ),
      if (hole.locked)
        LeadingChip(
          label: '已锁定',
          color: colors.primary,
        ),
      if (hole.frozen)
        LeadingChip(
          label: '已冻结',
          color: colors.primary,
        ),
      if (first?.specialTag?.isNotEmpty == true)
        LeadingChip(
          label: first!.specialTag!,
          color: Colors.red,
        ),
    ];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: () => _showContextMenu(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header tags and status chips
              if (visibleTags.isNotEmpty || badges.isNotEmpty) ...[
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final badge in badges) badge,
                    for (final tag in visibleTags)
                      RectangularChip(
                        label: tag,
                        onTap: widget.onTapTag == null
                            ? null
                            : () => widget.onTapTag!(tag),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],

              // Fold toggle button
              if (hasStarTag)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  label: Text(_expanded ? '收起折叠帖子' : '帖子已折叠，点击展开'),
                ),

              // Content preview
              if (showContent) ...[
                _FloorPreview(
                  key: ValueKey(('first', first?.floorId)),
                  floor: first,
                  fontSize: 16,
                  maxLines: 6,
                ),

                // DanXi-style latest reply preview with left accent border
                if (last != null && last.floorId != first?.floorId)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: InkWell(
                      onTap: widget.onTapLatestReply ?? widget.onTap,
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: colors.outline.withValues(alpha: 0.6),
                              width: 2,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.only(left: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '最新回复 · ${last.anonyname?.trim().isNotEmpty == true ? last.anonyname!.trim() : '热心同学'} · ${formatFriendlyTime(last.timeCreated)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
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

              // DanXi-style bottom info row: #ID, friendly time, reply count with icon
              DefaultTextStyle(
                style: infoStyle,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('#${hole.holeId}'),
                    Text(formatFriendlyTime(hole.timeCreated)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${hole.reply} 回复'),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.sms_outlined,
                          size: 14,
                          color: colors.onSurfaceVariant,
                        ),
                        if (hole.view > 0) ...[
                          const SizedBox(width: 8),
                          Text('${hole.view} 浏览'),
                        ],
                      ],
                    ),
                  ],
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
    final prefs = ForumPreferences.instance;

    final cleaned = prefs.filterContent(cleanPreviewText(floor?.content));
    final preview = deleted ? '该楼层已被删除' : cleaned;
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
