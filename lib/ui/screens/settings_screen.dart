import 'package:flutter/material.dart';

import '../core/dansheng_state.dart';

/// Screen for system permissions, accessibility options, and runtime info.
class SettingsScreen extends StatefulWidget {
  final DanshengController controller;

  const SettingsScreen({super.key, required this.controller});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final perms = widget.controller.permissions;
    final exactAvailable = perms['exact_available'] == true;
    final notifAvailable = perms['notifications_available'] == true;
    final info = widget.controller.info;

    return Scaffold(
      appBar: AppBar(
        title: const Text('系统设置与权限'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新权限状态',
            onPressed: () => widget.controller.refreshPermissions(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Section: System Permissions
          Text(
            '系统权限状态',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          // Exact alarm tile
          Card(
            child: ListTile(
              leading: Icon(
                Icons.alarm,
                color: exactAvailable ? Colors.green : Colors.orange,
              ),
              title: const Text('精确闹钟权限 (Exact Alarm)'),
              subtitle: Text(
                exactAvailable ? '已获得系统精确闹钟权限，任务可准时唤醒' : '未授权：后台任务可能被系统省电机制延迟',
              ),
              trailing: exactAvailable
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : FilledButton.tonal(
                      onPressed: () => widget.controller.openAlarmSettings(),
                      child: const Text('前往设置'),
                    ),
            ),
          ),

          // Notifications tile
          Card(
            child: ListTile(
              leading: Icon(
                Icons.notifications_active,
                color: notifAvailable ? Colors.green : Colors.orange,
              ),
              title: const Text('通知权限 (Notifications)'),
              subtitle: Text(
                notifAvailable
                    ? '已授权：可接收前台服务进度与执行结果通知'
                    : '未授权：任务在后台完成时无法发送系统提醒',
              ),
              trailing: notifAvailable
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : FilledButton.tonal(
                      onPressed: () => widget.controller.requestNotifications(),
                      child: const Text('授权通知'),
                    ),
            ),
          ),

          const SizedBox(height: 24),

          // Section: Appearance & Theme
          Text(
            '外观',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '主题模式',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                        icon: Icon(Icons.brightness_auto),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('浅色'),
                        icon: Icon(Icons.light_mode),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('深色'),
                        icon: Icon(Icons.dark_mode),
                      ),
                    ],
                    selected: {widget.controller.themeMode},
                    onSelectionChanged: (selected) {
                      widget.controller.setThemeMode(selected.first);
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Section: Core Runtime Info
          Text(
            '宿主与核心信息',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildInfoRow('客户端包名', 'org.dansheng.app'),
                  _buildInfoRow('核心协议版本', 'C ABI v1 / Pigeon'),
                  if (info.isNotEmpty)
                    ...info.entries.map(
                      (e) => _buildInfoRow(e.key, '${e.value}'),
                    )
                  else
                    _buildInfoRow('运行环境', 'Android 宿主引擎已就绪'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
