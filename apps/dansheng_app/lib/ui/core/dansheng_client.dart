import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:flutter/services.dart';

/// Abstract contract for Dansheng API bridge to allow both production
/// Pigeon calls and test mocks.
abstract class DanshengBridge {
  Future<String> invoke(HostCommand command, String payload);
}

/// Production implementation using generated Pigeon DanshengApi.
class PigeonDanshengBridge implements DanshengBridge {
  final DanshengApi _api;

  PigeonDanshengBridge({DanshengApi? api}) : _api = api ?? DanshengApi();

  @override
  Future<String> invoke(HostCommand command, String payload) {
    return _api.invoke(command, payload);
  }
}

/// Typed client for Dansheng host operations.
class DanshengClient {
  final DanshengBridge bridge;

  DanshengClient({DanshengBridge? bridge})
    : bridge = bridge ?? PigeonDanshengBridge();

  Future<dynamic> _invoke(
    HostCommand cmd, [
    Map<String, dynamic>? params,
  ]) async {
    final payload = jsonEncode(params ?? <String, dynamic>{});
    try {
      final res = await bridge.invoke(cmd, payload);
      if (res.isEmpty) return null;
      return jsonDecode(res);
    } on PlatformException {
      rethrow;
    } catch (e) {
      throw PlatformException(
        code: 'PARSE_ERROR',
        message: 'Failed to decode host response: $e',
      );
    }
  }

  /// Read core/engine info
  Future<Map<String, dynamic>> getInfo() async {
    final res = await _invoke(HostCommand.info);
    if (res is Map<String, dynamic>) return res;
    return <String, dynamic>{'raw': res};
  }

  /// List installed plugins
  Future<List<Map<String, dynamic>>> getPlugins() async {
    final res = await _invoke(HostCommand.plugins);
    if (res is List) {
      return res.whereType<Map<String, dynamic>>().toList();
    }
    if (res is Map && res['plugins'] is List) {
      return (res['plugins'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  /// Import external .dspack package.
  /// If packagePath is omitted or null, payload is `{}` which triggers native Android document picker.
  Future<Map<String, dynamic>> importPackage([String? packagePath]) async {
    final params = (packagePath != null && packagePath.isNotEmpty)
        ? {'path': packagePath, 'package_path': packagePath}
        : <String, dynamic>{};
    final res = await _invoke(HostCommand.importPackage, params);
    if (res is Map<String, dynamic>) return res;
    return <String, dynamic>{'result': res};
  }

  /// Enable a plugin
  Future<void> enablePlugin(String pluginId) async {
    await _invoke(HostCommand.enablePlugin, {'plugin_id': pluginId});
  }

  /// Disable a plugin
  Future<void> disablePlugin(String pluginId) async {
    await _invoke(HostCommand.disablePlugin, {'plugin_id': pluginId});
  }

  /// Remove a plugin
  Future<void> removePlugin(String pluginId) async {
    await _invoke(HostCommand.removePlugin, {'plugin_id': pluginId});
  }

  /// Get published or static UI component by ID
  Future<Map<String, dynamic>> getComponent(
    String pluginId,
    String componentId,
  ) async {
    final res = await _invoke(HostCommand.component, {
      'plugin_id': pluginId,
      'id': componentId,
    });
    if (res is Map<String, dynamic>) return res;
    return <String, dynamic>{'component': res};
  }

  /// Preview a mutating action before review confirmation
  Future<Map<String, dynamic>> previewAction({
    required String pluginId,
    required String action,
    required Map<String, dynamic> input,
  }) async {
    // Ensure caller never inserts approved
    final sanitizedInput = Map<String, dynamic>.from(input)..remove('approved');
    final res = await _invoke(HostCommand.preview, {
      'plugin_id': pluginId,
      'action': action,
      'input': sanitizedInput,
    });
    if (res is Map<String, dynamic>) return res;
    return <String, dynamic>{'preview': res};
  }

  /// Execute an action
  Future<dynamic> runAction({
    required String pluginId,
    required String action,
    required Map<String, dynamic> input,
    String? inputSha256,
  }) async {
    // Ensure caller never inserts approved
    final sanitizedInput = Map<String, dynamic>.from(input)..remove('approved');
    final params = <String, dynamic>{
      'plugin_id': pluginId,
      'action': action,
      'input': sanitizedInput,
    };
    if (inputSha256 != null && inputSha256.isNotEmpty) {
      params['input_sha256'] = inputSha256;
    }
    return await _invoke(HostCommand.runAction, params);
  }

  /// Get core jobs array
  Future<List<Map<String, dynamic>>> getJobs() async {
    final res = await _invoke(HostCommand.jobs);
    if (res is List) {
      return res.whereType<Map<String, dynamic>>().toList();
    }
    if (res is Map && res['jobs'] is List) {
      return (res['jobs'] as List).whereType<Map<String, dynamic>>().toList();
    }
    return <Map<String, dynamic>>[];
  }

  /// Poll events incrementally with sequence cursor
  Future<Map<String, dynamic>> pollEvents({int? after}) async {
    final params = <String, dynamic>{};
    if (after != null) {
      params['after'] = after;
    }
    final res = await _invoke(HostCommand.events, params);
    if (res is Map<String, dynamic>) return res;
    if (res is List) {
      return <String, dynamic>{'events': res};
    }
    return <String, dynamic>{};
  }

  /// Get active account
  Future<String?> getAccount() async {
    final res = await _invoke(HostCommand.account);
    if (res is Map && res['account_id'] != null) {
      return res['account_id'].toString();
    }
    if (res is String && res.isNotEmpty) return res;
    return null;
  }

  /// Switch or set active account
  Future<void> setAccount(String accountId) async {
    await _invoke(HostCommand.setAccount, {'account_id': accountId});
  }

  /// Check system permissions (exact alarm, notifications)
  Future<Map<String, dynamic>> getPermissions() async {
    final res = await _invoke(HostCommand.permissions);
    if (res is Map<String, dynamic>) return res;
    return <String, dynamic>{
      'exact_available': false,
      'notifications_available': false,
    };
  }

  /// Open system exact alarm settings
  Future<void> openAlarmSettings() async {
    await _invoke(HostCommand.openAlarmSettings);
  }

  /// Request runtime notifications permission
  Future<void> requestNotifications() async {
    await _invoke(HostCommand.requestNotifications);
  }

  /// Get card balance for active account
  Future<Map<String, dynamic>> getBalance(String accountId) async {
    final res = await _invoke(HostCommand.balance, {'account_id': accountId});
    if (res is Map<String, dynamic>) return res;
    return <String, dynamic>{'balance': res};
  }
}
