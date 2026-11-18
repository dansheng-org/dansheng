// SPDX-License-Identifier: GPL-3.0-or-later

import '../../../agent/agent_types.dart';
import '../../core/dansheng_client.dart';
import '../campus_api.dart';

class AgentSettingsStore {
  AgentSettingsStore(DanshengClient client) : _api = CampusApi(client);

  final CampusApi _api;

  Future<AgentModelConfig?> load() async {
    final result = await _api.call('agent.settings.get');
    if (result == null) return null;
    if (result is! Json ||
        result['provider'] is! String ||
        result['base_url'] is! String ||
        result['model'] is! String ||
        result['api_key'] is! String ||
        (result['model_label'] != null && result['model_label'] is! String) ||
        (result['search_api_key'] != null &&
            result['search_api_key'] is! String)) {
      throw const AgentFailure('无法读取模型配置，请重置后重新配置。');
    }
    final provider = switch (result['provider']) {
      'openAi' => ModelProvider.openAi,
      'anthropic' => ModelProvider.anthropic,
      _ => throw const AgentFailure('模型配置的协议不受支持。'),
    };
    return AgentModelConfig(
      provider: provider,
      baseUrl: AgentModelConfig.parseBaseUrl(result['base_url'] as String),
      model: result['model'] as String,
      modelLabel: result['model_label'] as String?,
      apiKey: result['api_key'] as String,
      searchApiKey: result['search_api_key'] as String?,
    );
  }

  Future<void> save(AgentModelConfig config) async {
    await _api.call('agent.settings.set', {
      'provider': config.provider.name,
      'base_url': config.baseUrl.toString(),
      'model': config.model,
      if (config.modelLabel case final String name) 'model_label': name,
      'api_key': config.apiKey,
      if (config.searchApiKey case final String key) 'search_api_key': key,
    });
  }

  Future<void> clear() async {
    await _api.call('agent.settings.clear');
  }
}
