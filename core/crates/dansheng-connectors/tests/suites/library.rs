// SPDX-License-Identifier: GPL-3.0-or-later
use async_trait::async_trait;
use campus::{CampusError, Coverage};
use chrono::{TimeZone, Utc};
use dansheng_connectors::library::{
    ACCESS_TOKEN_HEADER, BIBLIOGRAPHY_PREFIX, CURRENT_LOANS_PATH, HISTORY_LOANS_PATH,
    HOLDINGS_PATH, LIBRARY_ORIGIN, LibraryClient, LibraryDateMeaning, LibraryDatePrecision,
    LibraryError, LibraryIdentityState, LibraryLoanIdBasis, LibraryLoanKind, LibraryLookupKind,
    LibraryPage, MAX_LIBRARY_BODY, READER_INFO_PATH, SINGLE_VOLUME_PATH,
};
use dansheng_connectors::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth, campus, models,
};
use models::SourceContext;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use url::Url;

const VOLUME: &[u8] = include_bytes!("../../fixtures/library/single-volume.json");
const BIB: &[u8] = include_bytes!("../../fixtures/library/bibliography.json");
const HOLDINGS: &[u8] = include_bytes!("../../fixtures/library/holdings.json");
const READER: &[u8] = include_bytes!("../../fixtures/library/reader.json");
const CURRENT: &[u8] = include_bytes!("../../fixtures/library/current-loans.json");
const HISTORY: &[u8] = include_bytes!("../../fixtures/library/history-loans.json");

fn source() -> SourceContext {
    SourceContext {
        account_id: "opaque-host-account".into(),
        source_id: "official.fudan.library.current".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 9, 12, 0, 0).unwrap(),
    }
}
fn page() -> LibraryPage {
    LibraryPage {
        page_no: 1,
        page_size: 2,
    }
}
fn baseline(source: &SourceContext) -> String {
    let parts = [LIBRARY_ORIGIN, &source.account_id, "synthetic-reader-1"];
    format!(
        "library-reader:{:x}",
        Sha256::digest(serde_json::to_vec(&parts).unwrap())
    )
}
fn reply(path: &str, body: &[u8]) -> Result<ConnectorResponse, ConnectorError> {
    Ok(ConnectorResponse {
        status: 200,
        final_url: Url::parse(&format!("{LIBRARY_ORIGIN}{path}")).unwrap(),
        headers: vec![("Content-Type".into(), "application/json".into())],
        body: body.into(),
    })
}

