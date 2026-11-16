// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../core/dansheng_state.dart';
import '../../campus_api.dart';
import '../notice_sheet.dart';
import 'department_directory.dart';
import 'department_notice_model.dart';
import 'department_notice_service.dart';
import 'department_subscription_sheet.dart';

/// Full screen view for browsing department notices with subscription management.
class DepartmentNoticesPage extends StatefulWidget {
  const DepartmentNoticesPage({
    super.key,
    required this.controller,
    required this.initialDepartments,
    this.onUpdateDepartments,
  });

  final DanshengController controller;
  final List<String> initialDepartments;
  final ValueChanged<List<String>>? onUpdateDepartments;

  @override
  State<DepartmentNoticesPage> createState() => _DepartmentNoticesPageState();
}

class _DepartmentNoticesPageState extends State<DepartmentNoticesPage> {
  late List<String> _subscribed = List.from(widget.initialDepartments);
  final DepartmentNoticeService _service = DepartmentNoticeService.instance;

  String? _selectedFilterDept; // null means '全部'
  List<DepartmentNoticeItem> _notices = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadNotices(refresh: false);
  }

  Future<void> _loadNotices({bool refresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await _service.getNotices(_subscribed, refresh: refresh);
      if (mounted) {
        setState(() {
          _notices = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '获取院系通知失败，请下拉重试';
          _loading = false;
        });
      }
    }
  }

  Future<void> _openSubscriptionPicker() async {
    final next = await showDepartmentSubscriptionSheet(
      context,
      currentSelected: _subscribed,
    );
    if (next != null && mounted) {
      setState(() {
        _subscribed = next;
        if (_selectedFilterDept != null && !_subscribed.contains(_selectedFilterDept)) {
          _selectedFilterDept = null;
        }
      });
      widget.onUpdateDepartments?.call(_subscribed);
      _loadNotices(refresh: true);
    }
  }

  Future<void> _openNotice(DepartmentNoticeItem notice) async {
    final api = CampusApi(widget.controller.client);
    try {
      await showNoticeSheet(
        context,
        api,
        title: '[${notice.departmentName}] ${notice.title}',
        url: notice.url,
      );
    } catch (_) {
      try {
        await api.call('campus.openNotice', {'url': notice.url});
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(campusError(e))),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final displayNotices = _selectedFilterDept == null
        ? _notices
        : _notices.where((n) => n.departmentId == _selectedFilterDept).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('院系通知'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_outlined),
            tooltip: '选择接收院系',
            onPressed: _openSubscriptionPicker,
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter Chips Row
          if (_subscribed.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text('全部 (${_notices.length})'),
                    selected: _selectedFilterDept == null,
                    onSelected: (_) => setState(() => _selectedFilterDept = null),
                  ),
                  const SizedBox(width: 8),
                  for (final dept in _subscribed
                      .map(DepartmentDirectory.byId)
                      .whereType<DepartmentInfo>()) ...[
                    ChoiceChip(
                      label: Text(
                        '${dept.shortName} (${_notices.where((n) => n.departmentId == dept.id).length})',
                      ),
                      selected: _selectedFilterDept == dept.id,
                      onSelected: (_) => setState(() {
                        _selectedFilterDept =
                            _selectedFilterDept == dept.id ? null : dept.id;
                      }),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),

          if (_loading && _notices.isEmpty)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_subscribed.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.notifications_off_outlined,
                        size: 48,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '尚未关注任何院系通知',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '点击下方按钮，按学部自选关注的院系',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('选择接收院系'),
                        onPressed: _openSubscriptionPicker,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (displayNotices.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 48,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _error ?? '暂无通知',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('刷新重试'),
                      onPressed: () => _loadNotices(refresh: true),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _loadNotices(refresh: true),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: displayNotices.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final notice = displayNotices[index];
                    return Card(
                      elevation: 0,
                      color: colors.surfaceContainerLowest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: colors.outlineVariant),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _openNotice(notice),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: colors.primaryContainer.withValues(alpha: 0.6),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      notice.departmentName,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: colors.onPrimaryContainer,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  if (notice.date.isNotEmpty)
                                    Text(
                                      notice.date,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                notice.title,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
