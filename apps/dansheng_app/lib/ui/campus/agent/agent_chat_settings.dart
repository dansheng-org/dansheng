// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../agent/agent_types.dart';
import '../../../agent/model_catalog.dart';
import 'agent_model_picker.dart';

class AgentChatSettings extends StatefulWidget {
  const AgentChatSettings({
    super.key,
    required this.config,
    required this.canClear,
    required this.onSave,
    required this.onClear,
    this.loadModels,
    this.onClearCourseFiles,
  });

  final AgentModelConfig? config;
  final bool canClear;
  final Future<void> Function(AgentModelConfig config) onSave;
  final Future<void> Function() onClear;
  final ModelCatalogLoader? loadModels;
  final Future<int> Function()? onClearCourseFiles;

  @override
  State<AgentChatSettings> createState() => _AgentChatSettingsState();
}

class _AgentChatSettingsState extends State<AgentChatSettings> {
  static const _catalogDebounce = Duration(milliseconds: 450);

  final _form = GlobalKey<FormState>();
  late ModelProvider _provider;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  final _searchApiKey = TextEditingController();
  late final AgentModelConfig? _savedConfig;
  late final Uri? _savedPrefix;
  Uri? _editedPrefix;
  Timer? _catalogTimer;
  ModelCatalog? _catalog;
  int _catalogGeneration = 0;
  List<ModelCatalogEntry>? _models;
  bool _loadingModels = false;
  bool _catalogFailed = false;
  bool _removeSearchKey = false;
  Route<Object?>? _dialog;
  bool _saving = false;
  bool _clearingFiles = false;
  ModelCatalogEntry? _selectedModel;
  String? _error;

  bool get _canRetainKey => _matchesSavedDestination(_editedPrefix);

  bool _matchesSavedDestination(Uri? prefix) =>
      prefix != null &&
      prefix == _savedPrefix &&
      _provider == _savedConfig?.provider;

  String get _effectiveApiKey {
    final key = _apiKey.text.trim();
    return key.isEmpty && _canRetainKey ? _savedConfig!.apiKey : key;
  }

  bool get _canLoadModels =>
      _editedPrefix != null && _isValidKey(_effectiveApiKey);

  String? get _savedSearchKey => _savedConfig?.searchApiKey;

  String get _catalogStatus {
    if (_loadingModels) return '正在读取模型列表…';
    if (_catalogFailed) return '无法读取模型列表，可手动输入模型标识。';
    if (_models case final models?) {
      return models.isEmpty ? '模型列表为空，可手动输入模型标识。' : '已读取 ${models.length} 个模型。';
    }
    return '填写有效的 API 地址和密钥后自动读取。';
  }

  bool _isValidKey(String key) =>
      key.isNotEmpty &&
      key.length <= 4096 &&
      key.codeUnits.every((unit) => unit >= 33 && unit <= 126);

  @override
  void initState() {
    super.initState();
    final config = _savedConfig = widget.config;
    _provider = config?.provider ?? ModelProvider.openAi;
    final address =
        config?.baseUrl ?? AgentModelConfig.defaultBaseUrl(_provider);
    _baseUrl = TextEditingController(text: address.toString());
    _editedPrefix = _parsePrefix(address.toString());
    _savedPrefix = config == null ? null : _editedPrefix;
    _model = TextEditingController(text: config?.model);
    _apiKey = TextEditingController();
    _queueCatalog();
  }

  @override
  void dispose() {
    _cancelCatalog();
    final prompt = _dialog;
    if (prompt != null) {
      scheduleMicrotask(() {
        final navigator = prompt.navigator;
        if (navigator != null && navigator.mounted && prompt.isActive) {
          navigator.removeRoute(prompt);
        }
      });
    }
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    _searchApiKey.dispose();
    super.dispose();
  }

  void _changeProvider(ModelProvider? provider) {
    if (provider == null || provider == _provider) return;
    final previousDefault = AgentModelConfig.defaultBaseUrl(_provider);
    setState(() {
      if (_editedPrefix == normalizeModelApiPrefix(previousDefault)) {
        final address = AgentModelConfig.defaultBaseUrl(provider);
        _baseUrl.text = address.toString();
        _editedPrefix = normalizeModelApiPrefix(address);
      }
      _provider = provider;
      _selectedModel = null;
      _apiKey.clear();
      _queueCatalog();
    });
  }

  void _changeBaseUrl(String value) {
    final prefix = _parsePrefix(value);
    if (prefix == _editedPrefix) return;
    setState(() {
      // A draft entered before the first valid address has no destination yet.
      if (_editedPrefix != null || _savedConfig != null) _apiKey.clear();
      _editedPrefix = prefix;
      _selectedModel = null;
      _queueCatalog();
    });
  }

