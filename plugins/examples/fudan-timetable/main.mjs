// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2021 DanXi-Dev; JS adaptation (C) 2026 dansheng-core contributors.
// Field mapping/week conversion: DanXi 3c1f5f0, lib/model/time_table.dart.
// Attribution and GPL terms: ../../../crates/dansheng-connectors/NOTICE.md.
const UG = "https://fdjwgl.fudan.edu.cn";
const PG = "http://yjsxk.fudan.edu.cn";
const PG_SECONDARY = "http://yjsxktest.fudan.sh.cn";

function options(input, undergraduate) {
  if (!input || typeof input.account_id !== "string" || !input.account_id.trim()
      || typeof input.semester_id !== "string" || !input.semester_id.trim()
      || input.semester_id.length > 64
      || (undergraduate && !/^\d{1,32}$/.test(input.semester_id))) {
    throw new Error("Explicit account_id and semester_id are required");
  }
  const start = typeof input.starts_on === "string" && /^\d{4}-\d\d-\d\d$/.test(input.starts_on)
    ? new Date(input.starts_on + "T00:00:00Z") : null;
  if (!start || !Number.isFinite(start.getTime()) || start.getUTCDay() !== 1
      || start.toISOString().slice(0, 10) !== input.starts_on) {
    throw new Error("starts_on must be the explicit Monday of teaching week 1");
  }
  return input;
}

async function login(ctx, accountId, origin) {
  try {
    const challenge = await ctx.auth.requireLogin({ account_id: accountId, origin });
    return { status: "auth_required", challenge };
  } catch (error) {
    if (error && (error.code === "AuthenticationRequired" || error.code === "AuthRequired")) {
      return { status: "auth_required", challenge: { code: error.code, account_id: accountId, origin } };
    }
    throw error;
  }
}

async function read(ctx, accountId, origin, url) {
  const auth = await ctx.auth.status({ account_id: accountId, origin });
  if (!auth || auth.authenticated !== true) return { challenge: await login(ctx, accountId, origin) };
  // Public DanXi timetable uses Dio HTTP cookies. The host owns the native HTTP
  // session; browser-only services (e.g. sports) must explicitly use another mode.
  const response = await ctx.http.request({ account_id: accountId, url, method: "GET", headers: { Accept: "application/json" } });
  if (response.status === 401 || (response.status >= 300 && response.status < 400)) {
    return { challenge: await login(ctx, accountId, origin) };
  }
  if (!Number.isInteger(response.status) || response.status < 200 || response.status >= 300) {
    throw new Error("Fudan timetable HTTP request failed");
  }
  const finalUrl = response.final_url || response.url;
  if (finalUrl && (!finalUrl.startsWith(origin + "/") || /\/(?:login|authserver)(?:[/?]|$)/i.test(finalUrl))) {
    return { challenge: await login(ctx, accountId, origin) };
  }
  if (typeof response.body !== "string" || response.body.length > 2 * 1024 * 1024) throw new Error("Invalid Fudan timetable body");
  if (/^\s*(?:<!doctype|<html|<form)/i.test(response.body)) return { challenge: await login(ctx, accountId, origin) };
  try { return { data: JSON.parse(response.body) }; }
  catch { throw new Error("Invalid Fudan timetable JSON"); }
}

function integer(value, max, field) {
  const parsed = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > max) throw new Error("Invalid timetable " + field);
  return parsed;
}

function string(value, field) {
  if (typeof value !== "string" || !value.trim()) throw new Error("Invalid timetable " + field);
  return value;
}

function id(value) {
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return String(value);
  if (typeof value === "string" && value.length > 0 && value.length <= 64) return value;
  throw new Error("Invalid timetable lesson id");
}

function room(value) {
  if (value == null) return null;
  if (typeof value !== "string") throw new Error("Invalid timetable room");
  return value;
}

