import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../../screens/account_balance_screen.dart';
import '../../screens/settings_screen.dart';
import '../campus_api.dart';
import '../venues/venue_models.dart';
import '../venues/venue_page.dart';
import 'campus_building.dart';
import 'life_page.dart';

/// State tracking for user-triggered inline metrics
class _ServiceMetricState {
  dynamic data;
  String? error;
  bool loading = false;
  bool fetchedByUser = false;
}

/// Modern Chinese campus workbench for eHall home and campus life services.
/// Integrates prominent daily utility metrics, user-triggered sports venue snapshot,
/// grouped life & academic services, and a concise sandbox mail shell.
class EHallPage extends StatefulWidget {
  const EHallPage({super.key, required this.controller});
  final DanshengController controller;

  @override
  State<EHallPage> createState() => _EHallPageState();
}

class _EHallPageState extends State<EHallPage> {
  late final CampusApi _api;
  DanshengController get controller => widget.controller;

  String? _lastAccountId;
  int _venueRequestToken = 0;
  int _cacheRequestToken = 0;
  int _powerRequestToken = 0;
  int _roomsRequestToken = 0;
  bool _roomsLoading = false;
  String? _roomsFetchedDate, _roomsMetric, _roomsError;
  int _libraryRequestToken = 0;
  int _diningRequestToken = 0;

  // Cached campus snapshot data (retrieved offline without hidden network calls)
  Map<String, dynamic>? _cachedPower;
  int? _cachedRoomCount;

  // Per-account metric states
  final Map<String, _ServiceMetricState> _powerStates = {};
  final Map<String, _ServiceMetricState> _libraryStates = {};
  final Map<String, _ServiceMetricState> _diningStates = {};

  _ServiceMetricState _getPowerState(String account) =>
      _powerStates.putIfAbsent(account, () => _ServiceMetricState());
  _ServiceMetricState _getLibraryState(String account) =>
      _libraryStates.putIfAbsent(account, () => _ServiceMetricState());
  _ServiceMetricState _getDiningState(String account) =>
      _diningStates.putIfAbsent(account, () => _ServiceMetricState());

  // Inline venue snapshot state (strictly user-triggered; NO background network on open)
  bool _venueQueried = false;
  bool _venueLoading = false;
  String? _venueError;
  bool _venueAuthRequired = false;
  List<CampusVenue> _venues = [];
  CampusVenue? _selectedVenue;
  final DateTime _venueDate = DateTime.now();
  List<VenueSlot> _venueSlots = [];

  @override
  void initState() {
    super.initState();
    _api = CampusApi(controller.client);
    _lastAccountId = controller.activeAccountId;
    controller.addListener(_onControllerUpdate);
    _loadOfflineCaches();
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    final currentAccount = controller.activeAccountId;
    if (currentAccount != _lastAccountId) {
      _lastAccountId = currentAccount;
      // Drop stale async results immediately on account switch
      _venueRequestToken++;
      _cacheRequestToken++;
      _powerRequestToken++;
      _roomsRequestToken++;
      _libraryRequestToken++;
      _diningRequestToken++;

      if (mounted) {
        setState(() {
          _cachedPower = null;
          _cachedRoomCount = null;
          _roomsLoading = false;
          _roomsFetchedDate = null;
          _roomsMetric = null;
          _roomsError = null;
          _venues = [];
          _selectedVenue = null;
          _venueSlots = [];
          _venueQueried = false;
          _venueLoading = false;
          _venueError = null;
          _venueAuthRequired = false;
        });
      }
      _loadOfflineCaches();
    } else {
      if (mounted) {
        setState(() {});
      }
    }
  }