#[derive(Clone, Default)]
struct FakeTransport {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    replies: Arc<Mutex<VecDeque<Result<ConnectorResponse, ConnectorError>>>>,
}
impl FakeTransport {
    fn new(replies: impl IntoIterator<Item = Result<ConnectorResponse, ConnectorError>>) -> Self {
        Self {
            requests: Arc::default(),
            replies: Arc::new(Mutex::new(replies.into_iter().collect())),
        }
    }
}
#[async_trait]
impl ConnectorTransport for FakeTransport {
    async fn execute(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, ConnectorError> {
        self.requests.lock().unwrap().push(request);
        self.replies
            .lock()
            .unwrap()
            .pop_front()
            .expect("synthetic response expected")
    }
}

#[tokio::test]
async fn public_single_volume_uses_exact_observed_callnumber_get_and_local_limit() {
    let transport = FakeTransport::new([reply(SINGLE_VOLUME_PATH, VOLUME)]);
    let batch = LibraryClient::new(transport.clone())
        .single_volume(&source(), LibraryLookupKind::CallNumber, "I000/1001", 1)
        .await
        .unwrap();
    assert_eq!(batch.records.len(), 1);
    assert_eq!(batch.records[0].payload.catalogue_id, "1001");
    assert!(matches!(batch.coverage, Coverage::Window { .. }));
    assert_eq!(
        batch.records[0].payload.official_url,
        "https://opac.fudan.edu.cn/#/bookInfo/g9"
    );
    let request = &transport.requests.lock().unwrap()[0];
    assert_eq!(request.method, HttpMethod::Get);
    assert_eq!(request.auth, TransportAuth::Anonymous);
    assert_eq!(
        request.url.query(),
        Some("searchKey=resource_djssh&value=I000%2F1001")
    );
    assert!(!request.url.query().unwrap().contains("searchConditions"));
    assert!(
        !serde_json::to_string(&batch)
            .unwrap()
            .contains("SYNTHETIC-PUBLIC-ITEM")
    );
}

#[tokio::test]
async fn barcode_lookup_uses_reviewed_key_and_empty_list_remains_scoped_window() {
    let transport = FakeTransport::new([reply(
        SINGLE_VOLUME_PATH,
        br#"{"code":200,"data":{"list":[]}}"#,
    )]);
    let batch = LibraryClient::new(transport.clone())
        .single_volume(
            &source(),
            LibraryLookupKind::Barcode,
            "synthetic-public-barcode",
            2,
        )
        .await
        .unwrap();
    assert!(batch.records.is_empty());
    assert_eq!(batch.source, source());
    assert!(matches!(batch.coverage, Coverage::Window { .. }));
    assert_eq!(
        transport.requests.lock().unwrap()[0].url.query(),
        Some("searchKey=resource_djtmh&value=synthetic-public-barcode")
    );
}

#[tokio::test]
async fn bibliography_maps_only_minimal_public_metadata_and_safe_constructed_url() {
    let path = format!("{BIBLIOGRAPHY_PREFIX}1001");
    let transport = FakeTransport::new([reply(&path, BIB)]);
    let record = LibraryClient::new(transport)
        .bibliography(&source(), "1001")
        .await
        .unwrap();
    assert_eq!(record.payload.title, "合成书目");
    assert_eq!(record.payload.authors, vec!["合成作者甲", "合成作者乙"]);
    assert_eq!(record.payload.publication_year, Some(2026));
    assert_eq!(record.payload.isbns, vec!["9780000000000"]);
    assert_eq!(
        record.payload.official_url,
        "https://opac.fudan.edu.cn/#/bookInfo/g9"
    );
    let encoded = serde_json::to_string(&record).unwrap();
    assert!(!encoded.contains("SYNTHETIC-SIGNATURE"));
    assert!(!encoded.contains("SYNTHETIC-PERSON"));
    assert!(!encoded.contains("resource_openurl"));
}

#[tokio::test]
async fn bibliography_not_found_or_mismatched_identity_cannot_be_reported_as_success() {
    for (body, not_found) in [
        (json!({"code":200,"data":[]}), true),
        (
            json!({"code":200,"data":[{"resource_smjlh":"1002","resource_ztm":"wrong"}]}),
            false,
        ),
    ] {
        let transport = FakeTransport::new([reply(
            &format!("{BIBLIOGRAPHY_PREFIX}1001"),
            &serde_json::to_vec(&body).unwrap(),
        )]);
        let error = LibraryClient::new(transport)
            .bibliography(&source(), "1001")
            .await
            .unwrap_err();
        if not_found {
            assert_eq!(error, LibraryError::NotFound);
        } else {
            assert!(matches!(
                error,
                LibraryError::Campus(CampusError::SchemaChanged {
                    field: "bibliography.identity",
                    ..
                })
            ));
        }
    }
}

#[tokio::test]
async fn holdings_preserve_unknown_status_and_dates_without_inferred_timezone() {
    let transport = FakeTransport::new([reply(HOLDINGS_PATH, HOLDINGS)]);
    let batch = LibraryClient::new(transport.clone())
        .holdings(&source(), "1001", page())
        .await
        .unwrap();
    assert_eq!(
        batch.coverage,
        Coverage::Page {
            next: None,
            total: Some(2)
        }
    );
    assert!(batch.records[0].payload.known_available);
    assert!(batch.records[0].payload.expected_return.is_none());
    let record = &batch.records[1].payload;
    assert_eq!(record.item_status, "FutureStatusV2");
    assert!(!record.known_available);
    assert_eq!(record.temporary_location.as_deref(), Some("合成临时书库"));
    let date = record.expected_return.as_ref().unwrap();
    assert_eq!(date.source_field, "checkinDateTime");
    assert_eq!(
        date.meaning,
        LibraryDateMeaning::ExpectedReturnAsDisplayedByHoldingsUi
    );
    assert_eq!(date.precision, LibraryDatePrecision::DateTimeWithoutZone);
    assert!(date.timezone.is_none());
    assert_eq!(
        transport.requests.lock().unwrap()[0].url.query(),
        Some("catalogueId=1001&pageNo=1&pageSize=2&display=true")
    );
    assert!(
        !serde_json::to_string(&batch)
            .unwrap()
            .contains("SYNTHETIC-SIGNATURE")
    );
    assert!(
        !serde_json::to_string(&batch)
            .unwrap()
            .contains("SYNTHETIC-ITEM-OMIT")
    );
}

#[tokio::test]
async fn reader_identity_observation_is_explicitly_unbound_and_redacts_pii() {
    let transport = FakeTransport::new([reply(READER_INFO_PATH, READER)]);
    let identity = LibraryClient::new(transport.clone())
        .reader_identity(&source())
        .await
        .unwrap();
    assert_eq!(identity.state, LibraryIdentityState::ObservedUnbound);
    assert_eq!(identity.reader_ref, baseline(&source()));
    assert!(
        !serde_json::to_string(&identity)
            .unwrap()
            .contains("synthetic-reader-1")
    );
    assert!(!format!("{identity:?}").contains("SYNTHETIC-"));
    let request = &transport.requests.lock().unwrap()[0];
    assert_eq!(request.url.path(), READER_INFO_PATH);
    assert!(request.url.query().is_none());
    assert_eq!(
        request.auth,
        TransportAuth::HostHeaders {
            account_id: source().account_id
        }
    );
    assert!(
        !request
            .headers
            .iter()
            .any(|(name, _)| name == ACCESS_TOKEN_HEADER)
    );
}

#[tokio::test]
async fn missing_or_arbitrary_username_binding_blocks_loan_io() {
    let transport = FakeTransport::default();
    let client = LibraryClient::new(transport.clone());
    for binding in [
        None,
        Some("synthetic-reader-1"),
        Some("opaque-host-account"),
        Some("library-reader:invalid"),
    ] {
        assert_eq!(
            client
                .loans(&source(), LibraryLoanKind::Current, page(), binding)
                .await
                .unwrap_err(),
            LibraryError::IdentityUnverified
        );
    }
    assert!(transport.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn token_subject_mismatch_blocks_loans_after_only_reader_info() {
    let mut reader: Value = serde_json::from_slice(READER).unwrap();
    reader["data"]["barcode"] = json!("another-synthetic-reader");
    let transport = FakeTransport::new([reply(
        READER_INFO_PATH,
        &serde_json::to_vec(&reader).unwrap(),
    )]);
    let error = LibraryClient::new(transport.clone())
        .loans(
            &source(),
            LibraryLoanKind::Current,
            page(),
            Some(&baseline(&source())),
        )
        .await
        .unwrap_err();
    assert_eq!(error, LibraryError::IdentityMismatch);
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    assert_eq!(
        transport.requests.lock().unwrap()[0].url.path(),
        READER_INFO_PATH
    );
    assert!(!format!("{error:?}").contains("another-synthetic-reader"));
}

#[tokio::test]
async fn unverified_reader_schema_blocks_loans_and_reports_protocol_explicitly() {
    let transport = FakeTransport::new([reply(
        READER_INFO_PATH,
        br#"{"code":200,"data":{"name":"SYNTHETIC-PERSON-OMIT"}}"#,
    )]);
    let error = LibraryClient::new(transport.clone())
        .loans(
            &source(),
            LibraryLoanKind::Current,
            page(),
            Some(&baseline(&source())),
        )
        .await
        .unwrap_err();
    assert_eq!(
        error,
        LibraryError::ProtocolUnverified {
            field: "reader.barcode"
        }
    );
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn current_nested_and_flat_loan_shapes_preserve_due_semantics_and_unknown_count() {
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        reply(CURRENT_LOANS_PATH, CURRENT),
    ]);
    let output = LibraryClient::new(transport.clone())
        .loans(
            &source(),
            LibraryLoanKind::Current,
            page(),
            Some(&baseline(&source())),
        )
        .await
        .unwrap();
    assert_eq!(
        output.identity,
        LibraryIdentityState::MatchedTrustedFingerprint
    );
    assert!(!output.protocol_live_validated);
    assert_eq!(output.batch.records.len(), 2);
    let first = &output.batch.records[0].payload;
    assert_eq!(first.authors, vec!["合成作者甲", "合成作者乙"]);
    assert_eq!(first.renewal_count, None);
    assert_eq!(first.id_basis, LibraryLoanIdBasis::AccountItemFingerprint);
    let due = first.due.as_ref().unwrap();
    assert_eq!(
        due.meaning,
        LibraryDateMeaning::DueAsDisplayedByOfficialCurrentLoanUi
    );
    assert_eq!(due.source_field, "checkinDateTime");
    assert_eq!(due.precision, LibraryDatePrecision::DateTimeWithoutZone);
    assert!(due.timezone.is_none());
    assert!(first.returned.is_none());
    let second = &output.batch.records[1].payload;
    assert_eq!(
        second.checkout.as_ref().unwrap().precision,
        LibraryDatePrecision::NumericUnknownUnit
    );
    assert!(second.checkout.as_ref().unwrap().timezone.is_none());
    assert_eq!(
        second.due.as_ref().unwrap().timezone.as_deref(),
        Some("+08:00")
    );
    assert_eq!(second.renewal_count, Some(2));
    let requests = transport.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].url.path(), READER_INFO_PATH);
    assert_eq!(requests[1].url.path(), CURRENT_LOANS_PATH);
    assert_eq!(requests[1].url.query(), Some("pageNo=1&pageSize=2"));
    assert!(
        requests
            .iter()
            .all(|r| r.method == HttpMethod::Get && r.body.is_none())
    );
    assert!(requests.iter().all(|r| {
        r.headers
            .iter()
            .all(|(name, _)| name != ACCESS_TOKEN_HEADER)
    }));
    let encoded = serde_json::to_string(&output).unwrap();
    for sentinel in [
        "SYNTHETIC-SIGNATURE",
        "SYNTHETIC-READER-OMIT",
        "SYNTHETIC-EMAIL",
        "synthetic-loan-item-1",
    ] {
        assert!(!encoded.contains(sentinel));
    }
}

