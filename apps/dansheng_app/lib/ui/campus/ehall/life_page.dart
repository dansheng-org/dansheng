import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../../screens/account_balance_screen.dart';
import '../campus_api.dart';
import 'bus_detail.dart';
import 'ecard_detail.dart';
import 'power_detail.dart';
import 'room_detail.dart';

export 'bus_detail.dart';
export 'power_detail.dart';
export 'room_detail.dart';

enum LifeService {
  rooms('教室空位', 'fudan.rooms', Icons.meeting_room_outlined),
  power('寝室电量', 'fudan.electricity', Icons.bolt_outlined),
  library('图书馆', 'fudan.library.occupancy', Icons.local_library_outlined),
  dining('食堂客流', 'fudan.dining.occupancy', Icons.restaurant_outlined),
  bus('校车班次', 'fudan.bus', Icons.directions_bus_outlined),
  notices('教务公告', 'fudan.notices', Icons.campaign_outlined),
  transactions('校园卡明细', 'fudan.ecard.statement', Icons.receipt_long_outlined),
  gpa('学分绩点', 'fudan.gpa', Icons.school_outlined),
  grades('课程成绩', 'fudan.grades', Icons.checklist_outlined),
  exams('考试安排', 'fudan.exams', Icons.event_note_outlined);

  const LifeService(this.label, this.method, this.icon);
  final String label, method;
  final IconData icon;
}

/// Dining areas in the order of their source area codes.
const diningAreas = ['邯郸本部', '南区食堂', '江湾食堂', '枫林食堂', '张江食堂'];

class LifePage extends StatelessWidget {
  const LifePage({
    super.key,
    required this.service,
    required this.controller,
    this.initialBuilding,
    this.initialDate,
    this.initialDiningArea,
    this.initialGraduate,
    this.initialFrom,
    this.initialTo,
  });
  final LifeService service;
  final DanshengController controller;
  final String? initialBuilding;
  final DateTime? initialDate;

  /// Dining area code (0 to 4) to show first; 邯郸本部 when not given.
  final int? initialDiningArea;

  /// Whether notices open on the graduate list.
  final bool? initialGraduate;

  /// Bus route to show first.
  final Campus? initialFrom, initialTo;

  @override
  Widget build(BuildContext context) => switch (service) {
    LifeService.rooms => RoomDetailPage(
      controller: controller,
      initialBuilding: initialBuilding,
      initialDate: initialDate,
    ),
    LifeService.bus => BusDetailPage(
      controller: controller,
      initialDate: initialDate,
      initialFrom: initialFrom,
      initialTo: initialTo,
    ),
    LifeService.power => PowerDetailPage(controller: controller),
    LifeService.transactions => EcardDetailPage(
      controller: controller,
      initialDate: initialDate,
    ),
    _ => _CampusDetail(
      service: service,
      controller: controller,
      initialDate: initialDate,
      initialDiningArea: initialDiningArea,
      initialGraduate: initialGraduate,
    ),
  };
}

class _CampusDetail extends StatefulWidget {
  const _CampusDetail({
    required this.controller,
    required this.service,
    this.initialDate,
    this.initialDiningArea,
    this.initialGraduate,
  });
  final DanshengController controller;
  final LifeService service;
  final DateTime? initialDate;
  final int? initialDiningArea;
  final bool? initialGraduate;
  @override
  State<_CampusDetail> createState() => _LifeState();
}

class _LifeState extends State<_CampusDetail> {
  late final CampusApi api = CampusApi(widget.controller.client);

  dynamic result;
  String? problem;
  bool busy = false;
  bool cached = false;
  bool isAuthError = false;
  int generation = 0;
  String? promptedAccount;
  bool verifying = false;

  Future<void> verifyDining() async {
    if (verifying) {
      return;
    }
    final active = widget.controller.activeAccountId;
    setState(() => verifying = true);
    try {
      await api.call('campus.verifyDining');
      if (mounted && active == widget.controller.activeAccountId) {
        await load();
      }
    } catch (e) {
      if (mounted) {
        setState(() => problem = campusError(e));
      }
    } finally {
      if (mounted) {
        setState(() => verifying = false);
      }
    }
  }