function undergraduate(data) {
  if (!data || !Array.isArray(data.studentTableVms) || data.studentTableVms.length !== 1
      || !Array.isArray(data.studentTableVms[0].activities)) throw new Error("Missing undergraduate activities");
  if (data.studentTableVms[0].activities.length > 100) throw new Error("Timetable activity limit exceeded");
  return data.studentTableVms[0].activities.map(activity => {
    const weekday = integer(activity.weekday, 7, "weekday");
    const start = integer(activity.startUnit, 15, "startUnit");
    const end = integer(activity.endUnit, 15, "endUnit");
    if (end < start || !Array.isArray(activity.teachers) || !Array.isArray(activity.weekIndexes)) throw new Error("Invalid undergraduate activity");
    return {
      lesson_id: id(activity.lessonId), course_code: string(activity.lessonCode, "lessonCode"),
      name: string(activity.courseName, "courseName"),
      teachers: activity.teachers.map(teacher => string(teacher, "teacher")), room: room(activity.room),
      weekday, start_unit: start, end_unit: end,
      // JWGL's Sunday belongs to the previous Monday-based teaching week.
      weeks: [...new Set(activity.weekIndexes.map(week => integer(week, 64, "weekIndexes") - (weekday === 7 ? 1 : 0)))].sort((a,b) => a-b),
    };
  });
}

function postgraduate(data) {
  if (!data || data.success === false || !Array.isArray(data.results)) throw new Error("Missing postgraduate results");
  if (data.results.length > 100) throw new Error("Timetable activity limit exceeded");
  return data.results.map(row => {
    const bitmap = string(row.ZCBH, "ZCBH");
    if (!/^[01]{1,64}$/.test(bitmap)) throw new Error("Invalid postgraduate week bitmap");
    const start = integer(row.KSJCDM, 15, "KSJCDM");
    const end = row.JSJCDM == null ? start : integer(row.JSJCDM, 15, "JSJCDM");
    if (end < start) throw new Error("Invalid postgraduate unit range");
    return {
      lesson_id: null, course_code: row.KCDM == null ? null : id(row.KCDM), name: string(row.KCMC, "KCMC"),
      teachers: row.JSXM == null || row.JSXM === "" ? [] : [string(row.JSXM, "JSXM")], room: room(row.JASMC),
      weekday: integer(row.XQ, 7, "XQ"), start_unit: start, end_unit: end,
      weeks: [...bitmap].flatMap((bit, i) => bit === "1" ? [i+1] : []),
    };
  });
}

async function save(ctx, input, flavor, courses) {
  const sourceId = "official.fudan-timetable." + flavor;
  const observedAt = new Date().toISOString();
  const seen = new Set();
  for (const course of courses) {
    // Canonical source activity identity, independent of row order; retain source lesson IDs.
    const identity = encodeURIComponent(JSON.stringify([input.semester_id, course.lesson_id,
      course.course_code, course.name, course.weekday, course.start_unit, course.end_unit, course.weeks, course.room]));
    const externalId = input.account_id + ":" + identity;
    if (seen.has(externalId)) continue;
    seen.add(externalId);
    await ctx.sources.upsert({ source_id: sourceId, external_id: externalId, kind: "fudan.timetable", data: {
      account_id: input.account_id, source_id: sourceId, observed_at: observedAt,
      semester_id: input.semester_id, starts_on: input.starts_on, timezone: "Asia/Shanghai", ...course,
    } });
  }
  await ctx.ui.publish({ id: "timetable", component: { type: "list", title: "Fudan timetable",
    items: courses.map(course => ({ title: course.name, weekday: course.weekday,
      start_unit: course.start_unit, end_unit: course.end_unit, weeks: course.weeks, room: course.room })),
  } });
  return { status: "synced", count: seen.size, observed_at: observedAt };
}

export async function syncUndergraduate(ctx, supplied) {
  const input = options(supplied, true);
  const result = await read(ctx, input.account_id, UG, UG + "/student/for-std/course-table/semester/" + input.semester_id + "/print-data");
  if (result.challenge) return result.challenge;
  return save(ctx, input, "undergraduate", undergraduate(result.data));
}

export async function syncPostgraduate(ctx, supplied) {
  const input = options(supplied, false);
  if (input.endpoint != null && input.endpoint !== "primary" && input.endpoint !== "secondary") throw new Error("Invalid PG endpoint");
  const origin = input.endpoint === "secondary" ? PG_SECONDARY : PG;
  // loadKbxx.do returns the current schedule; semester metadata is never sent as a filter.
  const result = await read(ctx, input.account_id, origin, origin + "/yjsxkapp/sys/xsxkappfudan/xsxkCourse/loadKbxx.do?_=" + Date.now());
  if (result.challenge) return result.challenge;
  return save(ctx, input, "postgraduate", postgraduate(result.data));
}
