// SPDX-License-Identifier: GPL-3.0-or-later
// ignore_for_file: deprecated_member_use
// Content filtering and preferences adapted from DanXi lib/util/forum/clean_mode_filter.dart
// and lib/provider/settings_provider.dart. Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'package:flutter/material.dart';

import 'forum_models.dart';

/// Clean mode filter from DanXi: removes unfriendly emojis.
class CleanModeFilter {
  static const List<String> deleteEmoji = [
    '😅',
    '😄',
    '😋',
    '🥰',
    '🤭',
    '😊',
    '😍',
    '😇',
    '🤗',
    '😁',
    '🤤',
    '😡',
    '🥵',
    '🤓',
  ];

  static String? cleanText(String? content) {
    if (content == null) return null;
    String newContent = content;
    for (final element in deleteEmoji) {
      newContent = newContent.replaceAll(element, ' ');
    }
    return newContent;
  }
}

/// Forum folded post behavior: fold (expandable), show (direct), or hide (completely hidden).
enum FoldBehavior {
  fold('fold', '折叠显示', '折叠有折叠标记的帖子，点击展开'),
  show('show', '直接显示', '直接显示所有内容，不折叠'),
  hide('hide', '完全隐藏', '完全不显示含有折叠标记的帖子');

  final String value;
  final String label;
  final String description;
  const FoldBehavior(this.value, this.label, this.description);

  static FoldBehavior fromString(String? str) {
    switch (str) {
      case 'show':
        return FoldBehavior.show;
      case 'hide':
        return FoldBehavior.hide;
      case 'fold':
      default:
        return FoldBehavior.fold;
    }
  }
}

/// Global forum preferences and filter state manager.
class ForumPreferences extends ChangeNotifier {
  static final ForumPreferences instance = ForumPreferences._internal();

  ForumPreferences._internal();

  bool _cleanMode = false;
  FoldBehavior _foldBehavior = FoldBehavior.fold;
  final Set<String> _hiddenTags = {};
  final Set<int> _hiddenHoles = {};
  String? _selectedTagFilter;

  bool get cleanMode => _cleanMode;
  FoldBehavior get foldBehavior => _foldBehavior;
  List<String> get hiddenTags => _hiddenTags.toList();
  List<int> get hiddenHoles => _hiddenHoles.toList();
  String? get selectedTagFilter => _selectedTagFilter;

  void setCleanMode(bool value) {
    if (_cleanMode != value) {
      _cleanMode = value;
      notifyListeners();
    }
  }

  void setFoldBehavior(FoldBehavior value) {
    if (_foldBehavior != value) {
      _foldBehavior = value;
      notifyListeners();
    }
  }

  void addHiddenTag(String tag) {
    final clean = tag.trim().replaceFirst(RegExp(r'^#'), '');
    if (clean.isNotEmpty && _hiddenTags.add(clean)) {
      notifyListeners();
    }
  }

  void removeHiddenTag(String tag) {
    final clean = tag.trim().replaceFirst(RegExp(r'^#'), '');
    if (_hiddenTags.remove(clean)) {
      notifyListeners();
    }
  }

  void hideHole(int holeId) {
    if (holeId > 0 && _hiddenHoles.add(holeId)) {
      notifyListeners();
    }
  }

  void unhideHole(int holeId) {
    if (_hiddenHoles.remove(holeId)) {
      notifyListeners();
    }
  }

  void clearHiddenHoles() {
    if (_hiddenHoles.isNotEmpty) {
      _hiddenHoles.clear();
      notifyListeners();
    }
  }

  void setTagFilter(String? tag) {
    final clean = tag?.trim().replaceFirst(RegExp(r'^#'), '');
    final next = (clean == null || clean.isEmpty || clean == '默认') ? null : clean;
    if (_selectedTagFilter != next) {
      _selectedTagFilter = next;
      notifyListeners();
    }
  }

  /// Whether a hole should be hidden based on hidden posts, blocked tags, or hide-folded behavior.
  bool shouldHideHole(TeaHole hole) {
    // 1. Manually hidden holes
    if (_hiddenHoles.contains(hole.holeId)) return true;

    // 2. Blocked tags
    if (_hiddenTags.isNotEmpty &&
        hole.tags.any((t) => _hiddenTags.contains(t.replaceFirst(RegExp(r'^#'), '')))) {
      return true;
    }

    // 3. Completely hide folded posts if foldBehavior == FoldBehavior.hide
    if (_foldBehavior == FoldBehavior.hide && hole.tags.any(isHiddenForumTag)) {
      return true;
    }

    // 4. Tag filter
    if (_selectedTagFilter != null && !hole.tags.contains(_selectedTagFilter)) {
      return true;
    }

    return false;
  }

  /// Filter content string according to clean mode.
  String filterContent(String? content) {
    if (content == null || content.isEmpty) return '';
    if (_cleanMode) {
      return CleanModeFilter.cleanText(content) ?? '';
    }
    return content;
  }
}

/// Dialog for managing forum content filtering, clean mode, fold behavior, and blocked tags.
class ForumFilterDialog extends StatefulWidget {
  const ForumFilterDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const ForumFilterDialog(),
    );
  }

  @override
  State<ForumFilterDialog> createState() => _ForumFilterDialogState();
}

class _ForumFilterDialogState extends State<ForumFilterDialog> {
  final _tagController = TextEditingController();
  final _prefs = ForumPreferences.instance;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onPrefsChanged);
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPrefsChanged);
    _tagController.dispose();
    super.dispose();
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  void _handleAddTag() {
    final text = _tagController.text.trim();
    if (text.isNotEmpty) {
      _prefs.addHiddenTag(text);
      _tagController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.tune_rounded),
          SizedBox(width: 8),
          Text('论坛过滤与偏好'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Clean mode switch
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('净化模式 (Clean Mode)'),
                subtitle: const Text('开启后自动过滤不友好表情符号（如 😅、😡 等）'),
                value: _prefs.cleanMode,
                onChanged: (val) => _prefs.setCleanMode(val),
              ),
              const Divider(),
              const SizedBox(height: 8),

              // Fold behavior selector
              Text(
                '折叠帖子显示方式',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              for (final behavior in FoldBehavior.values)
                RadioListTile<FoldBehavior>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(behavior.label),
                  subtitle: Text(behavior.description),
                  value: behavior,
                  groupValue: _prefs.foldBehavior,
                  onChanged: (val) {
                    if (val != null) _prefs.setFoldBehavior(val);
                  },
                ),
              const Divider(),
              const SizedBox(height: 8),

              // Blocked tags section
              Text(
                '屏蔽标签管理',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '包含以下标签的帖子将被自动隐藏：',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _tagController,
                      decoration: const InputDecoration(
                        hintText: '输入要屏蔽的标签名称',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _handleAddTag(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _handleAddTag,
                    child: const Text('添加'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_prefs.hiddenTags.isEmpty)
                Text(
                  '暂无屏蔽标签',
                  style: TextStyle(fontSize: 12, color: colors.outline),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in _prefs.hiddenTags)
                      InputChip(
                        label: Text('#$tag'),
                        onDeleted: () => _prefs.removeHiddenTag(tag),
                      ),
                  ],
                ),
              const Divider(),
              const SizedBox(height: 8),

              // Hidden holes section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '已屏蔽帖子 (${_prefs.hiddenHoles.length}篇)',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  if (_prefs.hiddenHoles.isNotEmpty)
                    TextButton(
                      onPressed: () => _prefs.clearHiddenHoles(),
                      child: const Text('清空全部'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
