// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dansheng_state.dart';
import '../campus_api.dart';
import 'agent_chat_page.dart';
import 'agent_models.dart';
import 'agent_service.dart';

class AgentPage extends StatelessWidget {
  final DanshengController controller;

  const AgentPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => AgentChatPage(
    controller: controller,
    onOpenLocal: () => Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _LocalAgentPage(controller: controller),
      ),
    ),
  );
}

class _LocalAgentPage extends StatefulWidget {
  const _LocalAgentPage({required this.controller});

  final DanshengController controller;

  @override
  State<_LocalAgentPage> createState() => _LocalAgentPageState();
}

class _LocalAgentPageState extends State<_LocalAgentPage> {
  late final AgentService _service;
  late final CampusAccountScope _accountScope;
  ModalRoute<dynamic>? _route;
  final TextEditingController _queryController = TextEditingController();

  McpServerStatus _mcpStatus = const McpServerStatus(running: false, port: 0);
  bool _mcpLoading = false;
  bool _tokenCopying = false;

  int _modeIndex = 0; // 0: 智能问答, 1: 数据检索
  bool _isSearching = false;
  bool _hasSearched = false;
  String? _errorMessage;

  AgentAnswer? _answer;
  List<AgentHit> _hits = [];

  // Track expanded sources to follow excerpts easily
  final Set<int> _expandedSources = <int>{};