#[tokio::test]
async fn v2_history_uses_get_and_separate_return_date_not_current_due_or_old_post_shape() {
    let mut history_source = source();
    history_source.source_id = "official.fudan.library.history".into();
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        reply(HISTORY_LOANS_PATH, HISTORY),
    ]);
    let output = LibraryClient::new(transport.clone())
        .loans(
            &history_source,
            LibraryLoanKind::History,
            page(),
            Some(&baseline(&history_source)),
        )
        .await
        .unwrap();
    assert_eq!(output.batch.source.source_id, history_source.source_id);
    let first = &output.batch.records[0].payload;
    assert_eq!(first.title.as_deref(), Some("合成历史书一"));
    assert_eq!(first.returned.as_ref().unwrap().source_field, "returnDate");
    assert_eq!(
        first.returned.as_ref().unwrap().meaning,
        LibraryDateMeaning::ReturnedAsDisplayedByOfficialHistoryUi
    );
    assert!(first.due.is_none());
    assert!(output.batch.records[1].payload.title.is_none());
    assert_eq!(
        output.batch.records[1].payload.id_basis,
        LibraryLoanIdBasis::ContentFingerprint
    );
    assert!(
        output
            .batch
            .records
            .iter()
            .all(|r| r.external_id.starts_with("library:history:"))
    );
    let requests = transport.requests.lock().unwrap();
    assert_eq!(requests[1].url.path(), HISTORY_LOANS_PATH);
    assert_eq!(requests[1].method, HttpMethod::Get);
    assert!(requests[1].body.is_none());
    assert!(
        !serde_json::to_string(&output)
            .unwrap()
            .contains("SYNTHETIC-")
    );
}

