// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';

/// One announcement item published by a department.
@immutable
class DepartmentNoticeItem {
  const DepartmentNoticeItem({
    required this.id,
    required this.title,
    required this.url,
    required this.date,
    required this.departmentId,
    required this.departmentName,
  });

  final String id;
  final String title;
  final String url;
  final String date;
  final String departmentId;
  final String departmentName;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'date': date,
    'departmentId': departmentId,
    'departmentName': departmentName,
  };

  factory DepartmentNoticeItem.fromJson(Map<String, dynamic> json) =>
      DepartmentNoticeItem(
        id: json['id'] as String? ?? (json['url'] as String? ?? ''),
        title: json['title'] as String? ?? '',
        url: json['url'] as String? ?? '',
        date: json['date'] as String? ?? '',
        departmentId: json['departmentId'] as String? ?? '',
        departmentName: json['departmentName'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DepartmentNoticeItem &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