  @override
  void initState() {
    super.initState();
    final api = CampusApi.forAccount(widget.controller);
    _service = AgentService(api);
    _accountScope = api.accountScope!;
    _accountScope.addListener(_dismissOnAccountChange);
    if (_accountScope.accountId?.isNotEmpty ?? false) {
      unawaited(_loadMcpStatus());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (!_accountScope.isCurrent) _dismissOnAccountChange();
  }

  @override
  void dispose() {
    _accountScope.removeListener(_dismissOnAccountChange);
    _accountScope.dispose();
    _queryController.dispose();
    super.dispose();
  }

  bool get _isCurrent => mounted && _accountScope.isCurrent;

  void _showSnackBar(String message) {
    if (_isCurrent) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _dismissOnAccountChange() {
    final route = _route;
    if (route == null) return;
    scheduleMicrotask(() {
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  Future<void> _loadMcpStatus() async {
    try {
      final status = await _service.getMcpStatus();
      if (_isCurrent) {
        setState(() {
          _mcpStatus = status;
        });
      }
    } catch (_) {
      // Ignored if host or session is offline
    }
  }

  Future<void> _toggleMcp(bool enable) async {
    if (!_isCurrent || _mcpLoading) return;
    final account = _accountScope.accountId;
    if (account == null || account.isEmpty) {
      _showSnackBar('请先在账号设置中选择活动账号。');
      return;
    }

    setState(() => _mcpLoading = true);
    try {
      final status = enable
          ? await _service.startMcp()
          : await _service.stopMcp();
      if (_isCurrent) {
        setState(() {
          _mcpStatus = status;
        });
      }
    } catch (e) {
      _showSnackBar(campusError(e));
    } finally {
      if (_isCurrent) {
        setState(() => _mcpLoading = false);
      }
    }
  }

  Future<void> _copyMcpToken() async {
    if (!_isCurrent || _tokenCopying) return;
    setState(() => _tokenCopying = true);
    try {
      final token = await _service.getMcpToken();
      if (!_isCurrent) return;
      if (token.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: token));
        _showSnackBar('已复制连接凭据，请在电脑端外部工具中配置。');
      } else {
        _showSnackBar('服务未就绪，暂无法获取连接凭据。');
      }
    } catch (e) {
      _showSnackBar(campusError(e));
    } finally {
      if (_isCurrent) {
        setState(() => _tokenCopying = false);
      }
    }
  }

  Future<void> _executeSearch() async {
    if (!_isCurrent || _isSearching) return;
    final q = _queryController.text.trim();
    if (q.isEmpty) return;

    final account = _accountScope.accountId;
    if (account == null || account.isEmpty) {
      setState(() {
        _errorMessage = '请先在账号设置中选择活动账号。';
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _hasSearched = true;
    });

    try {
      if (_modeIndex == 0) {
        final answer = await _service.ask(q);
        if (_isCurrent) {
          setState(() {
            _answer = answer;
            _hits = [];
            _expandedSources.clear();
            // Automatically expand all source excerpts for direct reading
            for (final s in answer.sources) {
              _expandedSources.add(s.index);
            }
          });
        }
      } else {
        final hits = await _service.search(q);
        if (_isCurrent) {
          setState(() {
            _hits = hits;
            _answer = null;
          });
        }
      }
    } catch (e) {
      if (_isCurrent) {
        setState(() {
          _errorMessage = campusError(e);
        });
      }
    } finally {
      if (_isCurrent) {
        setState(() => _isSearching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = _accountScope.accountId;

    return Scaffold(
      appBar: AppBar(title: const Text('本地检索与配对'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        children: [
          // Active account bar
          _buildAccountBar(context, account),
          const SizedBox(height: 12.0),

          // External AI Assistant connection card
          _buildMcpCard(context),
          const SizedBox(height: 16.0),

          // Search & Ask Query Card
          _buildSearchControlCard(context),
          const SizedBox(height: 16.0),

          // Search Results / Answers
          if (_isSearching)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_errorMessage != null)
            _buildErrorBox(context, _errorMessage!)
          else if (_hasSearched)
            if (_modeIndex == 0)
              _buildAskAnswerView(context)
            else
              _buildHitsView(context),
        ],
      ),
    );
  }

  Widget _buildAccountBar(BuildContext context, String? account) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (account == null || account.isEmpty) {
      return Card(
        color: colorScheme.errorContainer.withAlpha(80),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              Icon(Icons.account_circle_outlined, color: colorScheme.error),
              const SizedBox(width: 12.0),
              Expanded(
                child: Text(
                  '未绑定活动账号，请先在卡包或设置中切换账号。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        Icon(
          Icons.verified_user_outlined,
          size: 18.0,
          color: colorScheme.primary,
        ),
        const SizedBox(width: 6.0),
        Text(
          '当前账号：$account',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            color: colorScheme.primary,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: Text(
            '仅限本机',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMcpCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isRunning = _mcpStatus.running;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isRunning
              ? colorScheme.primary.withAlpha(120)
              : colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(16.0),
      ),
      color: isRunning
          ? colorScheme.primaryContainer.withAlpha(30)
          : colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  color: isRunning
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8.0),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '外部 AI 助手连接',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '支持电脑端外部工具安全只读连接',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_mcpLoading)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else
                  Switch(value: isRunning, onChanged: _toggleMcp),
              ],
            ),
            const SizedBox(height: 8.0),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 2.0,
                  ),
                  decoration: BoxDecoration(
                    color: isRunning
                        ? Colors.green.withAlpha(40)
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isRunning ? Colors.green : Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 6.0),
                      Text(
                        isRunning
                            ? '服务已就绪 (端口：${_mcpStatus.port})'
                            : '已停止 (未监听端口)',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isRunning
                              ? Colors.green.shade800
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8.0),
                Text(
                  '只读保护 · 切换账号即断开',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (isRunning) ...[
              const Divider(height: 24.0),
              // URL row
              Text(
                '本地连接地址',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4.0),
              SelectableText(
                _mcpStatus.url ?? 'http://127.0.0.1:${_mcpStatus.port}/mcp',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(height: 12.0),

              // Pairing token row (masked by default, only copied explicitly)
              Text(
                '连接凭据',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4.0),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '••••••••••••••••••••••••',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        letterSpacing: 2.0,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _tokenCopying ? null : _copyMcpToken,
                    icon: _tokenCopying
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.copy, size: 16),
                    label: const Text('复制连接凭据'),
                  ),
                ],
              ),
              const SizedBox(height: 12.0),

              // PC adb forward helper
              Text(
                '电脑连接命令',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4.0),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      _mcpStatus.adbCommand ??
                          'adb forward tcp:${_mcpStatus.port} tcp:${_mcpStatus.port}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      if (!_isCurrent) return;
                      final cmd = _mcpStatus.adbCommand;
                      if (cmd != null && cmd.isNotEmpty) {
                        Clipboard.setData(ClipboardData(text: cmd));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制 ADB 映射命令到剪贴板。')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制电脑映射命令'),
                  ),
                ],
              ),
              const SizedBox(height: 12.0),

              // Supported read-only data chips
              Text(
                '支持查询的离线数据',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6.0),
              Wrap(
                spacing: 8.0,
                runSpacing: 4.0,
                children: const [
                  Chip(label: Text('本地记录检索')),
                  Chip(label: Text('日程与预约')),
                  Chip(label: Text('课程与作业')),
                  Chip(label: Text('校园卡状态')),
                ],
              ),
            ] else ...[
              const SizedBox(height: 8.0),
              Text(
                '默认关闭。开启后，电脑端 AI 客户端可通过本地端口只读检索当前账号在手机上已缓存的数据，不提供任何写操作权限。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchControlCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Mode selector
            SegmentedButton<int>(
              segments: const [
                ButtonSegment<int>(
                  value: 0,
                  label: Text('智能问答'),
                  icon: Icon(Icons.chat_bubble_outline),
                ),
                ButtonSegment<int>(
                  value: 1,
                  label: Text('数据检索'),
                  icon: Icon(Icons.search),
                ),
              ],
              selected: {_modeIndex},
              onSelectionChanged: (set) {
                setState(() {
                  _modeIndex = set.first;
                });
              },
            ),
            const SizedBox(height: 16.0),

            // Search query input
            TextField(
              controller: _queryController,
              decoration: InputDecoration(
                hintText: _modeIndex == 0
                    ? '向助手提问（如：饭卡余额、日程、下节课…）'
                    : '输入关键字检索本地缓存记录…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _queryController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _queryController.clear();
                          setState(() {});
                        },
                      )
                    : null,
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12.0)),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 12.0,
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _executeSearch(),
            ),
            const SizedBox(height: 12.0),

