// SPDX-License-Identifier: GPL-3.0-or-later
// Layout adapted from DanXi lib/widget/forum/forum_widgets.dart (OTFloorWidget)
// and lib/page/forum/hole_detail.dart. Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'forum_chips.dart';
import 'forum_content.dart';
import 'forum_filter_settings.dart';
import 'forum_format.dart';
import 'forum_mention_support.dart';
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
    this.onQuoteReply,
  });

  final TeaFloor floor;
  final TeaFloor? firstFloor;
  final int? index;
  final bool showHoleId;
  final List<String> tags;
  final VoidCallback? onTap;
  final ValueChanged<int>? onTapHole;
  final ValueChanged<int>? onTapFloor;
  final ValueChanged<TeaFloor>? onQuoteReply;

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

  void _showFloorContextMenu(BuildContext context) {
    final floor = widget.floor;

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
              leading: const Icon(Icons.format_quote_rounded),
              title: Text('引用此楼 (##${floor.floorId})'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onQuoteReply?.call(floor);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制正文'),
              onTap: () async {
                if (floor.content?.isNotEmpty == true) {
                  await Clipboard.setData(ClipboardData(text: floor.content!));
                  if (context.mounted) {
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制楼层内容')),
                    );
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('查看详情'),
              onTap: () {
                Navigator.of(ctx).pop();
                showFloorDetailModal(
                  context,
                  floor: floor,
                  onJumpToFloor: () => widget.onTapFloor?.call(floor.floorId),
                  onQuoteReply: () => widget.onQuoteReply?.call(floor),
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
    final floor = widget.floor;
    final first = widget.firstFloor;
    final name = floor.anonyname?.trim();
    final firstName = first?.anonyname?.trim();
    final isOp =
        first != null &&
        ((first.floorId > 0 && first.floorId == floor.floorId) ||
            (name != null && name.isNotEmpty && name == firstName));
    final rank = floor.ranking ?? widget.index;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final nameColor = isOp ? colors.primary : getHashColor(name ?? '热心同学', isDark: isDark);
    final infoStyle = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final folded =
        !floor.deleted &&
        (floor.fold.isNotEmpty || widget.tags.any(isHiddenForumTag));

    final prefs = ForumPreferences.instance;
    final displayContent = prefs.filterContent(floor.content);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: () => _showFloorContextMenu(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Floor header row matching DanXi
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Wrap(
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
                  ),
                  if (widget.onQuoteReply != null && !floor.deleted)
                    IconButton(
                      icon: const Icon(Icons.format_quote_rounded, size: 18),
                      tooltip: '引用此楼',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => widget.onQuoteReply?.call(floor),
                    ),
                ],
              ),
              const SizedBox(height: 8),

              // Deleted or folded content
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
                      child: ActionChip(
                        avatar: const Icon(Icons.reply_rounded, size: 14),
                        label: Text('回复 ##${floor.replyTo}'),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                        onPressed: widget.onTapFloor == null
                            ? null
                            : () => widget.onTapFloor!(floor.replyTo!),
                      ),
                    ),
                  if (displayContent.isNotEmpty)
                    ForumContent(
                      content: displayContent,
                      onTapHole: widget.onTapHole,
                      onTapFloor: widget.onTapFloor,
                    )
                  else
                    Text('（暂无正文）', style: infoStyle),
                ],
              ],

              // First floor tags
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

              // Bottom metadata row
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
