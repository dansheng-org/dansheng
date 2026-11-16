// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import 'department_directory.dart';

/// Shows the subscription picker bottom sheet.
Future<List<String>?> showDepartmentSubscriptionSheet(
  BuildContext context, {
  required List<String> currentSelected,
}) =>
    showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => DepartmentSubscriptionSheet(
        initialSelected: currentSelected,
      ),
    );

/// Sheet allowing the user to select which departments to receive notices from.
class DepartmentSubscriptionSheet extends StatefulWidget {
  const DepartmentSubscriptionSheet({
    super.key,
    required this.initialSelected,
  });

  final List<String> initialSelected;

  @override
  State<DepartmentSubscriptionSheet> createState() =>
      _DepartmentSubscriptionSheetState();
}

class _DepartmentSubscriptionSheetState
    extends State<DepartmentSubscriptionSheet> {
  late final Set<String> _selected = Set.from(widget.initialSelected);
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _toggleCategory(String category, bool selectAll) {
    final depts = DepartmentDirectory.byCategory(category);
    setState(() {
      for (final d in depts) {
        if (selectAll) {
          _selected.add(d.id);
        } else {
          _selected.remove(d.id);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final filtered = DepartmentDirectory.all.where((d) {
      if (_searchQuery.isEmpty) return true;
      return d.name.contains(_searchQuery) ||
          d.shortName.contains(_searchQuery) ||
          d.category.contains(_searchQuery);
    }).toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  '选择接收院系通知',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selected
                        ..clear()
                        ..addAll(DepartmentDirectory.defaultDepartmentIds);
                    });
                  },
                  child: const Text('恢复推荐'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Search Field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索院系名称或学部 (如 计算机、经院)...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          setState(() {
                            _searchController.clear();
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.4),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (text) => setState(() => _searchQuery = text.trim()),
            ),
          ),
          const SizedBox(height: 12),

          // List of Departments by Category
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final category in DepartmentDirectory.categories)
                  if (filtered.any((d) => d.category == category))
                    _buildCategorySection(
                      context,
                      category,
                      filtered.where((d) => d.category == category).toList(),
                    ),
              ],
            ),
          ),

          // Bottom Bar
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(
                top: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '已选 ${_selected.length} 个院系',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected.toList()),
                  child: const Text('确认保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategorySection(
    BuildContext context,
    String category,
    List<DepartmentInfo> catDepts,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final allSelected = catDepts.every((d) => _selected.contains(d.id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                category,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colors.onSurface,
                ),
              ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
                onPressed: () => _toggleCategory(category, !allSelected),
                child: Text(
                  allSelected ? '取消该类' : '全选该类',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        Card(
          elevation: 0,
          color: colors.surfaceContainerLow,
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            children: [
              for (final d in catDepts) ...[
                CheckboxListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  value: _selected.contains(d.id),
                  activeColor: colors.primary,
                  title: Text(
                    d.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: _selected.contains(d.id)
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    d.websiteUrl.replaceAll('https://', '').replaceAll('/', ''),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                  onChanged: (_) => _toggle(d.id),
                ),
                if (d != catDepts.last)
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 16,
                    endIndent: 16,
                    color: colors.outlineVariant.withValues(alpha: 0.3),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
