// SPDX-License-Identifier: GPL-3.0-or-later

/// Sports venue descriptor from built-in venues action.
class CampusVenue {
  final int id;
  final String name;

  const CampusVenue({required this.id, required this.name});

  factory CampusVenue.fromJson(Map<String, dynamic> json) {
    return CampusVenue(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// Calendar slot availability unit.
class VenueSlot {
  final int periodId;
  final String time;
  final int courtId;
  final String courtName;
  final bool available;

  const VenueSlot({
    required this.periodId,
    required this.time,
    required this.courtId,
    required this.courtName,
    required this.available,
  });

  factory VenueSlot.fromJson(Map<String, dynamic> json) {
    return VenueSlot(
      periodId: (json['period_id'] as num?)?.toInt() ?? 0,
      time: json['time']?.toString() ?? '',
      courtId: (json['court_id'] as num?)?.toInt() ?? 0,
      courtName: json['court_name']?.toString() ?? '',
      available: json['available'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'period_id': periodId,
    'time': time,
    'court_id': courtId,
    'court_name': courtName,
    'available': available,
  };
}

/// An individual time and court slot within an appointment.
class VenueAppointmentSlot {
  final String date;
  final String time;
  final String resourceName;
  final int? resourceId;
  final int? detailId;
  final int? appointmentDataId;
  final bool active;
  final bool canCancel;
  final String cancelMessage;

  const VenueAppointmentSlot({
    required this.date,
    required this.time,
    required this.resourceName,
    this.resourceId,
    this.detailId,
    this.appointmentDataId,
    this.active = true,
    this.canCancel = false,
    this.cancelMessage = '',
  });

  factory VenueAppointmentSlot.fromJson(Map<String, dynamic> json) {
    return VenueAppointmentSlot(
      date: json['date']?.toString().trim() ?? '',
      time: (json['str_time'] ?? json['time'])?.toString().trim() ?? '',
      resourceName: json['resource_name']?.toString().trim() ?? '',
      resourceId: (json['resource_id'] as num?)?.toInt(),
      detailId: (json['detail_id'] as num?)?.toInt(),
      appointmentDataId: (json['appointment_data_id'] as num?)?.toInt(),
      active:
          json['active'] != 0 &&
          json['active'] != '0' &&
          json['active'] != false,
      canCancel:
          json['can_cancel'] == true ||
          json['can_cancel'] == 1 ||
          json['can_cancel'] == '1',
      cancelMessage: json['cancel_message']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'date': date,
    'time': time,
    'resource_name': resourceName,
    if (resourceId != null) 'resource_id': resourceId,
    if (detailId != null) 'detail_id': detailId,
    if (appointmentDataId != null) 'appointment_data_id': appointmentDataId,
    'active': active,
    'can_cancel': canCancel,
    'cancel_message': cancelMessage,
  };
}

/// Personal reservation record item.
class VenueAppointment {
  final int id;
  final String resourceName;
  final dynamic status;
  final String statusName;
  final int type;
  final bool isGroup;
  final bool isCancel;
  final bool isAllCancel;
  final String cancelMessage;
  final List<VenueAppointmentSlot> slots;
  final String date;
  final String time;
  final String courtName;

  const VenueAppointment({
    required this.id,
    required this.resourceName,
    this.status,
    this.statusName = '',
    this.type = 0,
    this.isGroup = false,
    this.isCancel = false,
    this.isAllCancel = false,
    this.cancelMessage = '',
    this.slots = const [],
    this.date = '',
    this.time = '',
    this.courtName = '',
  });

  /// Cancellation eligibility following DanXi rules and main.mjs contract.
  bool get canCancel {
    if (type == 7) return true;
    if (!isCancel) return false;
    if (slots.isNotEmpty) {
      return slots.any((s) => s.active && s.canCancel);
    }
    return isCancel;
  }

  /// Combined cancel message if not eligible.
  String get displayCancelMessage {
    if (cancelMessage.isNotEmpty) return cancelMessage;
    for (final s in slots) {
      if (s.cancelMessage.isNotEmpty) return s.cancelMessage;
    }
    return '';
  }

  factory VenueAppointment.fromJson(Map<String, dynamic> json) {
    final rawSlots = json['slots'];
    final List<VenueAppointmentSlot> slots = [];
    if (rawSlots is List) {
      for (final s in rawSlots) {
        if (s is Map) {
          slots.add(
            VenueAppointmentSlot.fromJson(Map<String, dynamic>.from(s)),
          );
        }
      }
    }

    final id =
        (json['id'] as num?)?.toInt() ??
        (json['appointment_id'] as num?)?.toInt() ??
        (json['detail_id'] as num?)?.toInt() ??
        0;

    final flatDate = json['date']?.toString() ?? '';
    final flatTime = json['time']?.toString() ?? '';
    final flatCourt = json['court_name']?.toString() ?? '';

    final firstSlot = slots.isNotEmpty ? slots.first : null;
    final displayDate = flatDate.isNotEmpty
        ? flatDate
        : (firstSlot?.date ?? '');
    final displayTime = flatTime.isNotEmpty
        ? flatTime
        : (firstSlot?.time ?? '');
    final displayCourt = flatCourt.isNotEmpty
        ? flatCourt
        : (firstSlot?.resourceName ?? '');

    return VenueAppointment(
      id: id,
      resourceName:
          json['resource_name']?.toString() ?? (firstSlot?.resourceName ?? ''),
      status: json['status'],
      statusName:
          json['status_name']?.toString() ?? (json['status']?.toString() ?? ''),
      type: (json['type'] as num?)?.toInt() ?? 0,
      isGroup:
          json['is_group'] == true ||
          json['is_group'] == 1 ||
          json['is_group'] == '1',
      isCancel:
          json['is_cancel'] == true ||
          json['is_cancel'] == 1 ||
          json['is_cancel'] == '1',
      isAllCancel:
          json['is_all_cancel'] == true ||
          json['is_all_cancel'] == 1 ||
          json['is_all_cancel'] == '1',
      cancelMessage: json['cancel_message']?.toString() ?? '',
      slots: slots,
      date: displayDate,
      time: displayTime,
      courtName: displayCourt,
    );
  }
}
