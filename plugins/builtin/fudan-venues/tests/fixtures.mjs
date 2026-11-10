// SPDX-License-Identifier: GPL-3.0-or-later
// Real DanXi response shapes and offline fixtures.
// Reference: C:/Code/danxi/lib/model/sports_reservation.dart

export const FIXTURE_ACCOUNT = 'fixture-user-2026';
export const FIXTURE_VENUE_ID = 900;
export const FIXTURE_DATE = '2026-11-09';

/**
 * Real DanXi calendar response shape.
 * Demonstrates:
 * - Court 901, Period 70: available (occupy: false, num: 1, status: 0)
 * - Court 901, Period 71: occupied (occupy: true, num: 0, status: 1)
 * - Court 902, Period 70: occupied (num: 0, occupy: false)
 * - Court 902, Period 71: read_only (read_only: true)
 * - Court 903, Period 70: available (occupy: false, num: 2, status: 0)
 * - Court 903, Period 71: occupied (status: 2)
 */
export const DANXI_CALENDAR_RESPONSE = {
  e: 'OK',
  m: '操作成功',
  d: {
    time: [
      { id: 70, str_time: '10:00-11:00', start_time: '10:00', end_time: '11:00' },
      { id: 71, str_time: '11:00-12:00', start_time: '11:00', end_time: '12:00' },
    ],
    resource: [
      { id: 901, name: '羽毛球 1 号场' },
      { id: 902, name: '羽毛球 2 号场' },
      { id: 903, name: '羽毛球 3 号场' },
    ],
    data: {
      '2026-11-09': {
        901: {
          70: { occupy: false, num: 1, status: 0, read_only: false },
          71: { occupy: true, num: 0, status: 1, read_only: false },
        },
        902: {
          70: { occupy: false, num: 0, status: 0, read_only: false },
          71: { occupy: false, num: 1, status: 0, read_only: true },
        },
        903: {
          70: { occupy: false, num: 2, status: 0, read_only: false },
          71: { occupy: false, num: 1, status: 2, read_only: false },
        },
      },
    },
  },
};

/**
 * Calendar response where court 901 in period 70 has become occupied (for recheck test).
 */
export const DANXI_CALENDAR_RESPONSE_OCCUPIED = {
  e: 'OK',
  m: '操作成功',
  d: {
    time: [
      { id: 70, str_time: '10:00-11:00', start_time: '10:00', end_time: '11:00' },
      { id: 71, str_time: '11:00-12:00', start_time: '11:00', end_time: '12:00' },
    ],
    resource: [
      { id: 901, name: '羽毛球 1 号场' },
      { id: 902, name: '羽毛球 2 号场' },
      { id: 903, name: '羽毛球 3 号场' },
    ],
    data: {
      '2026-11-09': {
        901: {
          70: { occupy: true, num: 0, status: 1, read_only: false },
          71: { occupy: true, num: 0, status: 1, read_only: false },
        },
      },
    },
  },
};

export const DANXI_VENUES_RESPONSE = {
  e: 'OK',
  m: '操作成功',
  d: {
    data: [
      {
        base: {
          id: 900,
          name: '正大体育馆-羽毛球馆',
          type: 1,
        },
      },
      {
        base: {
          id: 905,
          name: '南区体育馆-乒乓球馆',
          type: 1,
        },
      },
      {
        base: {
          id: 910,
          name: '江湾体育馆-网球场',
          type: 2,
        },
      },
    ],
  },
};

export const DANXI_APPOINTMENTS_RESPONSE = {
  e: 'OK',
  m: '操作成功',
  d: {
    data: [
      {
        id: 5501,
        resource_name: '正大体育馆-羽毛球馆',
        status: 3,
        status_name: '已预约',
        type: 0,
        is_group: 0,
        is_cancel: 1,
        is_all_cancel: 0,
        cancel_message: '',
        appointment_time: [
          {
            date: '2026-11-09',
            str_time: '10:00-11:00',
            resource_name: '羽毛球 1 号场',
            resource_id: 901,
            detail_id: 8801,
            appointment_data_id: 9901,
            active: 1,
            can_cancel: 1,
          },
        ],
      },
    ],
  },
};

