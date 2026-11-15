// SPDX-License-Identifier: GPL-3.0-or-later
// Layout adapted from DanXi lib/widget/forum/forum_widgets.dart (OTFloorWidget)
// and lib/page/forum/hole_detail.dart. Copyright (C) 2021 DanXi-Dev.
import 'package:flutter/material.dart';

import 'forum_content.dart';
import 'forum_format.dart';
import 'forum_models.dart';

/// Shared floor layout for thread details and search results.
/// [index] is the zero-based position across all loaded pages, never a floor ID.
class ForumFloorTile extends StatefulWidget {
  const ForumFloorTile({
    super.key,
    required this.floor,
    this.firstFloor,
    this.index,
    this.showHoleId = false,
    this.tags = const [],
    this.onTap,
    this.onTapHole,
    this.onTapFloor,
  });

  final TeaFloor floor;
  final TeaFloor? firstFloor;
  final int? index;
  final bool showHoleId;
  final List<String> tags;
  final VoidCallback? onTap;
  final ValueChanged<int>? onTapHole;
  final ValueChanged<int>? onTapFloor;

  @override
  State<ForumFloorTile> createState() => _ForumFloorTileState();
}

class _ForumFloorTileState extends State<ForumFloorTile> {
  bool _expanded = false;

  @override
  void didUpdateWidget(ForumFloorTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.floor.floorId != widget.floor.floorId ||
        oldWidget.floor.content != widget.floor.content ||
        oldWidget.floor.deleted != widget.floor.deleted ||
        oldWidget.tags.any(isHiddenForumTag) !=
            widget.tags.any(isHiddenForumTag) ||
        oldWidget.floor.fold.join('\n') != widget.floor.fold.join('\n')) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final floor = widget.floor;
    final first = widget.firstFloor;
    final name = floor.anonyname?.trim();
    final firstName = first?.anonyname?.trim();
    final isOp =
        first != null &&
        ((first.floorId > 0 && first.floorId == floor.floorId) ||
            (name != null && name.isNotEmpty && name == firstName));
    final rank = floor.ranking ?? widget.index;
    final colors = Theme.of(context).colorScheme;
    final nameHash = (name ?? '').runes.fold<int>(
      0,
      (value, char) => (value * 31 + char) & 0x7fffffff,
    );
    final nameColor = isOp
        ? colors.primary
        : HSLColor.fromAHSL(
            1,
            (nameHash % 360).toDouble(),
            .55,
            Theme.of(context).brightness == Brightness.dark ? .72 : .34,
          ).toColor();
    final infoStyle = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final folded =
        !floor.deleted &&
        (floor.fold.isNotEmpty || widget.tags.any(isHiddenForumTag));

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (isOp) _badge(context, '洞主'),
                  Container(
                    width: 3,
                    height: 14,
                    decoration: BoxDecoration(
                      color: nameColor,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                  Text(
                    name?.isNotEmpty == true ? name! : '热心同学',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: nameColor,
                    ),
                  ),
                  if (floor.specialTag?.isNotEmpty == true)
                    _badge(context, floor.specialTag!),
                ],
              ),
              const SizedBox(height: 8),
              if (floor.deleted)
                Text('该楼层已被删除', style: infoStyle)
              else ...[
                if (folded)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                    ),
                    label: Text(
                      '${_expanded ? '收起折叠内容' : '内容已折叠，点击展开'}：${floor.fold.isEmpty ? '帖子标记' : floor.fold.join('、')}',
                    ),
                  ),
                if (!folded || _expanded) ...[
                  if (floor.replyTo != null && floor.replyTo! > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: TextButton(
                        onPressed: widget.onTapFloor == null
                            ? null
                            : () => widget.onTapFloor!(floor.replyTo!),
                        child: Text('回复 ##${floor.replyTo}'),
                      ),
                    ),
                  if (floor.content?.isNotEmpty == true)
                    ForumContent(
                      content: floor.content!,
                      onTapHole: widget.onTapHole,
                      onTapFloor: widget.onTapFloor,
                    )
                  else
                    Text('（暂无正文）', style: infoStyle),
                ],
              ],
              if (!floor.deleted && !folded && widget.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in widget.tags)
                      if (isVisibleForumTag(tag)) _badge(context, '#$tag'),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              DefaultTextStyle(
                style: infoStyle,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (widget.showHoleId) Text('#${floor.holeId}'),
                    if (rank != null) Text(rank == 0 ? '首楼' : '${rank + 1}楼'),
                    if (floor.floorId > 0) Text('##${floor.floorId}'),
                    if (floor.timeCreated?.isNotEmpty == true)
                      Text(formatFriendlyTime(floor.timeCreated)),
                    if (floor.modified > 0) const Text('已编辑'),
                    if (!floor.deleted && floor.like > 0)
                      Text('赞 ${floor.like}'),
                    if (!floor.deleted && floor.dislike > 0)
                      Text('踩 ${floor.dislike}'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, String label) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: colors.onSecondaryContainer),
      ),
    );
  }
}
