// SPDX-License-Identifier: GPL-3.0-or-later
// Keep ordinary suites in one test binary to reduce process startup overhead.
// Live probes stay independent; suite-local feature gates remain in each module.

#[path = "suites/academic_catalog.rs"]
mod academic_catalog;
#[path = "suites/academic_programs.rs"]
mod academic_programs;
#[path = "suites/campus.rs"]
mod campus;
#[path = "suites/canvas_content.rs"]
mod canvas_content;
#[path = "suites/canvas_conversation_bridge.rs"]
mod canvas_conversation_bridge;
#[path = "suites/canvas_conversations.rs"]
mod canvas_conversations;
#[path = "suites/canvas_course_users.rs"]
mod canvas_course_users;
#[path = "suites/canvas_learning.rs"]
mod canvas_learning;
#[path = "suites/canvas_session_send.rs"]
mod canvas_session_send;
#[path = "suites/ecard_login_boundary.rs"]
mod ecard_login_boundary;
#[path = "suites/ehall.rs"]
mod ehall;
#[path = "suites/electricity_alert_service.rs"]
mod electricity_alert_service;
#[path = "suites/energy_history.rs"]
mod energy_history;
#[path = "suites/expanded_service_bridge.rs"]
mod expanded_service_bridge;
#[path = "suites/forum_actions.rs"]
mod forum_actions;
#[path = "suites/library.rs"]
mod library;
#[path = "suites/offline.rs"]
mod offline;
#[path = "suites/postgraduate_calendar.rs"]
mod postgraduate_calendar;
#[path = "suites/qr_presentation.rs"]
mod qr_presentation;
#[path = "suites/timetable_regression.rs"]
mod timetable_regression;
