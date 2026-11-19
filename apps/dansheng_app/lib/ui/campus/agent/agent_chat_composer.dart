// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../agent/agent_types.dart';

class AgentChatComposer extends StatelessWidget {
  const AgentChatComposer({
    super.key,
    required this.controller,
    required this.config,
    required this.attachments,
    required this.sourceCount,
    required this.canEdit,
    required this.generating,
    required this.switchingAccount,
    required this.savingModel,
    required this.pickingAttachment,
    required this.onChanged,
    required this.onOptions,
    required this.onModel,
    required this.onDeleteAttachment,
    required this.onSend,
    required this.onStop,
    required this.historySaveError,
    required this.onRetrySave,
  });

  final TextEditingController controller;
  final AgentModelConfig config;
  final List<AgentAttachment> attachments;
  final int sourceCount;
  final bool canEdit;
  final bool generating;
  final bool switchingAccount;
  final bool savingModel;
  final bool pickingAttachment;
  final VoidCallback onChanged;
  final VoidCallback onOptions;
  final VoidCallback onModel;
  final ValueChanged<AgentAttachment> onDeleteAttachment;
  final VoidCallback? onSend;
  final VoidCallback onStop;
  final String? historySaveError;
  final VoidCallback onRetrySave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = switchingAccount
        ? '正在切换账号…'
        : pickingAttachment
        ? '正在读取附件…'
        : null;
    final modelLabel = savingModel ? '正在切换模型…' : config.displayModel;
    final optionsLabel = sourceCount == 0
        ? '添加与信息源'
        : '添加与信息源，已启用 $sourceCount 项';

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Material(
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (historySaveError case final String error)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(
                            error,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                          TextButton(
                            onPressed: onRetrySave,
                            child: const Text('重试保存'),
                          ),
                        ],
                      ),
                    ),
                  if (status != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(status, style: theme.textTheme.bodySmall),
                      ),
                    ),
                  if (attachments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (final file in attachments)
                            InputChip(
                              avatar: const Icon(
                                Icons.insert_drive_file_outlined,
                              ),
                              label: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 160,
                                ),
                                child: Text(
                                  file.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              tooltip: file.name,
                              deleteButtonTooltipMessage: '移除 ${file.name}',
                              onDeleted: canEdit
                                  ? () => onDeleteAttachment(file)
                                  : null,
                            ),
                        ],
                      ),
                    ),
                  TextField(
                    controller: controller,
                    enabled: canEdit,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: 4000,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      labelText: '消息',
                      floatingLabelBehavior: FloatingLabelBehavior.never,
                      border: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      counterText: '',
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                  Row(
                    children: [
                      IconButton(
                        key: const Key('chat-composer-options'),
                        tooltip: optionsLabel,
                        onPressed: canEdit ? onOptions : null,
                        icon: Badge(
                          isLabelVisible: sourceCount > 0,
                          label: ExcludeSemantics(child: Text('$sourceCount')),
                          child: const Icon(Icons.add_rounded),
                        ),
                      ),
                      Expanded(
                        child: Tooltip(
                          message: '选择模型 · ${config.displayModel}',
                          excludeFromSemantics: true,
                          child: TextButton(
                            key: const Key('chat-model-picker'),
                            onPressed: canEdit ? onModel : null,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            child: Semantics(
                              label: '选择模型，$modelLabel。发送至 ${config.baseUrl}',
                              excludeSemantics: true,
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          modelLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          '发送至 ${config.baseUrl.authority}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  const Icon(Icons.expand_more, size: 18),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton.filled(
                        tooltip: generating ? '停止生成' : '发送',
                        onPressed: generating ? onStop : onSend,
                        icon: Icon(
                          generating ? Icons.stop_rounded : Icons.arrow_upward,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum AgentComposerAction { attach, manageApprovals }

class AgentComposerOptions extends StatelessWidget {
  const AgentComposerOptions({
    super.key,
    required this.config,
    required this.hasAccount,
    required this.canAttach,
    required this.sources,
    required this.sourceAvailable,
    required this.onSourceChanged,
  });

  final AgentModelConfig config;
  final bool hasAccount;
  final bool canAttach;
  final Set<AgentSourceKind> sources;
  final bool Function(AgentSourceKind) sourceAvailable;
  final void Function(AgentSourceKind, bool) onSourceChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('添加附件'),
              subtitle: canAttach
                  ? null
                  : Text('每条消息最多 $agentMaxAttachments 个附件'),
              onTap: canAttach
                  ? () => Navigator.of(context).pop(AgentComposerAction.attach)
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('管理授权'),
              onTap: () =>
                  Navigator.of(context)
                      .pop(AgentComposerAction.manageApprovals),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text('信息源', style: textTheme.titleMedium),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasAccount ? '读取作业附件时请启用「课程文件」。' : '选择活动账号后可使用校园信息源。',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '发送会将消息和对话上下文发往 ${config.baseUrl}。',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            for (final source in AgentSourceKind.values)
              SwitchListTile(
                title: Text(source.label),
                subtitle: source == AgentSourceKind.web
                    ? Text(
                        (config.searchApiKey?.isNotEmpty ?? false)
                            ? '通过 Brave Search 搜索'
                            : '通过模型服务搜索',
                      )
                    : null,
                value: sources.contains(source),
                onChanged: sourceAvailable(source)
                    ? (enabled) => onSourceChanged(source, enabled)
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