#[tokio::test]
async fn account_switch_cannot_reuse_trusted_reader_fingerprint() {
    let mut other = source();
    other.account_id = "another-opaque-account".into();
    let transport = FakeTransport::new([reply(READER_INFO_PATH, READER)]);
    assert_eq!(
        LibraryClient::new(transport)
            .loans(
                &other,
                LibraryLoanKind::Current,
                page(),
                Some(&baseline(&source()))
            )
            .await
            .unwrap_err(),
        LibraryError::IdentityMismatch
    );
}

#[tokio::test]
async fn current_and_history_external_ids_do_not_collide_even_if_remote_id_repeats() {
    let mut history: Value = serde_json::from_slice(HISTORY).unwrap();
    history["data"]["list"][0]["id"] = json!("synthetic-loan-id-2");
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        reply(CURRENT_LOANS_PATH, CURRENT),
        reply(READER_INFO_PATH, READER),
        reply(HISTORY_LOANS_PATH, &serde_json::to_vec(&history).unwrap()),
    ]);
    let client = LibraryClient::new(transport);
    let current = client
        .loans(
            &source(),
            LibraryLoanKind::Current,
            page(),
            Some(&baseline(&source())),
        )
        .await
        .unwrap();
    let history = client
        .loans(
            &source(),
            LibraryLoanKind::History,
            page(),
            Some(&baseline(&source())),
        )
        .await
        .unwrap();
    assert_ne!(
        current.batch.records[1].external_id,
        history.batch.records[0].external_id
    );
    assert_ne!(current.batch.source_revision, history.batch.source_revision);
}

