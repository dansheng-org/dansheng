import 'package:flutter/material.dart';

import '../campus/webvpn_settings.dart';
import '../core/dansheng_state.dart';

/// App settings: campus network, appearance, reminders and app information.
class SettingsScreen extends StatelessWidget {
  final DanshengController controller;

  const SettingsScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新状态',
            onPressed: controller.refreshPermissions,
          ),
        ],
      ),
      // Rebuilt on every controller change, e.g. right after a permission
      // was granted in the system dialog.
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _SettingsBody(controller: controller),
      ),
    );
  }
}

class _SettingsBody extends StatelessWidget {
  final DanshengController controller;
  const _SettingsBody({required this.controller});

  @override
  Widget build(BuildContext context) {
    final perms = controller.permissions;
    final exactAvailable = perms['exact_available'] == true;
    final notifAvailable = perms['notifications_available'] == true;
    final info = controller.info;
    final coreVersion = info['version']?.toString();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        const _SectionTitle('校园网络'),
        WebVpnSettingsCard(controller: controller),
        const _SectionTitle('外观'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('主题', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
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
                    selected: {controller.themeMode},
                    onSelectionChanged: (selected) =>
                        controller.setThemeMode(selected.first),
                  ),
                ),
              ],
            ),
          ),
        ),
        const _SectionTitle('通知与提醒'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _PermissionTile(
                icon: Icons.notifications_active_outlined,
                title: '通知',
                granted: notifAvailable,
                grantedText: '可在后台完成任务或电量不足时提醒你',
                missingText: '未开启：后台任务完成、电量预警等无法提醒',
                action: '授权通知',
                onAction: controller.requestNotifications,
              ),
              const Divider(height: 1, indent: 56),
              _PermissionTile(
                icon: Icons.alarm,
                title: '准时提醒',
                granted: exactAvailable,
                grantedText: '定时任务会按时执行',
                missingText: '未开启：定时任务可能被系统省电延后',
                action: '前往设置',
                onAction: controller.openAlarmSettings,
              ),
            ],
          ),
        ),
        const _SectionTitle('关于'),
        Card(
          child: Column(
            children: [
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('旦生'),
                subtitle: Text('复旦校园生活助手'),
              ),
              if (coreVersion != null) ...[
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.memory_outlined),
                  title: const Text('核心版本'),
                  trailing: Text(
                    coreVersion,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One system permission with its state and, when missing, a way to fix it.
class _PermissionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool granted;
  final String grantedText;
  final String missingText;
  final String action;
  final VoidCallback onAction;

  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.granted,
    required this.grantedText,
    required this.missingText,
    required this.action,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: granted ? scheme.primary : scheme.error),
      title: Text(title),
      subtitle: Text(granted ? grantedText : missingText),
      trailing: granted
          ? Icon(Icons.check_circle, color: scheme.primary)
          : FilledButton.tonal(onPressed: onAction, child: Text(action)),
    );
  }
}
