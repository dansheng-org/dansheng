// SPDX-License-Identifier: GPL-3.0-or-later

import '../campus_api.dart';
import 'agent_models.dart';

/// Dart service communicating with native CampusAgent via CampusApi.
class AgentService {
  final CampusApi api;

  const AgentService(this.api);

  /// Search local records using Rust search.query.
  Future<List<AgentHit>> search(String query, {int limit = 20}) async {
    final res = await api.call('agent.query', {
      'query': query,
      'limit': limit,
    });
    if (res is Map<String, dynamic> && res['hits'] is List) {
      return (res['hits'] as List)
          .whereType<Map<String, dynamic>>()
          .map(AgentHit.fromJson)
          .toList();
    }
    return const [];
  }

  /// Practical local evidence-based question answering.
  Future<AgentAnswer> ask(String question) async {
    final res = await api.call('agent.ask', {'question': question});
    if (res is Map<String, dynamic>) {
      return AgentAnswer.fromJson(res);
    }
    return AgentAnswer(
      question: question,
      accountId: '',
      answer: '未能获取本地证据回答。',
      sources: const [],
      evidenceCount: 0,
    );
  }

  /// Start opt-in loopback MCP HTTP server (token is not returned here).
  Future<McpServerStatus> startMcp({int? port}) async {
    final params = <String, dynamic>{};
    if (port != null && port > 0) {
      params['port'] = port;
    }
    final res = await api.call('agent.mcp.start', params);
    if (res is Map<String, dynamic>) {
      return McpServerStatus.fromJson(res);
    }
    return const McpServerStatus(running: false, port: 0);
  }

  /// Stop loopback MCP server.
  Future<McpServerStatus> stopMcp() async {
    final res = await api.call('agent.mcp.stop', const {});
    if (res is Map<String, dynamic>) {
      return McpServerStatus.fromJson(res);
    }
    return const McpServerStatus(running: false, port: 0);
  }

  /// Check loopback MCP server status and bound account (token is not returned here).
  Future<McpServerStatus> getMcpStatus() async {
    final res = await api.call('agent.mcp.status', const {});
    if (res is Map<String, dynamic>) {
      return McpServerStatus.fromJson(res);
    }
    return const McpServerStatus(running: false, port: 0);
  }

  /// Retrieve pairing bearer token ONLY upon explicit copy action.
  Future<String> getMcpToken() async {
    final res = await api.call('agent.mcp.token', const {});
    if (res is Map<String, dynamic> && res['token'] != null) {
      return res['token'].toString();
    }
    return '';
  }
}