export const DANXI_DETAIL_RESPONSE = {
  e: 'OK',
  m: '操作成功',
  d: {
    id: 5501,
    resource_name: '正大体育馆-羽毛球馆',
    status: 3,
    status_name: '已预约',
    qrcode: 'DATA:QRCODE-FIXTURE-12345',
    resource_info: {
      name: '正大体育馆-羽毛球馆',
      config: {
        is_show_code: 1,
        refresh_time: 15,
      },
    },
    appointment_time: [
      {
        date: '2026-11-09',
        str_time: '10:00-11:00',
        resource_name: '羽毛球 1 号场',
        resource_id: 901,
        active: 1,
        can_cancel: 1,
      },
    ],
  },
};

export const LAUNCH_SUCCESS_RESPONSE = {
  e: 'OK',
  m: '预约成功',
  d: {
    order_id: 778899,
  },
};

export const LAUNCH_GONE_RESPONSE = {
  e: 1,
  m: '该场地容量不足已被预约',
  d: null,
};

export const LAUNCH_NOT_OPEN_RESPONSE = {
  e: 1,
  m: '不在预约时间内，服务未开放',
  d: null,
};

export const LAUNCH_THROTTLED_RESPONSE = {
  e: 1,
  m: '访问频繁，请稍后再试',
  d: null,
};

export const LAUNCH_EXISTING_RESPONSE = {
  e: 1,
  m: '您有未结束的预约，不可重复预约',
  d: null,
};

export const CANCEL_SUCCESS_RESPONSE = {
  e: 'OK',
  m: '退订成功',
  d: null,
};

export const CANCEL_REJECT_RESPONSE = {
  e: 1,
  m: '当前预约不能取消',
  d: null,
};

export const DANXI_APPOINTMENTS_WITH_THIRD_PARTY = {
  e: 'OK',
  m: '操作成功',
  d: {
    data: [
      {
        id: 5501,
        resource_name: '正大体育馆-羽毛球馆',
        status: 3,
        status_name: '已预约',
        type: 0,
        is_group: 0,
        is_cancel: 1,
        is_all_cancel: 0,
        cancel_message: '',
        appointment_time: [
          {
            date: '2026-11-09',
            str_time: '10:00-11:00',
            resource_name: '羽毛球 1 号场',
            resource_id: 901,
            detail_id: 8801,
            appointment_data_id: 9901,
            active: 1,
            can_cancel: 1,
          },
        ],
      },
      {
        id: 5502,
        resource_name: '江湾游泳馆-个人入场',
        status: 3,
        status_name: '已预约',
        type: 7, // Third party
        is_group: 0,
        is_cancel: 0,
        is_all_cancel: 0,
        cancel_message: '',
        appointment_time: [
          {
            date: '2026-11-10',
            str_time: '14:00-15:00',
            resource_name: '游泳馆浅水区',
            resource_id: 905,
            active: 1,
            can_cancel: 0,
          },
        ],
      },
      {
        id: 5503,
        resource_name: '南区乒乓球房',
        status: 3,
        status_name: '已预约',
        type: 0,
        is_group: 0,
        is_cancel: 0, // Not cancellable
        is_all_cancel: 0,
        cancel_message: '当前预约不符合取消规则',
        appointment_time: [
          {
            date: '2026-11-09',
            str_time: '08:00-09:00',
            resource_name: '乒乓球 1 号桌',
            resource_id: 920,
            detail_id: 8820,
            appointment_data_id: 9920,
            active: 1,
            can_cancel: 0,
          },
        ],
      },
    ],
  },
};

export const DANXI_APPOINTMENTS_CANCELLED = {
  e: 'OK',
  m: '操作成功',
  d: {
    data: [
      {
        id: 5501,
        resource_name: '正大体育馆-羽毛球馆',
        status: 0, // Cancelled status
        status_name: '已取消',
        type: 0,
        is_group: 0,
        is_cancel: 0,
        is_all_cancel: 0,
        appointment_time: [
          {
            date: '2026-11-09',
            str_time: '10:00-11:00',
            resource_name: '羽毛球 1 号场',
            resource_id: 901,
            detail_id: 8801,
            appointment_data_id: 9901,
            active: 0, // Inactive
            can_cancel: 0,
          },
        ],
      },
    ],
  },
};

export const IDENTITY_PROBE_SUCCESS = {
  authenticated: true,
  body: {
    e: 'OK',
    m: '操作成功',
    d: {
      number: FIXTURE_ACCOUNT,
      name: '测试用户',
      user_type: 'student',
    },
  },
};

export const IDENTITY_PROBE_MISMATCH = {
  authenticated: true,
  body: {
    e: 'OK',
    m: '操作成功',
    d: {
      number: 'different-account-999',
      name: '其他用户',
    },
  },
};