  Uri? _parsePrefix(String value) {
    try {
      return normalizeModelApiPrefix(
        AgentModelConfig.parseBaseUrl(value.trim()),
      );
    } on FormatException {
      return null;
    }
  }

  void _cancelCatalog() {
    _catalogGeneration++;
    _catalogTimer?.cancel();
    _catalog?.close();
    _catalog = null;
  }

  void _queueCatalog({bool refresh = false}) {
    _cancelCatalog();
    if (!refresh) _models = null;
    _catalogFailed = false;
    _loadingModels = _canLoadModels;
    if (!_loadingModels) return;

    final generation = _catalogGeneration;
    _catalogTimer = Timer(
      refresh ? Duration.zero : _catalogDebounce,
      () => _loadCatalog(generation).ignore(),
    );
  }

  Future<List<ModelCatalogEntry>> _loadCatalog(int generation) async {
    // Injected loaders can finish even after cancellation, so both outcomes
    // are accepted only for the generation that started the load.
    const cancelled = AgentFailure('模型列表读取已取消。');
    if (!mounted || generation != _catalogGeneration || !_canLoadModels) {
      throw cancelled;
    }
    try {
      final loader = widget.loadModels ?? (_catalog = ModelCatalog()).load;
      final models = await loader(
        provider: _provider,
        baseUrl: _editedPrefix!,
        apiKey: _effectiveApiKey,
      );
      if (!mounted || generation != _catalogGeneration) throw cancelled;
      setState(() {
        _models = models;
        _loadingModels = false;
      });
      return models;
    } catch (_) {
      if (mounted && generation == _catalogGeneration) {
        setState(() {
          _catalogFailed = true;
          _loadingModels = false;
        });
      }
      rethrow;
    }
  }

  Future<void> _pickModel() async {
    final models = _models;
    if (_dialog != null || models == null || models.isEmpty) return;
    var generation = _catalogGeneration;
    final picker = DialogRoute<ModelCatalogEntry>(
      context: context,
      builder: (_) => AgentModelPicker(
        selectedId: _model.text.trim(),
        initialModels: models,
        load: () async {
          if (!mounted || generation != _catalogGeneration || !_canLoadModels) {
            throw const AgentFailure('模型列表读取已取消。');
          }
          setState(() {
            _cancelCatalog();
            generation = _catalogGeneration;
            _loadingModels = true;
            _catalogFailed = false;
          });
          return _loadCatalog(generation);
        },
      ),
    );
    _dialog = picker;
    final model = await Navigator.of(context).push(picker);
    _dialog = null;
    if (!mounted ||
        _saving ||
        generation != _catalogGeneration ||
        model == null) {
      return;
    }
    _selectedModel = model;
    _model.text = model.id;
  }