#[tokio::test]
async fn page_limits_and_inconsistent_totals_fail_closed_not_full_empty_snapshots() {
    for total in [json!(0), json!(1), json!(3)] {
        let mut holdings: Value = serde_json::from_slice(HOLDINGS).unwrap();
        holdings["data"]["total"] = total;
        if holdings["data"]["total"] == json!(3) {
            holdings["data"]["list"].as_array_mut().unwrap().truncate(1);
        }
        let transport = FakeTransport::new([reply(
            HOLDINGS_PATH,
            &serde_json::to_vec(&holdings).unwrap(),
        )]);
        assert_eq!(
            LibraryClient::new(transport)
                .holdings(&source(), "1001", page())
                .await
                .unwrap_err(),
            LibraryError::Campus(CampusError::PaginationInconsistent)
        );
    }
    let transport = FakeTransport::new([reply(HOLDINGS_PATH, HOLDINGS)]);
    assert_eq!(
        LibraryClient::new(transport)
            .holdings(
                &source(),
                "1001",
                LibraryPage {
                    page_no: 1,
                    page_size: 1
                }
            )
            .await
            .unwrap_err(),
        LibraryError::Transport(ConnectorError::LimitExceeded)
    );
}

#[tokio::test]
async fn unknown_total_and_empty_lists_have_explicit_coverage_and_scope() {
    for data in [json!({"list":[]}), json!({"list":[],"total":0})] {
        let body = serde_json::to_vec(&json!({"code":200,"data":data})).unwrap();
        let transport = FakeTransport::new([reply(HOLDINGS_PATH, &body)]);
        let batch = LibraryClient::new(transport)
            .holdings(&source(), "1001", page())
            .await
            .unwrap();
        assert_eq!(batch.source, source());
        assert!(batch.records.is_empty());
        assert_ne!(batch.coverage, Coverage::Complete);
        if data.get("total").is_none() {
            assert!(matches!(batch.coverage, Coverage::Window { .. }));
        }
    }
}

#[tokio::test]
async fn duplicate_ids_and_hidden_holdings_are_rejected_without_partial_visibility_leaks() {
    for duplicate in [true, false] {
        let mut value: Value = serde_json::from_slice(HOLDINGS).unwrap();
        if duplicate {
            value["data"]["list"][1]["id"] = value["data"]["list"][0]["id"].clone();
        } else {
            value["data"]["list"][1]["display"] = json!(false);
        }
        let transport =
            FakeTransport::new([reply(HOLDINGS_PATH, &serde_json::to_vec(&value).unwrap())]);
        assert!(
            LibraryClient::new(transport)
                .holdings(&source(), "1001", page())
                .await
                .is_err()
        );
    }
}