  Future<void> offerVerification(String account) async {
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要双因素认证'),
        content: const Text('在复旦信息门户完成验证后，返回查看食堂客流。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('前往验证'),
          ),
        ],
      ),
    );
    if (open == true &&
        mounted &&
        widget.controller.activeAccountId == account) {
      await verifyDining();
    }
  }

  Future<void> openNotice(String url) async {
    try {
      await api.call('campus.openNotice', {'url': url});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(campusError(e))));
      }
    }
  }

  // Dining campus area selection
  late int diningAreaCode = widget.initialDiningArea ?? 0;

  // Notices audience; the official list page follows the selected segment
  late bool noticesGraduate = widget.initialGraduate ?? false;
  String get noticesListUrl => noticesGraduate
      ? 'https://gs.fudan.edu.cn/tzgg/list.htm'
      : 'https://jwc.fudan.edu.cn/9397/list.htm';

  List<dynamic> semesters = [];
  String? semester;

  LifeService get s => widget.service;
  bool get academic =>
      [LifeService.grades, LifeService.exams, LifeService.gpa].contains(s);
  String date(DateTime d) => d.toIso8601String().substring(0, 10);

  String? _lastAccountId;

  @override
  void initState() {
    super.initState();
    _lastAccountId = widget.controller.activeAccountId;
    widget.controller.addListener(_onControllerUpdate);

    if (widget.controller.activeAccountId != null) {
      load();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    final current = widget.controller.activeAccountId;
    if (current != _lastAccountId) {
      _lastAccountId = current;
      generation++; // cancel inflight async results
      if (mounted) {
        setState(() {
          result = null;
          problem = null;
          cached = false;
          isAuthError = false;
          busy = false;
        });
      }
      if (current != null) {
        load();
      }
    }
  }

  /// Extracts the student association ID from various formats returned by the backend.
  /// Correctly handles `SourceRecord<String>` where record id is 'student-association'
  /// and the actual student ID is stored in 'payload'.
  String? _extractStudentAssociation(dynamic res) {
    if (res == null) {
      return null;
    }
    if (res is String && res.isNotEmpty && res != 'student-association') {
      return res;
    }
    if (res is Map) {
      final payload = res['payload'];
      if (payload is String &&
          payload.isNotEmpty &&
          payload != 'student-association') {
        return payload;
      }
      if (payload is Map) {
        final sub =
            payload['student_association'] ??
            payload['studentAssoc'] ??
            payload['id'];
        if (sub != null &&
            sub.toString().isNotEmpty &&
            sub.toString() != 'student-association') {
          return sub.toString();
        }
      }
      final sa = res['student_association'] ?? res['studentAssoc'];
      if (sa != null && sa.toString().isNotEmpty) {
        return sa.toString();
      }

      final rawId = res['id'];
      if (rawId != null &&
          rawId.toString().isNotEmpty &&
          rawId.toString() != 'student-association') {
        return rawId.toString();
      }
    }
    return null;
  }

  Future<void> load() async {
    if (widget.controller.activeAccountId == null) {
      setState(() {
        problem = '未设置账号，请先绑定复旦统一身份认证账号。';
        isAuthError = false;
        busy = false;
      });
      return;
    }

    final ticket = ++generation;
    final account = widget.controller.activeAccountId;

    setState(() {
      busy = true;
      problem = null;
      isAuthError = false;
      cached = false;
      result = null;
    });

    final input = <String, dynamic>{};
    try {
      if (academic) {
        final catalog = await api.call('fudan.semesters');
        semesters =
            (catalog is Map ? catalog['semesters'] : null) as List? ?? [];
        semester ??= catalog is Map
            ? catalog['default_semester_id']?.toString()
            : null;
        if (semester == null &&
            semesters.isNotEmpty &&
            semesters.first is Map) {
          semester = semesters.first['external_id']?.toString();
        }
        if (semester == null) {
          throw StateError('学期不可用');
        }

        final association = await api.call('fudan.student_association', {
          'semester_id': semester,
        });

        final assocId = _extractStudentAssociation(association);
        if (assocId == null || assocId.isEmpty) {
          throw StateError('无学籍信息');
        }

        input.addAll({'student_association': assocId, 'semester_id': semester});
      }

      if (s == LifeService.dining) {
        input['area_code'] = diningAreaCode;
      }
      // Undergraduate sends no level so its existing cache key stays valid.
      if (s == LifeService.notices && noticesGraduate) {
        input['level'] = 'graduate';
      }

      final data = await api.call(s.method, input);
      if (mounted &&
          ticket == generation &&
          account == widget.controller.activeAccountId) {
        setState(() => result = data);
      }
    } catch (e) {
      final errStr = e.toString();
      final authNeeded =
          errStr.contains('AuthenticationRequired') ||
          errStr.contains('InteractiveLoginRequired') ||
          errStr.contains('NotLoginError') ||
          errStr.contains('401') ||
          errStr.contains('postgraduates_need_login');

      dynamic old;
      try {
        old = await api.call('campus.cached', {'method': s.method, ...input});
      } catch (_) {}

      if (mounted &&
          ticket == generation &&
          account == widget.controller.activeAccountId) {
        setState(() {
          result = old;
          cached = old != null;
          problem = campusError(e);
          isAuthError = authNeeded;
        });
        if (s == LifeService.dining &&
            errStr.contains('InteractiveLoginRequired') &&
            account != null &&
            promptedAccount != account) {
          promptedAccount = account;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && account == widget.controller.activeAccountId) {
              offerVerification(account);
            }
          });
        }
      }
    } finally {
      if (mounted && ticket == generation) {
        setState(() => busy = false);
      }
    }
  }

  /// Recursively unrolls diverse campus response payloads into individual row maps.
  /// Accurately extracts arrays like 'buses', 'dining_halls', 'grades', 'exams', etc.
  /// Prevents empty envelope containers from becoming fake empty rows.
  Iterable<Map> rows(dynamic data) sync* {
    if (data == null) {
      return;
    }
    if (data is List) {
      for (final r in data) {
        yield* rows(r);
      }
      return;
    }
    if (data is! Map) {
      return;
    }

    if (data['records'] is List) {
      yield* rows(data['records']);
      return;
    }
    if (data['entries'] is List) {
      yield* rows(data['entries']);
      return;
    }
    if (data['dining_halls'] is List) {
      yield* rows(data['dining_halls']);
      return;
    }
    if (data['grades'] is List) {
      yield* rows(data['grades']);
      return;
    }
    if (data['exams'] is List) {
      yield* rows(data['exams']);
      return;
    }
    if (data['transactions'] is List) {
      yield* rows(data['transactions']);
      return;
    }
    if (data['data'] is List) {
      yield* rows(data['data']);
      return;
    }
    if (data['list'] is List) {
      yield* rows(data['list']);
      return;
    }
    if (data['courses'] is List) {
      yield* rows(data['courses']);
      return;
    }
    if (data['payload'] != null) {
      final p = data['payload'];
      if (p is List || p is Map) {
        yield* rows(p);
        return;
      }
    }

    // Guard against yielding empty envelopes as rows
    if (data.containsKey('dining_halls') ||
        data.containsKey('grades') ||
        data.containsKey('exams') ||
        data.containsKey('transactions') ||
        data.containsKey('records')) {
      return;
    }

    yield data;
  }

  String money(dynamic raw) {
    if (raw is Map && raw['cents'] is num) {
      return ((raw['cents'] as num) / 100).toStringAsFixed(2);
    }
    if (raw is num) {
      return raw.toStringAsFixed(2);
    }
    if (raw is String && raw.isNotEmpty) {
      return raw;
    }
    return '—';
  }

  Widget row(Map r) {
    String title = '';
    String sub = '';

    switch (s) {
      case LifeService.rooms:
      case LifeService.power:
      case LifeService.bus:
        // Handled by dedicated pages RoomDetailPage, PowerDetailPage, BusDetailPage
        break;

      case LifeService.library:
        if (r['campus'] != null) {
          title = '${r['campus']}';
          sub =
              '当前在馆 ${r['inside'] ?? '—'} 人${r['capacity'] != null ? ' / 容量 ${r['capacity']}' : ''}';
        } else {
          title = '图书馆各馆区总览';
          sub = '当前在馆 ${r['used'] ?? '—'} 人 / 总容量 ${r['total'] ?? '—'}';
        }
        break;

      case LifeService.dining:
        title = '${r['name'] ?? '食堂餐厅'}';
        sub = '当前就餐 ${r['current'] ?? '—'} 人 / 餐厅容量 ${r['capacity'] ?? '—'}';
        break;

      case LifeService.transactions:
        title = '${r['location'] ?? r['transaction_type'] ?? '校园卡消费'}';
        final at = DateTime.tryParse(r['at']?.toString() ?? '');
        final local = at?.toUtc().add(const Duration(hours: 8));
        final stamp = local == null
            ? ''
            : '${date(local)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
        sub =
            '$stamp · ${r['transaction_type'] ?? ''} · ¥ ${money(r['amount'])}';
        break;

      case LifeService.notices:
        title = '${r['title'] ?? '教务公告'}';
        sub = '${r['published_on'] ?? r['date'] ?? ''}';
        break;

      case LifeService.grades:
        title = '${r['course_name'] ?? r['KCMC'] ?? '课程'}';
        final gradeStr = r['letter_grade'] ?? r['CJ'] ?? '—';
        final creditStr = r['credits'] ?? r['XF'] ?? '—';
        final gpStr = r['grade_point'] ?? r['JDZ'];
        sub =
            '成绩: $gradeStr · $creditStr 学分${gpStr != null ? ' · 绩点: $gpStr' : ''}';
        break;

      case LifeService.gpa:
        title = '绩点: ${r['gpa'] ?? '—'}';
        final gpaParts = [
          r['name'],
          r['major'] ?? r['department'],
          r['credits'] != null ? '已获 ${r['credits']} 学分' : null,
          r['ranking'] != null ? '排名第 ${r['ranking']} 名' : null,
        ].whereType<String>().where((str) => str.isNotEmpty).join(' · ');
        sub = gpaParts.isNotEmpty ? gpaParts : '学业总绩点与学分';
        break;

      case LifeService.exams:
        title = '${r['course_name'] ?? '考试科目'}';
        final examParts = [
          r['on'],
          r['time_range'],
          r['room'] ?? '地点待定',
          r['exam_type'],
        ].whereType<String>().where((str) => str.isNotEmpty).join(' · ');
        sub = examParts.isNotEmpty ? examParts : '考试安排待公布';
        break;
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(sub),
        trailing: s == LifeService.notices && r['url'] is String
            ? IconButton(
                tooltip: '打开公告网页',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => openNotice(r['url'] as String),
              )
            : null,
        onTap: s == LifeService.notices && r['url'] is String
            ? () => openNotice(r['url'] as String)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final data = rows(result).toList();
    final hasAccount =
        widget.controller.activeAccountId != null &&
        widget.controller.activeAccountId!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.label),
        actions: [
          if (s == LifeService.notices)
            IconButton(
              tooltip: '打开官网公告栏',
              onPressed: () => openNotice(noticesListUrl),
              icon: const Icon(Icons.open_in_new),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (s == LifeService.notices) ...[
            SegmentedButton<bool>(
              key: const Key('notices_level_toggle'),
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              segments: const [
                ButtonSegment(value: false, label: Text('本科生')),
                ButtonSegment(value: true, label: Text('研究生')),
              ],
              selected: {noticesGraduate},
              onSelectionChanged: (set) {
                setState(() => noticesGraduate = set.first);
                load();
              },
            ),
            const SizedBox(height: 12),
          ],
          if (s == LifeService.dining && hasAccount)
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('校园双因素认证'),
              subtitle: const Text('id.fudan.edu.cn'),
              trailing: const Icon(Icons.open_in_new),
              onTap: verifying ? null : verifyDining,
            ),
          // Distinct No-Account Warning Banner
          if (!hasAccount) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.account_circle_outlined,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '未设置账号',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '查询复旦校园生活与教务服务需要先在“账号与校园卡”中配置统一身份认证账号。',
                    style: textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            AccountBalanceScreen(controller: widget.controller),
                      ),
                    ),
                    child: const Text('设置账号'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          if (s == LifeService.dining) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (code, name) in diningAreas.indexed)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(name),
                        selected: diningAreaCode == code,
                        onSelected: (sel) {
                          if (sel) {
                            setState(() => diningAreaCode = code);
                            load();
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (academic && semesters.isNotEmpty) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final v in semesters.whereType<Map>())
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(v['name']?.toString() ?? ''),
                        selected: v['external_id']?.toString() == semester,
                        onSelected: (_) {
                          setState(
                            () => semester = v['external_id'].toString(),
                          );
                          load();
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (busy) const LinearProgressIndicator(),

          // Service Unavailable or Auth Notice
          if (problem != null) ...[
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isAuthError
                      ? colors.tertiaryContainer
                      : colors.outlineVariant,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isAuthError ? Icons.lock_outline : Icons.info_outline,
                        color: isAuthError
                            ? colors.onTertiaryContainer
                            : colors.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          cached ? '上次读取的数据 · $problem' : problem!,
                          style: textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isAuthError) ...[
                    const SizedBox(height: 10),
                    if (s == LifeService.dining)
                      FilledButton.tonal(
                        onPressed: verifying ? null : verifyDining,
                        child: verifying
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('前往验证'),
                      )
                    else if (academic || s == LifeService.transactions)
                      FilledButton.tonal(
                        onPressed: () async {
                          try {
                            await api.call('campus.login', {
                              'service': s == LifeService.transactions
                                  ? 'ecard'
                                  : 'academic',
                            });
                            await load();
                          } catch (e) {
                            if (mounted) {
                              setState(() => problem = campusError(e));
                            }
                          }
                        },
                        child: const Text('登录并刷新'),
                      ),
                  ],
                ],
              ),
            ),
          ],

          if (!busy && problem == null && result != null && data.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    '暂无相关记录',
                    style: textTheme.bodyMedium?.copyWith(
                      color: colors.outline,
                    ),
                  ),
                ),
              ),
            ),

          ...data.map(row),
        ],
      ),
    );
  }
}
