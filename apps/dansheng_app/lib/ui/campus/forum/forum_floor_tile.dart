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
    this.onEdit,
    this.onDelete,
    this.onReport,
    this.onlyPerson,
    this.onToggleOnlyPerson,
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

  /// Own floors only: edit or delete it (DanXi `is_me`).
  final ValueChanged<TeaFloor>? onEdit;
  final ValueChanged<TeaFloor>? onDelete;
  final ValueChanged<TeaFloor>? onReport;

  /// The name whose floors alone are shown, if any.
  final String? onlyPerson;
  final ValueChanged<TeaFloor>? onToggleOnlyPerson;

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

  /// Floor actions, in DanXi's order: own-floor edits first, then copying,
  /// showing one person, and reporting.
  void _showFloorContextMenu(BuildContext context) {
    final floor = widget.floor;
    final messenger = ScaffoldMessenger.of(context);

    Widget item(
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool destructive = false,
    }) {
      final color = destructive ? Theme.of(context).colorScheme.error : null;
      return Builder(
        builder: (ctx) => ListTile(
          leading: Icon(icon, color: color),
          title: Text(label, style: TextStyle(color: color)),
          onTap: () {
            Navigator.of(ctx).pop();
            onTap();
          },
        ),
      );
    }

    void copy(String text, String done) {
      Clipboard.setData(ClipboardData(text: text));
      messenger.showSnackBar(SnackBar(content: Text(done)));
    }

    final name = floor.anonyname?.trim();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!floor.deleted && widget.onQuoteReply != null)
                item(
                  Icons.reply_rounded,
                  '回复此楼 (##${floor.floorId})',
                  () => widget.onQuoteReply!(floor),
                ),
              if (floor.isMe && !floor.deleted && widget.onEdit != null)
                item(Icons.edit_outlined, '修改', () => widget.onEdit!(floor)),
              if (floor.isMe && !floor.deleted && widget.onDelete != null)
                item(
                  Icons.delete_outline_rounded,
                  '删除',
                  () => widget.onDelete!(floor),
                  destructive: true,
                ),
              if (floor.content?.isNotEmpty == true && !floor.deleted)
                item(
                  Icons.copy_rounded,
                  '复制正文',
                  () => copy(floor.content!, '已复制楼层内容'),
                ),
              if (floor.content?.isNotEmpty == true && !floor.deleted)
                item(
                  Icons.text_fields_rounded,
                  '选择文字',
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text('##${floor.floorId}')),
                        body: SafeArea(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              floor.content!,
                              style: const TextStyle(fontSize: 16, height: 1.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              item(
                Icons.tag_rounded,
                '复制楼层号',
                () => copy('##${floor.floorId}', '已复制楼层号'),
              ),
              if (name != null &&
                  name.isNotEmpty &&
                  widget.onToggleOnlyPerson != null)
                item(
                  Icons.person_search_outlined,
                  widget.onlyPerson == null ? '只看此人' : '显示全部回复',
                  () => widget.onToggleOnlyPerson!(floor),
                ),
              item(Icons.info_outline_rounded, '查看详情', () {
                showFloorDetailModal(
                  context,
                  floor: floor,
                  onJumpToFloor: () => widget.onTapFloor?.call(floor.floorId),
                  onQuoteReply: () => widget.onQuoteReply?.call(floor),
                );
              }),
              if (!floor.isMe && widget.onReport != null)
                item(
                  Icons.flag_outlined,
                  '举报',
                  () => widget.onReport!(floor),
                  destructive: true,
                ),
            ],
          ),
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

    final nameColor = isOp
        ? colors.primary
        : getHashColor(name ?? '热心同学', isDark: isDark);
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
                if (folded && prefs.foldBehavior == FoldBehavior.fold)
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
                if (!folded ||
                    prefs.foldBehavior == FoldBehavior.show ||
                    _expanded) ...[
                  if (floor.replyTo != null && floor.replyTo! > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: ActionChip(
                        avatar: const Icon(Icons.reply_rounded, size: 14),
                        label: Text('回复 ##${floor.replyTo}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 0,
                        ),
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
                      selectable: false,
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