#[tokio::test]
async fn login_redirect_shell_code401_and_permission_failures_do_not_become_empty_loans() {
    let mut redirect = reply(READER_INFO_PATH, b"").unwrap();
    redirect.status = 302;
    redirect.headers = vec![(
        "Location".into(),
        "https://id.fudan.edu.cn/login?ticket=SYNTHETIC-SECRET".into(),
    )];
    for response in [
        Ok(redirect),
        reply(
            READER_INFO_PATH,
            b"<html><form><input type=password></form></html>",
        ),
        reply(
            READER_INFO_PATH,
            br#"{"code":401,"msg":"SYNTHETIC-SECRET"}"#,
        ),
    ] {
        let transport = FakeTransport::new([response]);
        let error = LibraryClient::new(transport.clone())
            .loans(
                &source(),
                LibraryLoanKind::Current,
                page(),
                Some(&baseline(&source())),
            )
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            LibraryError::Transport(ConnectorError::AuthRequired(_))
        ));
        assert!(!format!("{error:?}").contains("SYNTHETIC-SECRET"));
        assert_eq!(transport.requests.lock().unwrap().len(), 1);
    }
    let transport = FakeTransport::new([reply(
        READER_INFO_PATH,
        br#"{"code":403,"msg":"SYNTHETIC-SECRET"}"#,
    )]);
    assert_eq!(
        LibraryClient::new(transport)
            .reader_identity(&source())
            .await
            .unwrap_err(),
        LibraryError::Transport(ConnectorError::PermissionDenied)
    );
}

#[tokio::test]
async fn unsafe_response_or_oversized_body_is_rejected_without_secret_error_text() {
    let mut cross_origin = reply(SINGLE_VOLUME_PATH, VOLUME).unwrap();
    cross_origin.final_url =
        Url::parse("https://foreign.example.invalid/?token=SYNTHETIC-SECRET").unwrap();
    let transport = FakeTransport::new([Ok(cross_origin)]);
    assert_eq!(
        LibraryClient::new(transport)
            .single_volume(&source(), LibraryLookupKind::CallNumber, "I000", 2)
            .await
            .unwrap_err(),
        LibraryError::Transport(ConnectorError::UnsafeUrl)
    );
    let transport =
        FakeTransport::new([reply(SINGLE_VOLUME_PATH, &vec![b' '; MAX_LIBRARY_BODY + 1])]);
    assert_eq!(
        LibraryClient::new(transport)
            .single_volume(&source(), LibraryLookupKind::CallNumber, "I000", 2)
            .await
            .unwrap_err(),
        LibraryError::Transport(ConnectorError::LimitExceeded)
    );
}

#[tokio::test]
async fn malformed_private_schema_does_not_fabricate_identity_or_history_items() {
    let invalid = json!({"code":200,"data":{"total":1,"list":[{"title":"no identity"}]}});
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        reply(HISTORY_LOANS_PATH, &serde_json::to_vec(&invalid).unwrap()),
    ]);
    let error = LibraryClient::new(transport)
        .loans(
            &source(),
            LibraryLoanKind::History,
            page(),
            Some(&baseline(&source())),
        )
        .await
        .unwrap_err();
    assert_eq!(
        error,
        LibraryError::ProtocolUnverified {
            field: "history.catalogue_id"
        }
    );
}