  /// Reads local cached snapshots for room and power if available.
  /// Never makes outbound network calls during startup.
  /// Room cache query is explicitly keyed by building and date matching native cache keys.
  Future<void> _loadOfflineCaches() async {
    final token = ++_cacheRequestToken;
    final account = controller.activeAccountId;
    if (account == null || account.isEmpty) {
      if (mounted) {
        setState(() {
          _cachedPower = null;
          _cachedRoomCount = null;
        });
      }
      return;
    }

    try {
      final power = await _api.call('campus.cached', {
        'method': 'fudan.electricity',
      });
      if (!mounted ||
          token != _cacheRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      if (power is Map) {
        final p = power['payload'] is Map ? (power['payload'] as Map) : power;
        setState(() {
          _cachedPower = Map<String, dynamic>.from(p);
        });
      }
    } catch (_) {}

    try {
      final now = DateTime.now().toUtc().add(const Duration(hours: 8));
      final todayStr = _formatDate(now);
      const defaultBuilding = CampusBuildings.defaultBuildingCode;

      final rooms = await _api.call('campus.cached', {
        'method': 'fudan.rooms',
        'building': defaultBuilding,
        'date': todayStr,
      });
      if (!mounted ||
          token != _cacheRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      final cached = rooms == null ? const [] : RoomDataParser.parse(rooms);
      if (cached.isNotEmpty) {
        setState(() => _cachedRoomCount = cached.length);
      }
    } catch (_) {}
  }

  String _formatDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  bool _is2FAError(Object error) {
    final str = error.toString().toLowerCase();
    return str.contains('2fa') ||
        str.contains('twofactor') ||
        str.contains('two_factor') ||
        str.contains('enhancedauth') ||
        str.contains('enhanced_auth') ||
        str.contains('interactiveloginrequired');
  }

  bool _isAuthError(Object error) {
    final str = error.toString();
    return str.contains('AuthenticationRequired') ||
        str.contains('NotLoginError') ||
        str.contains('InvalidCredentials') ||
        str.contains('AccountRequired') ||
        str.contains('401') ||
        str.contains('postgraduates_need_login') ||
        _is2FAError(error);
  }

  Future<void> _onTapRooms() async {
    final account = controller.activeAccountId;
    if (account == null || account.isEmpty) {
      _openAccount();
      return;
    }
    if (_roomsLoading) return;
    final now = campusRoomNow();
    final day = now.toIso8601String().substring(0, 10);
    const building = CampusBuildings.defaultBuildingCode;
    if (_roomsFetchedDate == day) {
      _openPage(
        LifePage(
          service: LifeService.rooms,
          controller: controller,
          initialBuilding: building,
          initialDate: now,
        ),
      );
      return;
    }
    final ticket = ++_roomsRequestToken;
    setState(() {
      _roomsLoading = true;
      _roomsError = null;
    });
    try {
      final raw = await _api.call('fudan.rooms', {
        'building': building,
        'date': day,
      });
      final rooms = RoomDataParser.parse(raw);
      if (!mounted ||
          ticket != _roomsRequestToken ||
          controller.activeAccountId != account) {
        return;
      }
      setState(() {
        _roomsLoading = false;
        _roomsFetchedDate = day;
        _roomsMetric = rooms.isEmpty ? '暂无教室记录' : '${rooms.length} 间教室';
      });
    } catch (e) {
      if (!mounted ||
          ticket != _roomsRequestToken ||
          controller.activeAccountId != account) {
        return;
      }
      setState(() {
        _roomsLoading = false;
        _roomsError = campusError(e);
      });
      if (_isAuthError(e)) {
        _openPage(
          LifePage(
            service: LifeService.rooms,
            controller: controller,
            initialBuilding: building,
            initialDate: now,
          ),
        );
      }
    }
  }

  void _handleAuthError(Object error, LifeService service) {
    if ((_is2FAError(error) || service == LifeService.dining) &&
        _isAuthError(error)) {
      _openPage(LifePage(service: service, controller: controller));
    } else if (_isAuthError(error)) {
      _openAccount();
    }
  }

  Future<void> _onTapPower() async {
    final account = controller.activeAccountId;
    if (account == null || account.isEmpty) {
      _openAccount();
      return;
    }

    final state = _getPowerState(account);

    if (state.loading) return;

    if (state.fetchedByUser && state.error == null) {
      _openPage(LifePage(service: LifeService.power, controller: controller));
      return;
    }

    final token = ++_powerRequestToken;
    setState(() {
      state.loading = true;
      state.error = null;
    });

    try {
      final res = await _api.call('fudan.electricity');
      if (!mounted ||
          token != _powerRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      Map<String, dynamic>? powerMap;
      if (res is Map) {
        final p = res['payload'] is Map ? (res['payload'] as Map) : res;
        powerMap = Map<String, dynamic>.from(p);
      }
      setState(() {
        state.loading = false;
        state.data = powerMap;
        state.fetchedByUser = true;
        state.error = null;
      });
    } catch (e) {
      if (!mounted ||
          token != _powerRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      setState(() {
        state.loading = false;
        state.fetchedByUser = false;
        state.error = campusError(e);
      });
      _handleAuthError(e, LifeService.power);
    }
  }

  Future<void> _onTapLibrary() async {
    final account = controller.activeAccountId;
    if (account == null || account.isEmpty) {
      _openAccount();
      return;
    }

    final state = _getLibraryState(account);

    if (state.loading) return;

    if (state.fetchedByUser && state.error == null) {
      _openPage(LifePage(service: LifeService.library, controller: controller));
      return;
    }

    final token = ++_libraryRequestToken;
    setState(() {
      state.loading = true;
      state.error = null;
    });

    try {
      final res = await _api.call('fudan.library.occupancy');
      if (!mounted ||
          token != _libraryRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      setState(() {
        state.loading = false;
        state.data = res;
        state.fetchedByUser = true;
        state.error = null;
      });
    } catch (e) {
      if (!mounted ||
          token != _libraryRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      setState(() {
        state.loading = false;
        state.fetchedByUser = false;
        state.error = campusError(e);
      });
      _handleAuthError(e, LifeService.library);
    }
  }

  Future<void> _onTapDining() async {
    final account = controller.activeAccountId;
    if (account == null || account.isEmpty) {
      _openAccount();
      return;
    }

    final state = _getDiningState(account);

    if (state.loading) return;

    if (state.fetchedByUser && state.error == null) {
      _openPage(LifePage(service: LifeService.dining, controller: controller));
      return;
    }

    final token = ++_diningRequestToken;
    setState(() {
      state.loading = true;
      state.error = null;
    });

    try {
      final res = await _api.call('fudan.dining.occupancy');
      if (!mounted ||
          token != _diningRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      setState(() {
        state.loading = false;
        state.data = res;
        state.fetchedByUser = true;
        state.error = null;
      });
    } catch (e) {
      if (!mounted ||
          token != _diningRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      setState(() {
        state.loading = false;
        state.fetchedByUser = false;
        state.error = campusError(e);
      });
      _handleAuthError(e, LifeService.dining);
    }
  }

  List<Map<String, dynamic>> _extractItems(dynamic data, String key) {
    if (data is List) {
      return data.expand((row) => _extractItems(row, key)).toList();
    }
    if (data is! Map) return [];
    for (final wrapper in [key, 'records', 'data', 'list', 'payload']) {
      final value = data[wrapper];
      if (value is List || value is Map) return _extractItems(value, key);
    }
    return [Map<String, dynamic>.from(data)];
  }

  String _formatLibraryMetric(dynamic data) {
    List<Map<String, dynamic>> items = _extractItems(data, 'libraries');
    if (items.isEmpty && data is List) {
      items = data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    if (items.isNotEmpty) {
      final parts = <String>[];
      for (final item in items) {
        final campus = item['campus'] ?? item['name'] ?? '馆舍';
        final inside = item['inside'] ?? item['used'] ?? item['current'];
        if (inside != null) {
          parts.add('$campus $inside人');
        }
      }
      if (parts.isNotEmpty) return parts.join(' · ');
    }
    return '已获取在馆人数';
  }

  String _formatDiningMetric(dynamic data) {
    List<Map<String, dynamic>> items = _extractItems(data, 'dining_halls');
    if (items.isEmpty && data is List) {
      items = data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    if (items.isNotEmpty) {
      final parts = <String>[];
      for (final item in items) {
        final name = item['name'] ?? '餐厅';
        final current = item['current'] ?? item['inside'] ?? item['used'];
        if (current != null) {
          parts.add('$name $current人');
        }
      }
      if (parts.isNotEmpty) return parts.join(' · ');
    }
    return '已获取就餐人数';
  }

  /// User-triggered venue availability query.
  /// In-flight requests are bound to current account and cancelled if account switches.
  Future<void> _refreshVenueSnapshot({bool triggerLogin = false}) async {
    final token = ++_venueRequestToken;
    final account = controller.activeAccountId;

    if (account == null || account.isEmpty) {
      setState(() {
        _venueQueried = true;
        _venueError = '未设置账号，请先绑定复旦统一身份认证账号';
        _venueAuthRequired = false;
        _venueLoading = false;
      });
      return;
    }

    setState(() {
      _venueQueried = true;
      _venueLoading = true;
      _venueError = null;
      _venueAuthRequired = false;
    });

    try {
      if (triggerLogin) {
        await _api.call('venues.visibleLogin');
        if (!mounted ||
            token != _venueRequestToken ||
            account != controller.activeAccountId) {
          return;
        }
      }

      // Always reload venues list on login recovery or when empty
      if (_venues.isEmpty || triggerLogin) {
        final res = await _api.call('venues.venues');
        if (!mounted ||
            token != _venueRequestToken ||
            account != controller.activeAccountId) {
          return;
        }
        if (res is List) {
          _venues = res
              .whereType<Map<String, dynamic>>()
              .map((e) => CampusVenue.fromJson(e))
              .toList();
        }
        if (_venues.isNotEmpty) {
          _selectedVenue = _venues.first;
        }
      }

      if (_selectedVenue != null) {
        final dateStr = _formatDate(_venueDate);
        final calRes = await _api.call('venues.calendar', {
          'venue_id': _selectedVenue!.id,
          'target_date': dateStr,
        });
        if (!mounted ||
            token != _venueRequestToken ||
            account != controller.activeAccountId) {
          return;
        }

        if (calRes is Map && calRes['slots'] is List) {
          _venueSlots = (calRes['slots'] as List)
              .whereType<Map<String, dynamic>>()
              .map((s) => VenueSlot.fromJson(s))
              .toList();
        } else if (calRes is List) {
          _venueSlots = calRes
              .whereType<Map<String, dynamic>>()
              .map((s) => VenueSlot.fromJson(s))
              .toList();
        } else {
          _venueSlots = [];
        }
      }
    } catch (e) {
      if (!mounted ||
          token != _venueRequestToken ||
          account != controller.activeAccountId) {
        return;
      }
      final errStr = e.toString();
      // Cancelling or mistyping in the login sheet still leaves the login button.
      final loginIncomplete =
          triggerLogin &&
          (errStr.contains('InvalidCredentials') ||
              errStr.contains('Cancelled'));
      if (errStr.contains('AuthenticationRequired') ||
          errStr.contains('NotLoginError') ||
          errStr.contains('401') ||
          loginIncomplete) {
        _venueAuthRequired = true;
        _venueError = errStr.contains('InvalidCredentials')
            ? campusError(e)
            : '需要登录校园服务';
      } else {
        _venueError = campusError(e);
      }
    } finally {
      if (mounted &&
          token == _venueRequestToken &&
          account == controller.activeAccountId) {
        setState(() => _venueLoading = false);
      }
    }
  }

  void _openPage(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  void _openAccount() {
    _openPage(AccountBalanceScreen(controller: controller));
  }

  void _drillToVenues() {
    _openPage(
      VenuePage(
        controller: controller,
        initialVenueId: _selectedVenue?.id,
        initialDate: _venueDate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final hasAccount =
        controller.activeAccountId != null &&
        controller.activeAccountId!.isNotEmpty;

    final hasSchedulerPlugin = controller.plugins.any((p) {
      final pid = (p['id'] ?? p['plugin_id'] ?? '').toString();
      final isSports = pid.contains('sports') || pid.contains('venue');
      final enabled = p['enabled'] == true;
      return isSports && enabled;
    });

    final libraryState = hasAccount
        ? _getLibraryState(controller.activeAccountId!)
        : null;
    final diningState = hasAccount
        ? _getDiningState(controller.activeAccountId!)
        : null;

    String librarySub;
    if (!hasAccount) {
      librarySub = '未绑定账号';
    } else if (libraryState?.loading == true) {
      librarySub = '正在查询在馆人数...';
    } else if (libraryState?.error != null) {
      librarySub = '${libraryState!.error!} · 点击重试';
    } else if (libraryState?.fetchedByUser == true &&
        libraryState?.data != null) {
      librarySub = _formatLibraryMetric(libraryState!.data);
    } else {
      librarySub = '各馆舍在馆人数与实时负载';
    }

    String diningSub;
    if (!hasAccount) {
      diningSub = '未绑定账号';
    } else if (diningState?.loading == true) {
      diningSub = '正在查询就餐人数...';
    } else if (diningState?.error != null) {
      diningSub = '${diningState!.error!} · 点击重试';
    } else if (diningState?.fetchedByUser == true &&
        diningState?.data != null) {
      diningSub = _formatDiningMetric(diningState!.data);
    } else {
      diningSub = '各校区餐厅实时就餐人数与容量';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('eHall'),
        actions: [
          IconButton(
            tooltip: '账号与校园卡',
            onPressed: _openAccount,
            icon: const Icon(Icons.account_circle_outlined),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => _openPage(SettingsScreen(controller: controller)),
            icon: const Icon(Icons.tune_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          // Header Date & Title
          Text(
            '${now.month}月${now.day}日 · 星期${"一二三四五六日"[now.weekday - 1]}',
            style: textTheme.labelLarge?.copyWith(
              color: colors.primary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text('校园办事', style: textTheme.headlineLarge),
          const SizedBox(height: 18),

          // Prominent Card 1: 校园卡 (E-card Balance Hero Card with Transactions Entry)
          _buildCardBalanceCard(colors, textTheme, hasAccount),
          const SizedBox(height: 14),

          // Prominent Cards 2 & 3: 教室空位 & 寝室电量
          _buildQuickMetricsRow(colors, textTheme, hasAccount),
          const SizedBox(height: 18),

          // Prominent Inline Sports Venue Reservation Snapshot Card
          _buildVenueSnapshotCard(
            colors,
            textTheme,
            hasAccount,
            hasSchedulerPlugin,
          ),
          const SizedBox(height: 26),

          // Section 1: 生活与出行
          _buildServiceSection(
            title: '生活与出行',
            textTheme: textTheme,
            colors: colors,
            items: [
              _ServiceItem(
                service: LifeService.library,
                title: '图书馆客流',
                subtitle: librarySub,
                loading: libraryState?.loading == true,
                onTap: _onTapLibrary,
              ),
              _ServiceItem(
                service: LifeService.dining,
                title: '食堂实时客流',
                subtitle: diningSub,
                loading: diningState?.loading == true,
                onTap: _onTapDining,
              ),
              _ServiceItem(
                service: LifeService.bus,
                title: '校车班次时刻',
                subtitle: '校区通勤班车工作日与节假日班次',
                onTap: () => _openPage(
                  LifePage(service: LifeService.bus, controller: controller),
                ),
              ),
            ],
            extraItem: _buildMailShellTile(colors, textTheme),
          ),
          const SizedBox(height: 24),

          // Section 2: 教务查询
          _buildServiceSection(
            title: '教务查询',
            textTheme: textTheme,
            colors: colors,
            items: [
              _ServiceItem(
                service: LifeService.notices,
                title: '教务公告',
                subtitle: '教务处与研究生院最新通知',
                onTap: () => _openPage(
                  LifePage(
                    service: LifeService.notices,
                    controller: controller,
                  ),
                ),
              ),
              _ServiceItem(
                service: LifeService.grades,
                title: '课程成绩',
                subtitle: '学期已出成绩与等第',
                onTap: () => _openPage(
                  LifePage(service: LifeService.grades, controller: controller),
                ),
              ),
              _ServiceItem(
                service: LifeService.gpa,
                title: '学分与绩点',
                subtitle: '学业总绩点、所获学分及排名',
                onTap: () => _openPage(
                  LifePage(service: LifeService.gpa, controller: controller),
                ),
              ),
              _ServiceItem(
                service: LifeService.exams,
                title: '考试安排',
                subtitle: '期末与期中考场、时间与座位',
                onTap: () => _openPage(
                  LifePage(service: LifeService.exams, controller: controller),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Prominent Card: 校园卡 (Hero Card)
  /// Tapping card navigates to LifePage.transactions directly; refresh icon reads balance.
  Widget _buildCardBalanceCard(
    ColorScheme colors,
    TextTheme textTheme,
    bool hasAccount,
  ) {
    final balance = controller.balanceData?['balance'];
    final holder = controller.balanceData?['holder_name'];
    final updatedAt = controller.balanceData?['updated_at'];

    String primaryValue;
    String statusSubtitle;

    if (!hasAccount) {
      primaryValue = '设置账号';
      statusSubtitle = '绑定复旦学号后查看实时卡内余额';
    } else if (balance != null) {
      primaryValue = '¥ $balance';
      if (holder != null && holder.toString().isNotEmpty) {
        statusSubtitle = '$holder · 点击查看消费明细';
      } else if (updatedAt != null) {
        statusSubtitle = '已读取余额 · 点击查看明细';
      } else {
        statusSubtitle = '点击进入卡包消费明细';
      }
    } else {
      primaryValue = '查看明细';
      statusSubtitle = '右上角可刷新余额';
    }

    return Material(
      color: colors.primary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openPage(
          LifePage(service: LifeService.transactions, controller: controller),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.credit_card_outlined,
                    color: colors.onPrimary,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '校园卡',
                    style: textTheme.titleMedium?.copyWith(
                      color: colors.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  if (hasAccount)
                    IconButton(
                      tooltip: '刷新余额',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        Icons.refresh,
                        color: colors.onPrimary.withValues(alpha: 0.85),
                        size: 20,
                      ),
                      onPressed: () => controller.refreshBalance(),
                    ),
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_forward, color: colors.onPrimary, size: 20),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                primaryValue,
                style: textTheme.headlineSmall?.copyWith(
                  color: colors.onPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                statusSubtitle,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onPrimary.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Prominent Metric Cards: 教室空位 & 寝室电量
  Widget _buildQuickMetricsRow(
    ColorScheme colors,
    TextTheme textTheme,
    bool hasAccount,
  ) {
    return LayoutBuilder(
      builder: (ctx, box) {
        // Room capacity card data
        String roomsValue;
        if (!hasAccount) {
          roomsValue = '待设置账号';
        } else if (_roomsLoading) {
          roomsValue = '查询中';
        } else if (_roomsError != null) {
          roomsValue = '点击重试';
        } else if (_roomsMetric != null) {
          roomsValue = _roomsMetric!;
        } else if (_cachedRoomCount != null) {
          roomsValue = '$_cachedRoomCount 间教室';
        } else {
          roomsValue = '查空位节次';
        }

        // Dorm power card data: per-account state and offline cached support
        final powerState = hasAccount
            ? _getPowerState(controller.activeAccountId!)
            : null;

        String powerValue;
        String powerSub;
        if (!hasAccount) {
          powerValue = '待设置账号';
          powerSub = '未绑定宿舍';
        } else if (powerState?.loading == true) {
          final p = powerState?.data ?? _cachedPower;
          final kwh = p != null
              ? (p is Map
                    ? (p['payload'] is Map
                          ? p['payload']['remaining_kwh'] ??
                                p['payload']['balance']
                          : p['remaining_kwh'] ?? p['balance'])
                    : null)
              : null;
          powerValue = kwh != null ? '$kwh kWh' : '读取中...';
          powerSub = '正在查询最新电量...';
        } else if (powerState?.error != null) {
          powerValue = '读取失败';
          powerSub = '${powerState!.error!} · 点击重试';
        } else if (powerState?.fetchedByUser == true &&
            powerState?.data != null) {
          final p = powerState!.data is Map
              ? (powerState.data['payload'] is Map
                    ? powerState.data['payload'] as Map
                    : powerState.data as Map)
              : <String, dynamic>{};
          final kwh = p['remaining_kwh'] ?? p['balance'];
          final unit = p['unit'] ?? 'kWh';
          powerValue = kwh != null ? '$kwh $unit' : '— kWh';
          final bldg = p['building'] ?? p['room'] ?? '寝室电量';
          powerSub = '$bldg · 剩余电量';
        } else if (_cachedPower != null) {
          final p = _cachedPower!['payload'] is Map
              ? (_cachedPower!['payload'] as Map)
              : _cachedPower!;
          final kwh = p['remaining_kwh'] ?? p['balance'];
          final unit = p['unit'] ?? 'kWh';
          powerValue = '$kwh $unit';
          final bldg = p['building'] ?? p['room'] ?? '寝室电量';
          powerSub = '$bldg · 剩余电量';
        } else {
          powerValue = '读取余量';
          powerSub = '宿舍用电与余额';
        }

        final roomsCard = Material(
          color: colors.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _onTapRooms,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.meeting_room_outlined,
                        color: colors.primary,
                        size: 22,
                      ),
                      const Spacer(),
                      Icon(
                        Icons.chevron_right,
                        color: colors.onSurface.withValues(alpha: 0.4),
                        size: 18,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '教室空位',
                    style: textTheme.labelLarge?.copyWith(
                      color: colors.onSurface.withValues(alpha: 0.75),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    roomsValue,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // The reason is the only way to tell why a retry is needed.
                  if (_roomsError != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      _roomsError!,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.onSurface.withValues(alpha: 0.6),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );

        final powerCard = Material(
          color: colors.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _onTapPower,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.bolt_outlined,
                        color: colors.primary,
                        size: 22,
                      ),
                      const Spacer(),
                      if (powerState?.loading == true)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(
                          Icons.chevron_right,
                          color: colors.onSurface.withValues(alpha: 0.4),
                          size: 18,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '寝室电量',
                    style: textTheme.labelLarge?.copyWith(
                      color: colors.onSurface.withValues(alpha: 0.75),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    powerValue,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    powerSub,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.onSurface.withValues(alpha: 0.6),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        );

        if (box.maxWidth < 280) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [roomsCard, const SizedBox(height: 12), powerCard],
          );
        }
        // The rooms card has fewer lines; keep the pair the same height.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: roomsCard),
              const SizedBox(width: 12),
              Expanded(child: powerCard),
            ],
          ),
        );
      },
    );
  }

  /// Compact Inline Sports Venue Reservation Snapshot Card.
  /// Shows concise '选场馆、看空位、预约' or actual venue name, without hardcoded venue lists.
  /// Uses concise '可定时' badge when plugin enabled.
  Widget _buildVenueSnapshotCard(
    ColorScheme colors,
    TextTheme textTheme,
    bool hasAccount,
    bool hasSchedulerPlugin,
  ) {
    final venueSubtitle = _selectedVenue != null
        ? _selectedVenue!.name
        : '选场馆、看空位、预约';

    return Card(
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Card Header: concise labels, no hardcoded venue enumeration
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colors.tertiaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.sports_tennis,
                    color: colors.onTertiaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '场馆预约',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (hasSchedulerPlugin) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colors.primaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '可定时',
                                style: textTheme.labelSmall?.copyWith(
                                  color: colors.onPrimaryContainer,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        venueSubtitle,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.onSurface.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh),
                  onPressed: _venueLoading
                      ? null
                      : () => _refreshVenueSnapshot(),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Card Body Content States: clean and unstacked
            if (!_venueQueried) ...[
              // State 1: Clean unqueried prompt on initial open
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _refreshVenueSnapshot(),
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('查询今日空位'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _drillToVenues,
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text('预约中心'),
                  ),
                ],
              ),
            ] else if (_venueLoading) ...[
              // State 2: Loading
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    LinearProgressIndicator(),
                    SizedBox(height: 6),
                    Text('正在查询可用时段...', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ] else if (!hasAccount) ...[
              // State 3: Distinct No Account State
              Row(
                children: [
                  Icon(
                    Icons.account_circle_outlined,
                    size: 20,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('未设置账号，请先绑定学号。', style: textTheme.bodySmall),
                  ),
                  FilledButton.tonal(
                    onPressed: _openAccount,
                    child: const Text('设置账号'),
                  ),
                ],
              ),
            ] else if (_venueAuthRequired) ...[
              // State 4: Authentication Required State
              Row(
                children: [
                  Icon(Icons.lock_outline, size: 20, color: colors.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _venueError ?? '需要登录校园服务',
                      style: textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _refreshVenueSnapshot(triggerLogin: true),
                    child: const Text('登录并刷新'),
                  ),
                ],
              ),
            ] else if (_venueError != null) ...[
              // State 5: Service Unavailable State (visibly distinct from no-account)
              Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: colors.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '服务暂不可用 · $_venueError',
                      style: textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => _refreshVenueSnapshot(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ] else ...[
              // State 6: Loaded venue availability snapshot
              if (_venues.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final v in _venues)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(v.name),
                              selected: _selectedVenue?.id == v.id,
                              onSelected: (sel) {
                                if (sel) {
                                  setState(() => _selectedVenue = v);
                                  _refreshVenueSnapshot();
                                }
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

              Builder(
                builder: (context) {
                  final availSlots = _venueSlots
                      .where((s) => s.available)
                      .toList();
                  final venueName = _selectedVenue?.name ?? '所选场馆';
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            venueName,
                            style: textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            availSlots.isEmpty
                                ? '今日已约满'
                                : '${availSlots.length} 个时段可约',
                            style: textTheme.labelMedium?.copyWith(
                              color: availSlots.isEmpty
                                  ? colors.outline
                                  : colors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_venueSlots.isEmpty)
                        Text(
                          '当前暂无时段安排。',
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.outline,
                          ),
                        )
                      else
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final slot in _venueSlots.take(6))
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: slot.available
                                          ? colors.primaryContainer
                                          : colors.surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: slot.available
                                            ? colors.primary.withValues(
                                                alpha: 0.25,
                                              )
                                            : colors.outlineVariant,
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          slot.available
                                              ? Icons.check_circle_outline
                                              : Icons.block,
                                          size: 13,
                                          color: slot.available
                                              ? colors.onPrimaryContainer
                                              : colors.outline,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${slot.time} ${slot.courtName}',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                            color: slot.available
                                                ? colors.onPrimaryContainer
                                                : colors.outline,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Spacer(),
                          FilledButton.tonalIcon(
                            onPressed: _drillToVenues,
                            icon: const Icon(Icons.arrow_forward, size: 16),
                            label: const Text('手动预约'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Section wrapper grouping extra campus services with editorial card style.
  Widget _buildServiceSection({
    required String title,
    required TextTheme textTheme,
    required ColorScheme colors,
    required List<_ServiceItem> items,
    Widget? extraItem,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          color: colors.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colors.outlineVariant),
          ),
          child: Column(
            children: [
              for (int i = 0; i < items.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 0.6,
                    indent: 56,
                    endIndent: 16,
                    color: colors.outlineVariant.withValues(alpha: 0.5),
                  ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  leading: Icon(items[i].service.icon, color: colors.primary),
                  title: Text(
                    items[i].title,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    items[i].subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  trailing: items[i].loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right, size: 20),
                  onTap: items[i].onTap,
                ),
              ],
              if (extraItem != null) ...[
                Divider(
                  height: 1,
                  thickness: 0.6,
                  indent: 56,
                  endIndent: 16,
                  color: colors.outlineVariant.withValues(alpha: 0.5),
                ),
                extraItem,
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Concise Campus Mail Sandbox Shell Tile.
  Widget _buildMailShellTile(ColorScheme colors, TextTheme textTheme) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Icon(Icons.mail_outline, color: colors.primary),
      title: Text(
        '校园邮箱',
        style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '复旦大学学生邮箱 (@fudan.edu.cn)',
        style: textTheme.bodySmall?.copyWith(
          color: colors.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => _openPage(const _MailShellPage()),
    );
  }
}

class _ServiceItem {
  final LifeService service;
  final String title;
  final String subtitle;
  final bool loading;
  final VoidCallback onTap;

  const _ServiceItem({
    required this.service,
    required this.title,
    required this.subtitle,
    this.loading = false,
    required this.onTap,
  });
}

class _MailShellPage extends StatelessWidget {
  const _MailShellPage();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('校园邮箱')),
    body: const ListTile(
      leading: Icon(Icons.mail_outline),
      title: Text('邮箱暂未接入'),
    ),
  );
}
