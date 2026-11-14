import 'package:flutter/material.dart';

import '../core/dansheng_state.dart';

/// Screen displaying core jobs array and task execution statuses.
class TasksScreen extends StatefulWidget {
  final DanshengController controller;

  const TasksScreen({super.key, required this.controller});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'running':
      case 'active':
        return Colors.green;
      case 'scheduled':
      case 'waiting_wake':
      case 'pending':
        return Colors.blue;
      case 'needs_reconciliation':
      case 'reconcile':
        return Colors.orange;
      case 'failed':
      case 'error':
        return Colors.red;
      case 'completed':
      case 'done':
      default:
        return Colors.grey;
    }
  }

  String _formatWakeTime(dynamic wake) {
    if (wake is Map) return _formatWakeTime(wake['run_at'] ?? wake['wake_at']);
    if (wake == null) return '无特定唤醒时间';
    if (wake is num) {
      final dt = DateTime.fromMillisecondsSinceEpoch(wake.toInt());
      return dt.toLocal().toString().split('.').first;
    }
    return wake.toString();
  }

  @override
  Widget build(BuildContext context) {
    final jobs = widget.controller.jobs;
    final isLoading = widget.controller.isLoading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('任务调度中心'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: '增量同步事件',
            onPressed: () => widget.controller.pollIncrementalEvents(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重读快照',
            onPressed: () => widget.controller.refreshAll(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => widget.controller.refreshAll(),
        child: isLoading && jobs.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : jobs.isEmpty
            ? _buildEmptyState()
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: jobs.length,
                itemBuilder: (ctx, index) {
                  return _buildJobCard(jobs[index]);
                },
              ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      children: [
        const SizedBox(height: 80),
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.task_alt_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                '暂无后台任务',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: Text(
                  '当插件通过 Core 调度后台任务时，将在本中心呈现执行状态、系统唤醒时间及结果核对。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => widget.controller.refreshAll(),
                icon: const Icon(Icons.refresh),
                label: const Text('刷新任务列表'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildJobCard(Map<String, dynamic> job) {
    final taskId =
        job['task_id']?.toString() ?? job['id']?.toString() ?? '未知任务';
    final owner = job['plugin_id'] ?? job['owner'] ?? 'Core';
    final status = (job['state'] ?? job['status'] ?? '未知').toString();
    final action = (job['action'] ?? job['description'] ?? '').toString();
    final runAt = job['run_at'] ?? job['scheduled_time'];
    final updatedAt = job['updated_at'];
    final wakeUp = job['wake_up'];

    final isArmed =
        (wakeUp is Map && wakeUp['scheduled'] == true) ||
        job['wake.scheduled'] == true ||
        job['wake_scheduled'] == true;

    String displayState = switch (status) {
      'waiting_for_auth' => '需要登录',
      'waiting_for_approval' => '等待授权',
      'needs_reconciliation' => '结果待核对',
      'running' => '执行中',
      'succeeded' => '已完成',
      'failed' => '执行失败',
      'expired' => '已过期',
      'cancelled' => '已取消',
      _ => status,
    };
    if (status.toLowerCase() == 'scheduled' ||
        status.toLowerCase() == 'waiting_wake') {
      displayState = isArmed ? '已设闹钟 (待唤醒)' : '已保存 (未设闹钟)';
    }

    final statusColor = _getStatusColor(status);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    taskId,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    displayState,
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('所属: $owner', style: Theme.of(context).textTheme.bodySmall),
            if (action.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '动作: $action',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (runAt != null) ...[
              const SizedBox(height: 4),
              Text(
                '执行计划: $runAt',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (updatedAt != null) ...[
              const SizedBox(height: 2),
              Text(
                '更新于: $updatedAt',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.alarm, size: 16, color: Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '唤醒时间: ${_formatWakeTime(wakeUp)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
