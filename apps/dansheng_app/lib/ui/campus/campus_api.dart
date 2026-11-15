import 'dart:convert';

import 'package:flutter/services.dart';

import '../../bridge.g.dart';
import '../core/dansheng_client.dart';

/// The native host binds the account and accepts only named campus operations.
class CampusApi {
  const CampusApi(this.client);
  final DanshengClient client;
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async => jsonDecode(
    await client.bridge.invoke(
      HostCommand.campus,
      jsonEncode({'method': method, 'params': params}),
    ),
  );
}

String campusError(Object error) {
  final code = error is PlatformException ? error.code : error.toString();
  bool any(List<String> keys) => keys.any(code.contains);
  if (any(['ForumConsentRequired'])) return '请前往论坛页面登录，阅读风险提示并明确确认承担风险。';
  if (any(['CourseAccessDenied'])) return '这门课程未开放此项内容';
  if (any(['InteractiveLoginRequired'])) return '学校要求在登录页完成验证';
  if (any(['AccountMismatch'])) return '登录身份与当前账号不符';
  if (any(['InvalidCredentials'])) return '账号或密码错误，请核对后重试，多次错误可能被学校锁定';
  if (any([
    'AuthenticationRequired',
    'NotLoginError',
    '401',
    'postgraduates_need_login',
  ])) {
    return '需要登录校园服务';
  }
  if (any(['AccountRequired', 'AccountChanged'])) {
    return '请选择当前账号后再试。';
  }
  if (any(['ConfigurationRequired'])) return '需要先完成平台绑定';
  if (any(['NotificationPermissionRequired'])) return '请允许应用通知后开启预警';
  if (any(['BackgroundScheduleUnavailable'])) return '系统暂时无法安排后台检查，请重试';
  if (any(['SourceSchemaChanged'])) return '校园服务返回的数据格式发生变化，请更新后重试';
  if (any(['LimitExceeded'])) return '查询记录较多，请缩小日期范围后重试';
  if (any(['PermissionDenied', 'ApprovalRequired'])) return '权限不足或账号受限';
  if (any(['NeedsReconciliation'])) return '提交结果待核对，请先刷新记录，不要重复提交。';
  if (any(['CourtOccupied', 'SlotUnavailable'])) return '这个时段已不可约，请刷新后另选。';
  if (any(['ViewerUnavailable', 'FileUnavailable'])) return '当前无法打开这个文件。';
  if (any(['CapabilityUnavailable', 'AssetTooLarge', 'IntegrityMismatch'])) {
    return '当前环境无法完成此操作。';
  }
  if (any(['Cancelled'])) return '已取消。';
  if (any([
    'Network',
    'SourceTransportUnavailable',
    'SourceHttpError',
    'Timeout',
    'Deadline',
  ])) {
    return '暂时无法连接服务，请检查校园网络后刷新。';
  }
  return '请求失败，请稍后重试';
}