            FilledButton.icon(
              onPressed: _queryController.text.trim().isEmpty
                  ? null
                  : _executeSearch,
              icon: Icon(_modeIndex == 0 ? Icons.psychology : Icons.search),
              label: Text(_modeIndex == 0 ? '向助手提问' : '开始检索'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBox(BuildContext context, String message) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colorScheme.error),
            const SizedBox(width: 12.0),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAskAnswerView(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ans = _answer;

    if (ans == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          elevation: 0,
          color: colorScheme.surfaceContainerHighest.withAlpha(120),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16.0),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.format_quote_outlined,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8.0),
                    Text(
                      '本地证据回答',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 2.0,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8.0),
                      ),
                      child: Text(
                        '非大模型推测',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12.0),
                SelectableText(
                  ans.answer,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16.0),

        if (ans.sources.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: Row(
              children: [
                Text(
                  '已引用的本地证据来源 (${ans.sources.length})',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '点击可查看完整摘录',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8.0),
          ...ans.sources.map((src) => _buildSourceCard(context, src)),
        ],
      ],
    );
  }

  Widget _buildSourceCard(BuildContext context, AgentSource src) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isExpanded = _expandedSources.contains(src.index);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8.0),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isExpanded
              ? colorScheme.primary.withAlpha(120)
              : colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: () {
          setState(() {
            if (isExpanded) {
              _expandedSources.remove(src.index);
            } else {
              _expandedSources.add(src.index);
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6.0,
                      vertical: 2.0,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(6.0),
                    ),
                    child: Text(
                      '[来源 ${src.index}]',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  Expanded(
                    child: Text(
                      src.title.isNotEmpty ? src.title : '本地记录',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (src.kind.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6.0,
                        vertical: 2.0,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(6.0),
                      ),
                      child: Text(
                        _kindLabel(src.kind),
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  const SizedBox(width: 4.0),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18.0,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (isExpanded && src.snippet.isNotEmpty) ...[
                const SizedBox(height: 8.0),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10.0),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8.0),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withAlpha(80),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '可读摘录：',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4.0),
                      SelectableText(
                        src.snippet,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 6.0),
              Row(
                children: [
                  Icon(Icons.link, size: 14.0, color: colorScheme.outline),
                  const SizedBox(width: 4.0),
                  Expanded(
                    child: Text(
                      src.sourceId,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.outline,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  if (src.updatedAt.isNotEmpty)
                    Text(
                      src.updatedAt,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHitsView(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_hits.isEmpty) {
      return Card(
        color: colorScheme.surfaceContainerLow,
        child: const Padding(
          padding: EdgeInsets.all(24.0),
          child: Center(child: Text('本地未找到匹配的记录。')),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(
            '检索命中 (${_hits.length} 条记录)',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 8.0),
        ..._hits.map((hit) => _buildHitCard(context, hit)),
      ],
    );
  }

  Widget _buildHitCard(BuildContext context, AgentHit hit) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8.0),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 2.0,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6.0),
                  ),
                  child: Text(
                    _kindLabel(hit.kind),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8.0),
                Expanded(
                  child: Text(
                    hit.title.isNotEmpty ? hit.title : '本地记录',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (hit.snippet.isNotEmpty) ...[
              const SizedBox(height: 8.0),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: Text(hit.snippet, style: theme.textTheme.bodyMedium),
              ),
            ],
            const SizedBox(height: 6.0),
            Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 14.0,
                  color: colorScheme.outline,
                ),
                const SizedBox(width: 4.0),
                Expanded(
                  child: Text(
                    hit.sourceId,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.outline,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                if (hit.updatedAt.isNotEmpty)
                  Text(
                    hit.updatedAt,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _kindLabel(String kind) {
    return switch (kind) {
      'card' => '校园卡',
      'course' => '课程',
      'calendar' => '日程/预约',
      'task' => '任务',
      'notice' => '通知',
      _ => '记录',
    };
  }
}
