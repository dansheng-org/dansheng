// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared Rust serialization contract consumed by the Flutter timetable regression.
use chrono::{TimeZone, Utc};
use dansheng_connectors::fudan::{
    parse_postgraduate_timetable, parse_undergraduate_semesters, parse_undergraduate_timetable,
};
use dansheng_connectors::models::SourceContext;
use serde_json::{Value, json};

#[test]
fn timetable_wire_contract_matches_flutter_fixture() {
    let catalog =
        parse_undergraduate_semesters(include_str!("../fixtures/semesters.html")).unwrap();
    let semester = catalog
        .semesters
        .iter()
        .find(|s| s.external_id == catalog.default_semester_id)
        .unwrap()
        .clone();
    let source = SourceContext {
        account_id: "test-account".into(),
        source_id: "test-source".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 5, 10, 0, 0).unwrap(),
    };
    let undergraduate = parse_undergraduate_timetable(
        include_bytes!("../fixtures/undergraduate.json"),
        source.clone(),
        semester.clone(),
    )
    .unwrap();
    let postgraduate = parse_postgraduate_timetable(
        include_bytes!("../fixtures/postgraduate.json"),
        source,
        semester,
    )
    .unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("../fixtures/timetable-contract.json")).unwrap();
    // core_adapter returns serde_json::to_value(table), including SourceRecord
    // wrappers. Android campus.cached stores that entire value unchanged.
    assert_eq!(
        json!({"catalog": catalog, "undergraduate": undergraduate, "postgraduate": postgraduate}),
        expected
    );
}