  String? _validateBaseUrl(String? value) {
    try {
      AgentModelConfig.parseBaseUrl(value?.trim() ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final baseUrl = AgentModelConfig.parseBaseUrl(_baseUrl.text.trim());
    final searchKey = _searchApiKey.text.trim();
    final model = _model.text.trim();
    final modelLabel = _selectedModel?.id == model
        ? _selectedModel?.label
        : _models?.where((entry) => entry.id == model).firstOrNull?.label ??
              (_canRetainKey && model == _savedConfig?.model
                  ? _savedConfig?.modelLabel
                  : null);
    final config = AgentModelConfig(
      provider: _provider,
      baseUrl: baseUrl,
      model: model,
      modelLabel: modelLabel,
      apiKey: _effectiveApiKey,
      searchApiKey: searchKey.isNotEmpty
          ? searchKey
          : (_removeSearchKey ? null : _savedSearchKey),
    );
    await _persist(() => widget.onSave(config), '无法保存模型设置，请重试。');
  }

  Future<void> _clear() async {
    if (_saving || _dialog != null) return;
    final prompt = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除模型配置？'),
        content: const Text('这会清除设备中保存的模型配置和 API 密钥。对话仍可在历史中查看。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    _dialog = prompt;
    final confirmed = await Navigator.of(context).push(prompt);
    _dialog = null;
    if (!mounted || confirmed != true || _saving) return;
    await _persist(widget.onClear, '无法移除模型设置，请重试。');
  }

  Future<void> _clearCourseFiles() async {
    final clear = widget.onClearCourseFiles;
    if (clear == null || _clearingFiles || _dialog != null || _saving) return;
    final prompt = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理课程文件缓存？'),
        content: const Text('这会清除当前账号本机保存的课程文件缓存。需要时可重新下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理缓存'),
          ),
        ],
      ),
    );
    _dialog = prompt;
    final confirm = await Navigator.of(context).push(prompt);
    _dialog = null;
    if (!mounted || confirm != true) return;
    setState(() => _clearingFiles = true);
    try {
      final count = await clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已清理 $count 个课程文件缓存。')));
      }
    } catch (error) {
      if (mounted) {
        final message = error is AgentFailure ? error.message : '无法清理课程文件缓存。';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _clearingFiles = false);
    }
  }

  Future<void> _persist(
    Future<void> Function() action,
    String errorMessage,
  ) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = errorMessage;
      });
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('模型设置')),
        body: SafeArea(
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<ModelProvider>(
                  initialValue: _provider,
                  decoration: const InputDecoration(
                    labelText: '接口协议',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: ModelProvider.openAi,
                      child: Text('OpenAI 兼容'),
                    ),
                    DropdownMenuItem(
                      value: ModelProvider.anthropic,
                      child: Text('Anthropic 兼容'),
                    ),
                  ],
                  onChanged: _saving ? null : _changeProvider,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _baseUrl,
                  enabled: !_saving,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'API 地址前缀',
                    helperText: '使用 HTTPS 地址，保留服务商要求的版本路径。',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _changeBaseUrl,
                  validator: _validateBaseUrl,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _apiKey,
                  enabled: !_saving,
                  obscureText: true,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: InputDecoration(
                    labelText: 'API 密钥',
                    helperText: _canRetainKey ? '留空保留已保存密钥' : null,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(_queueCatalog),
                  validator: (value) {
                    final key = value?.trim() ?? '';
                    if (key.isEmpty) {
                      return _canRetainKey ? null : '请输入 API 密钥。';
                    }
                    return _isValidKey(key) ? null : '请输入有效的 API 密钥。';
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _model,
                  enabled: !_saving,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '模型标识',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final model = value?.trim() ?? '';
                    if (model.isEmpty) return '请输入服务商提供的模型标识。';
                    if (model.length > 256) return '模型标识最多可输入 256 个字符。';
                    return null;
                  },
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: !_saving && (_models?.isNotEmpty ?? false)
                          ? _pickModel
                          : null,
                      icon: const Icon(Icons.list),
                      label: const Text('选择模型'),
                    ),
                    TextButton.icon(
                      onPressed: !_saving && _canLoadModels
                          ? () => setState(() => _queueCatalog(refresh: true))
                          : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('刷新模型列表'),
                    ),
                  ],
                ),
                Text(_catalogStatus),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _searchApiKey,
                  enabled: !_saving,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: InputDecoration(
                    labelText: 'Brave Search API 密钥（可选）',
                    helperText: _removeSearchKey
                        ? '保存配置时移除密钥'
                        : _savedSearchKey?.isNotEmpty == true
                        ? '留空保留已保存的 Brave Search 密钥'
                        : '留空使用模型服务的联网搜索',
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
                    suffixIcon: _savedSearchKey?.isNotEmpty != true
                        ? null
                        : IconButton(
                            tooltip: _removeSearchKey
                                ? '撤销移除 Brave Search 密钥'
                                : '移除已保存的 Brave Search 密钥',
                            icon: Icon(
                              _removeSearchKey
                                  ? Icons.undo
                                  : Icons.delete_outline,
                            ),
                            onPressed: _saving
                                ? null
                                : () => setState(() {
                                    _removeSearchKey = !_removeSearchKey;
                                    if (_removeSearchKey) _searchApiKey.clear();
                                  }),
                          ),
                  ),
                  onChanged: (value) {
                    if (_removeSearchKey && value.trim().isNotEmpty) {
                      setState(() => _removeSearchKey = false);
                    }
                  },
                  validator: (value) {
                    final key = value?.trim() ?? '';
                    return key.isEmpty || _isValidKey(key)
                        ? null
                        : '请输入有效的 Brave Search API 密钥。';
                  },
                ),
                const SizedBox(height: 4),
                const Text('网页搜索默认由模型服务执行。填写 Brave 密钥后改用 Brave Search。'),
                const SizedBox(height: 16),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '正在处理…' : '保存配置'),
                ),
                if (widget.canClear)
                  TextButton(
                    onPressed: _saving ? null : _clear,
                    child: const Text('移除配置'),
                  ),
                if (widget.onClearCourseFiles != null)
                  TextButton.icon(
                    onPressed: _saving || _clearingFiles
                        ? null
                        : _clearCourseFiles,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: Text(_clearingFiles ? '正在清理…' : '清理课程文件缓存'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
