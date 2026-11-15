import 'package:flutter/material.dart';

import '../campus/campus_api.dart' show campusError;
import '../core/dansheng_state.dart';
import '../schema/schema_models.dart';
import 'schema_screen.dart';
import 'tasks_screen.dart';
import 'import_panel.dart';

class PluginsScreen extends StatefulWidget {
  final DanshengController controller;
  const PluginsScreen({super.key, required this.controller});
  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  final schemas = Expando<List<UiDeclarationModel>>();
  Future<void> command(Future<void> Function() run) async {
    try {
      await run();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作未完成：${campusError(e)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final rows = c.plugins;
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件'),
        actions: [
          IconButton(
            tooltip: '定时任务',
            icon: const Icon(Icons.schedule),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => TasksScreen(controller: c),
              ),
            ),
          ),
          IconButton(
            tooltip: '导入插件包 (.dspack)',
            icon: const Icon(Icons.add),
            onPressed: () => showPluginImporter(context, c),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: c.refreshAll,
        child: ListView.builder(
          padding: const EdgeInsets.all(18),
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: rows.isEmpty ? 1 : rows.length,
          itemBuilder: (ctx, i) {
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(top: 28),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.timer_outlined, size: 34),
                        const SizedBox(height: 14),
                        Text('定时抢场', style: Theme.of(ctx).textTheme.titleLarge),
                        const SizedBox(height: 6),
                        const Text('未安装插件'),
                        const SizedBox(height: 16),
                        FilledButton.tonalIcon(
                          onPressed: () => showPluginImporter(context, c),
                          icon: const Icon(Icons.file_open_outlined),
                          label: const Text('导入插件包'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            final p = rows[i],
                m = p['manifest'] is Map ? p['manifest'] as Map : p;
            final id = p['id']?.toString() ?? '',
                sports = id == 'official.fudan-sports',
                enabled = p['enabled'] == true;
            final entries = schemas[p] ??= [
              for (final e
                  in (m['ui'] is List ? m['ui'] as List : const [])
                      .whereType<Map>())
                if (!sports ||
                    [
                      'sports_schedule',
                      'task_list',
                      'task_management',
                    ].contains(e['id']))
                  _entry(e),
            ];
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    title: Text(sports ? '定时抢场' : m['name']?.toString() ?? id),
                    subtitle: Text(enabled ? '已启用' : '已停用'),
                    value: enabled,
                    onChanged: (v) => command(
                      () => v ? c.enablePlugin(id) : c.disablePlugin(id),
                    ),
                  ),
                  if (enabled)
                    for (final entry in entries)
                      ListTile(
                        title: Text(entry.title),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          ctx,
                          MaterialPageRoute<void>(
                            builder: (_) => SchemaScreen(
                              pluginId: id,
                              declaration: entry,
                              client: c.client,
                              activeAccountId: c.activeAccountId,
                              componentChanges: c.componentChanges,
                            ),
                          ),
                        ),
                      ),
                  ExpansionTile(
                    title: const Text('插件信息'),
                    children: [
                      ListTile(
                        title: Text(id),
                        subtitle: Text(
                          [
                            ...(m['capabilities'] as List? ?? []),
                            ...(m['network'] as List? ?? []),
                          ].join(' · '),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => command(() => c.removePlugin(id)),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('卸载插件'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  UiDeclarationModel _entry(Map v) {
    try {
      return UiDeclarationModel.fromJson(Map<String, dynamic>.from(v));
    } catch (_) {
      return UiDeclarationModel(
        id: '',
        type: 'card',
        title: '页面版本不兼容',
        uiVersion: 2,
        raw: const {},
      );
    }
  }
}
