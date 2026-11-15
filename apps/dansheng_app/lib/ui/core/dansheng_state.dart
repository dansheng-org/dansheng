import 'dart:async';

import 'package:flutter/material.dart';

import 'dansheng_client.dart';

/// Central state coordinator for Dansheng app.
class DanshengController extends ChangeNotifier {
  final DanshengClient client;

  DanshengController({required this.client});

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  List<Map<String, dynamic>> _plugins = [];
  List<Map<String, dynamic>> get plugins => _plugins;

  String? _activeAccountId;
  String? get activeAccountId => _activeAccountId;
  int _accountGeneration = 0;
  int get accountGeneration => _accountGeneration;
  bool _isChangingAccount = false;
  bool get isChangingAccount => _isChangingAccount;

  Map<String, dynamic>? _balanceData;
  Map<String, dynamic>? get balanceData => _balanceData;

  List<Map<String, dynamic>> _jobs = [];
  List<Map<String, dynamic>> get jobs => _jobs;

  Map<String, dynamic> _permissions = {
    'exact_available': false,
    'notifications_available': false,
  };
  Map<String, dynamic> get permissions => _permissions;

  Map<String, dynamic> _info = {};
  Map<String, dynamic> get info => _info;

  int? _eventCursor;
  int? get eventCursor => _eventCursor;
  final StreamController<String> _components =
      StreamController<String>.broadcast();
  Stream<String> get componentChanges => _components.stream;
  final _navigation = StreamController<int>.broadcast();
  Stream<int> get navigation => _navigation.stream;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  double _textScale = 1.0;
  double get textScale => _textScale;

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }

  void setTextScale(double scale) {
    _textScale = scale;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Initialize and load all snapshots
  Future<void> initialize() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await refreshAll();
      _isInitialized = true;
    } catch (e) {
      _errorMessage = '初始化失败: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Full snapshot refresh
  Future<void> refreshAll() async {
    try {
      final infoFuture = client.getInfo();
      final pluginsFuture = client.getPlugins().catchError(
        (_) => <Map<String, dynamic>>[],
      );
      final accountFuture = client.getAccount().catchError((_) => null);
      final jobsFuture = client.getJobs().catchError(
        (_) => <Map<String, dynamic>>[],
      );
      final permsFuture = client.getPermissions().catchError(
        (_) => <String, dynamic>{
          'exact_available': false,
          'notifications_available': false,
        },
      );

      final results = await Future.wait([
        infoFuture,
        pluginsFuture,
        accountFuture,
        jobsFuture,
        permsFuture,
      ]);

      _info = results[0] as Map<String, dynamic>;
      _plugins = results[1] as List<Map<String, dynamic>>;
      if (_activeAccountId != results[2]) _balanceData = null;
      _activeAccountId = results[2] as String?;
      _jobs = results[3] as List<Map<String, dynamic>>;
      _permissions = results[4] as Map<String, dynamic>;

      // Loading the plugin catalog must never log in to an unrelated campus service.
    } catch (e) {
      _errorMessage = '刷新失败: $e';
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// Refresh balance for active account
  Future<void> refreshBalance() async {
    if (_activeAccountId == null || _activeAccountId!.isEmpty) {
      _balanceData = null;
      notifyListeners();
      return;
    }
    try {
      _balanceData = await client.getBalance(_activeAccountId!);
    } catch (e) {
      _balanceData = {'error': e.toString()};
    }
    notifyListeners();
  }

  /// Switch active account
  Future<void> switchAccount(String accountId) async {
    _isChangingAccount = true;
    _accountGeneration++;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await client.setAccount(accountId);
      _balanceData = null;
      await refreshAll();
    } catch (e) {
      _errorMessage = '切换账号失败: $e';
      rethrow;
    } finally {
      _isChangingAccount = false;
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Incremental events polling
  Future<void> pollIncrementalEvents() async {
    try {
      final res = await client.pollEvents(after: _eventCursor);
      final resyncRequired = res['resync_required'] == true;
      if (res['open_tasks'] == true) _navigation.add(1);
      if (resyncRequired) {
        _eventCursor = res['cursor'] as int?;
        await refreshAll();
        _components.add('*');
        return;
      }

      if (res.containsKey('cursor') && res['cursor'] is int) {
        _eventCursor = res['cursor'] as int;
      }

      final eventsList = res['events'];
      if (eventsList is List && eventsList.isNotEmpty) {
        for (final evt in eventsList) {
          if (evt is Map) {
            if (evt['kind'] == 'ui_changed') {
              _components.add('${evt['principal']}:${evt['id']}');
            }
            final seq = evt['sequence'] ?? evt['seq'];
            if (seq is int && (_eventCursor == null || seq > _eventCursor!)) {
              _eventCursor = seq;
            }
          }
        }
        // Background jobs or plugins may have changed
        final jobs = await client.getJobs().catchError((_) => _jobs);
        _jobs = jobs;
        notifyListeners();
      }
    } catch (e) {
      // Incremental poll failure shouldn't crash UI, but log or fallback to full refresh on next action
    }
  }

  @override
  void dispose() {
    _components.close();
    _navigation.close();
    super.dispose();
  }

  /// Import external package (.dspack) - empty payload opens native SAF document picker
  Future<void> importPackage([String? packagePath]) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await client.importPackage(packagePath);
      _plugins = await client.getPlugins();
    } catch (e) {
      _errorMessage = '导入插件失败: $e';
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Enable plugin
  Future<void> enablePlugin(String pluginId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await client.enablePlugin(pluginId);
      _plugins = await client.getPlugins();
    } catch (e) {
      _errorMessage = '启用插件失败: $e';
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Disable plugin
  Future<void> disablePlugin(String pluginId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await client.disablePlugin(pluginId);
      _plugins = await client.getPlugins();
    } catch (e) {
      _errorMessage = '停用插件失败: $e';
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Remove plugin
  Future<void> removePlugin(String pluginId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await client.removePlugin(pluginId);
      _plugins = await client.getPlugins();
    } catch (e) {
      _errorMessage = '卸载插件失败: $e';
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Refresh system permissions
  Future<void> refreshPermissions() async {
    try {
      _permissions = await client.getPermissions();
      notifyListeners();
    } catch (_) {}
  }

  /// Open exact alarm settings
  Future<void> openAlarmSettings() async {
    await client.openAlarmSettings();
    await refreshPermissions();
  }

  /// Request runtime notifications
  Future<void> requestNotifications() async {
    await client.requestNotifications();
    await refreshPermissions();
  }
}