#[tokio::test]
async fn loan_read_timeout_is_not_retried_and_next_page_stays_a_page() {
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        Err(ConnectorError::Timeout),
    ]);
    assert_eq!(
        LibraryClient::new(transport.clone())
            .loans(
                &source(),
                LibraryLoanKind::Current,
                page(),
                Some(&baseline(&source()))
            )
            .await
            .unwrap_err(),
        LibraryError::Transport(ConnectorError::Timeout)
    );
    assert_eq!(transport.requests.lock().unwrap().len(), 2);
    let mut data: Value = serde_json::from_slice(CURRENT).unwrap();
    data["data"]["total"] = json!(3);
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        reply(CURRENT_LOANS_PATH, &serde_json::to_vec(&data).unwrap()),
    ]);
    let result = LibraryClient::new(transport)
        .loans(
            &source(),
            LibraryLoanKind::Current,
            page(),
            Some(&baseline(&source())),
        )
        .await
        .unwrap();
    assert_eq!(
        result.batch.coverage,
        Coverage::Page {
            next: Some(2),
            total: Some(3)
        }
    );
}

#[tokio::test]
async fn invalid_query_page_and_catalogue_id_never_execute_network() {
    let transport = FakeTransport::default();
    let client = LibraryClient::new(transport.clone());
    for id in ["../reader", "1001?userId=other", "0", "9007199254740992"] {
        assert!(client.bibliography(&source(), id).await.is_err());
    }
    for p in [
        LibraryPage {
            page_no: 0,
            page_size: 2,
        },
        LibraryPage {
            page_no: 1,
            page_size: 51,
        },
        LibraryPage {
            page_no: 10001,
            page_size: 2,
        },
    ] {
        assert!(client.holdings(&source(), "1001", p).await.is_err());
    }
    for query in ["", "https://foreign.example.invalid/", "I000\n"] {
        assert!(
            client
                .single_volume(&source(), LibraryLookupKind::CallNumber, query, 2)
                .await
                .is_err()
        );
    }
    assert!(
        client
            .single_volume(&source(), LibraryLookupKind::CallNumber, "I000", 0)
            .await
            .is_err()
    );
    let mut invalid = source();
    invalid.source_id.clear();
    assert!(client.reader_identity(&invalid).await.is_err());
    assert!(transport.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn duplicate_history_content_identity_is_not_given_fake_offset_ids() {
    let mut history: Value = serde_json::from_slice(HISTORY).unwrap();
    history["data"]["list"][0] = history["data"]["list"][1].clone();
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        reply(HISTORY_LOANS_PATH, &serde_json::to_vec(&history).unwrap()),
    ]);
    assert_eq!(
        LibraryClient::new(transport)
            .loans(
                &source(),
                LibraryLoanKind::History,
                page(),
                Some(&baseline(&source()))
            )
            .await
            .unwrap_err(),
        LibraryError::Transport(ConnectorError::PaginationCycle)
    );
}

#[tokio::test]
async fn excessive_private_wire_items_remain_limit_error_not_unknown_protocol() {
    let rows = vec![json!({"id":"synthetic-row"}); 2001];
    let body = json!({"code":200,"data":{"total":2001,"list":rows}});
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        reply(CURRENT_LOANS_PATH, &serde_json::to_vec(&body).unwrap()),
    ]);
    assert_eq!(
        LibraryClient::new(transport)
            .loans(
                &source(),
                LibraryLoanKind::Current,
                page(),
                Some(&baseline(&source()))
            )
            .await
            .unwrap_err(),
        LibraryError::Transport(ConnectorError::LimitExceeded)
    );
}

#[tokio::test]
async fn invalid_calendar_date_stays_unclassified_without_timezone_or_reminder_claim() {
    let mut current: Value = serde_json::from_slice(CURRENT).unwrap();
    current["data"]["list"][0]["itemInfo"]["item"]["checkinDateTime"] = json!("2026-02-31");
    let transport = FakeTransport::new([
        reply(READER_INFO_PATH, READER),
        reply(CURRENT_LOANS_PATH, &serde_json::to_vec(&current).unwrap()),
    ]);
    let output = LibraryClient::new(transport)
        .loans(
            &source(),
            LibraryLoanKind::Current,
            page(),
            Some(&baseline(&source())),
        )
        .await
        .unwrap();
    let date = output.batch.records[0].payload.due.as_ref().unwrap();
    assert_eq!(date.raw, "2026-02-31");
    assert_eq!(date.precision, LibraryDatePrecision::Unclassified);
    assert!(date.timezone.is_none());
}
