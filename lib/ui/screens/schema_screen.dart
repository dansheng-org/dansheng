import 'package:flutter/material.dart';

import '../core/dansheng_client.dart';
import '../schema/schema_models.dart';
import '../schema/schema_renderer.dart';

/// Full screen wrapper for rendering a plugin's UI entry declaration.
class SchemaScreen extends StatelessWidget {
  final String pluginId;
  final UiDeclarationModel declaration;
  final DanshengClient client;
  final String? activeAccountId;
  final VoidCallback? onRefresh;
  final Stream<String>? componentChanges;
  final Map<String, dynamic>? initialValues;

  const SchemaScreen({
    super.key,
    required this.pluginId,
    required this.declaration,
    required this.client,
    this.activeAccountId,
    this.onRefresh,
    this.componentChanges,
    this.initialValues,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(declaration.title),
        actions: [
          if (onRefresh != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: onRefresh,
            ),
        ],
      ),
      body: SafeArea(
        child: SchemaRenderer(
          initialValues: initialValues,
          componentChanges: componentChanges,
          pluginId: pluginId,
          declaration: declaration,
          client: client,
          activeAccountId: activeAccountId,
          onActionCompleted: onRefresh,
        ),
      ),
    );
  }
}
