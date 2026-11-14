// SPDX-License-Identifier: GPL-3.0-or-later
use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use dansheng_connectors::canvas::*;
use dansheng_connectors::models::SourceContext;
use dansheng_connectors::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport,
};
use serde_json::json;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use url::Url;

const CANVAS: &str = "https://canvas.example.invalid";

fn source() -> SourceContext {
    SourceContext {
        account_id: "user-42".into(),
        source_id: "canvas-main".into(),
        observed_at: Utc.with_ymd_and_hms(2026, 11, 6, 12, 0, 0).unwrap(),
    }
}

fn response(url: &str, body: &[u8]) -> ConnectorResponse {
    ConnectorResponse {
        status: 200,
        final_url: Url::parse(url).unwrap(),
        headers: vec![],
        body: body.to_vec(),
    }
}

#[derive(Clone, Default)]
struct FakeTransport {
    requests: Arc<Mutex<Vec<ConnectorRequest>>>,
    responses: Arc<Mutex<VecDeque<Result<ConnectorResponse, ConnectorError>>>>,
}

impl FakeTransport {
    fn new(responses: Vec<ConnectorResponse>) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into_iter().map(Ok).collect())),
            ..Self::default()
        }
    }
}

#[async_trait]
impl ConnectorTransport for FakeTransport {
    async fn execute(&self, req: ConnectorRequest) -> Result<ConnectorResponse, ConnectorError> {
        self.requests.lock().unwrap().push(req);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected transport request")
    }
}

fn client(transport: FakeTransport, access: CanvasAccess) -> CanvasClient<FakeTransport> {
    CanvasClient::new(transport, CANVAS, access).unwrap()
}
#[tokio::test]
async fn signed_external_links_are_omitted_without_discarding_public_query_links() {
    let body = json!([
        {"id":1,"module_id":7,"title":"AWS fixture","type":"ExternalUrl","external_url":"https://files.example/file?X-Amz-Signature=SYNTHETIC_SECRET"},
        {"id":2,"module_id":7,"title":"GCS fixture","type":"ExternalUrl","external_url":"https://files.example/file?X-Goog-Credential=SYNTHETIC_SECRET"},
        {"id":3,"module_id":7,"title":"Public fixture","type":"ExternalUrl","external_url":"https://video.example/watch?v=public-id"}
    ]);
    let transport = FakeTransport::new(vec![response(
        &format!("{CANVAS}/api/v1/courses/11/modules/7/items?per_page=100"),
        body.to_string().as_bytes(),
    )]);
    let rows = client(transport, CanvasAccess::HostSession)
        .module_items(&source(), "11", "7")
        .await
        .unwrap();
    assert!(rows[0].payload.external_url.is_none());
    assert!(rows[1].payload.external_url.is_none());
    assert_eq!(
        rows[2].payload.external_url.as_deref(),
        Some("https://video.example/watch?v=public-id")
    );
    assert!(
        !serde_json::to_string(&rows)
            .unwrap()
            .contains("SYNTHETIC_SECRET")
    );
}

#[tokio::test]
async fn test_folders_hierarchy_preservation_and_cycle_detection() {
    // 1. Normal hierarchy: root -> folder A -> folder B
    let folders_json = json!([
        {
            "id": 1001,
            "name": "course files",
            "parent_folder_id": null,
            "context_id": 81001,
            "context_type": "Course",
            "files_count": 3,
            "folders_count": 1,
            "created_at": "2026-09-01T00:00:00Z",
            "updated_at": "2026-09-02T00:00:00Z"
        },
        {
            "id": "1002",
            "name": "Lecture Slides",
            "parent_folder_id": 1001,
            "context_id": 81001,
            "context_type": "Course",
            "files_count": 5,
            "folders_count": 1,
            "updated_at": "2026-09-03T00:00:00Z"
        },
        {
            "id": 1003,
            "name": "Week 1",
            "parent_folder_id": "1002",
            "context_id": 81001,
            "context_type": "Course",
            "files_count": 2,
            "folders_count": 0,
            "updated_at": "2026-09-04T00:00:00Z"
        }
    ]);
    let fake = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/folders?per_page=100",
        serde_json::to_vec(&folders_json).unwrap().as_slice(),
    )]);
    let c = client(fake, CanvasAccess::HostToken);
    let records = c.folders(&source(), "81001").await.unwrap();
    assert_eq!(records.len(), 3);
    assert_eq!(records[0].external_id, "folder:81001:1001");
    assert_eq!(records[0].payload.parent_folder_id, None);
    assert_eq!(
        records[1].payload.parent_folder_id,
        Some(CanvasId("1001".into()))
    );
    assert_eq!(
        records[2].payload.parent_folder_id,
        Some(CanvasId("1002".into()))
    );
    assert_eq!(records[0].source_id, "canvas-main");
    assert_eq!(records[0].account_id, "user-42");
    assert!(records[0].updated_at.is_some());

    // 2. Direct cycle: folder 1 parent is 2, folder 2 parent is 1
    let cyclic_json = json!([
        {
            "id": 2001,
            "name": "A",
            "parent_folder_id": 2002,
            "context_id": 81001,
            "context_type": "Course"
        },
        {
            "id": 2002,
            "name": "B",
            "parent_folder_id": 2001,
            "context_id": 81001,
            "context_type": "Course"
        }
    ]);
    let fake_cycle = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/folders?per_page=100",
        serde_json::to_vec(&cyclic_json).unwrap().as_slice(),
    )]);
    assert_eq!(
        client(fake_cycle, CanvasAccess::HostToken)
            .folders(&source(), "81001")
            .await
            .unwrap_err(),
        ConnectorError::PaginationCycle
    );

    // 3. Self-referencing folder cycle: folder 3001 parent is 3001
    let self_cycle_json = json!([
        {
            "id": 3001,
            "name": "Self Parent",
            "parent_folder_id": 3001,
            "context_id": 81001,
            "context_type": "Course"
        }
    ]);
    let fake_self = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/folders?per_page=100",
        serde_json::to_vec(&self_cycle_json).unwrap().as_slice(),
    )]);
    assert_eq!(
        client(fake_self, CanvasAccess::HostToken)
            .folders(&source(), "81001")
            .await
            .unwrap_err(),
        ConnectorError::PaginationCycle
    );

    // 4. Duplicate folder ID collision
    let dup_json = json!([
        {"id": 4001, "name": "Folder 1", "context_id": 81001, "context_type": "Course"},
        {"id": 4001, "name": "Folder 1 dup", "context_id": 81001, "context_type": "Course"}
    ]);
    let fake_dup = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/folders?per_page=100",
        serde_json::to_vec(&dup_json).unwrap().as_slice(),
    )]);
    assert!(matches!(
        client(fake_dup, CanvasAccess::HostToken)
            .folders(&source(), "81001")
            .await,
        Err(ConnectorError::Parse {
            source_name: "Canvas",
            field: "duplicate folder id"
        })
    ));

    // 5. Cross-course folder rejection
    let cross_json = json!([
        {"id": 5001, "name": "Folder X", "context_id": 99999, "context_type": "Course"}
    ]);
    let fake_cross = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/folders?per_page=100",
        serde_json::to_vec(&cross_json).unwrap().as_slice(),
    )]);
    assert!(matches!(
        client(fake_cross, CanvasAccess::HostToken)
            .folders(&source(), "81001")
            .await,
        Err(ConnectorError::Parse {
            source_name: "Canvas",
            field: "folder context_id"
        })
    ));
}

#[tokio::test]
async fn test_modules_and_module_items_identity_and_safe_url() {
    let modules_json = json!([
        {
            "id": 71001,
            "name": "Module 1: Introduction",
            "position": 1,
            "require_sequential_progress": false,
            "prerequisite_module_ids": [],
            "items_count": 2,
            "course_id": 81001,
            "updated_at": "2026-09-10T00:00:00Z"
        }
    ]);
    let fake = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/modules?per_page=100",
        serde_json::to_vec(&modules_json).unwrap().as_slice(),
    )]);
    let c = client(fake, CanvasAccess::HostSession);
    let modules = c.modules(&source(), "81001").await.unwrap();
    assert_eq!(modules.len(), 1);
    assert_eq!(modules[0].external_id, "module:81001:71001");
    assert_eq!(modules[0].payload.name, "Module 1: Introduction");

    // Module items test with URL sanitization and token leakage prevention
    let items_json = json!([
        {
            "id": 91001,
            "module_id": 71001,
            "position": 1,
            "title": "Syllabus Page",
            "type": "Page",
            "page_url": "syllabus",
            "external_url": null,
            "published": true
        },
        {
            "id": 91002,
            "module_id": 71001,
            "position": 2,
            "title": "Reference File",
            "type": "File",
            "content_id": 9007199254740995u64,
            "url": "https://canvas.example.invalid/api/v1/courses/81001/files/9007199254740995?verifier=SECRET_LEAK",
            "published": true
        },
        {
            "id": 91003,
            "module_id": 71001,
            "position": 3,
            "title": "Safe External Doc",
            "type": "ExternalUrl",
            "external_url": "https://docs.example.org/guide",
            "published": true
        },
        {
            "id": 91004,
            "module_id": 71001,
            "position": 4,
            "title": "Leaking External Doc",
            "type": "ExternalUrl",
            "external_url": "https://docs.example.org/guide?access_token=TOP_SECRET",
            "published": true
        },
        {
            "id": 91005,
            "module_id": 71001,
            "position": 5,
            "title": "Javascript External",
            "type": "ExternalUrl",
            "external_url": "javascript:alert(document.cookie)",
            "published": true
        }
    ]);
    let fake_items = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/modules/71001/items?per_page=100",
        serde_json::to_vec(&items_json).unwrap().as_slice(),
    )]);
    let c = client(fake_items, CanvasAccess::HostSession);
    let items = c.module_items(&source(), "81001", "71001").await.unwrap();
    assert_eq!(items.len(), 5);
    // Page slug reference preserved
    assert_eq!(items[0].payload.page_slug.as_deref(), Some("syllabus"));
    // Content ID preserved above JS safe integer
    assert_eq!(
        items[1].payload.content_id,
        Some(CanvasId("9007199254740995".into()))
    );
    // Safe external url retained
    assert_eq!(
        items[2].payload.external_url.as_deref(),
        Some("https://docs.example.org/guide")
    );
    // Leaking external URL sanitized to None
    assert_eq!(items[3].payload.external_url, None);
    // Javascript URL sanitized to None
    assert_eq!(items[4].payload.external_url, None);
    // DTO serialization does not contain tokens
    let serialized = serde_json::to_string(&items).unwrap();
    assert!(!serialized.contains("SECRET_LEAK"));
    assert!(!serialized.contains("TOP_SECRET"));
    assert!(!serialized.contains("javascript:"));

    // Module item mismatch with requested module
    let mismatch_items = json!([
        {
            "id": 91001,
            "module_id": 99999,
            "title": "Wrong Module Item",
            "type": "Page"
        }
    ]);
    let fake_mismatch = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/modules/71001/items?per_page=100",
        serde_json::to_vec(&mismatch_items).unwrap().as_slice(),
    )]);
    assert!(matches!(
        client(fake_mismatch, CanvasAccess::HostSession)
            .module_items(&source(), "81001", "71001")
            .await,
        Err(ConnectorError::Parse {
            source_name: "Canvas",
            field: "module_item module_id"
        })
    ));
}

#[tokio::test]
async fn test_pages_and_page_detail_inert_body_and_path_safety() {
    let pages_json = json!([
        {
            "page_id": 61001,
            "url": "welcome-page",
            "title": "Welcome",
            "published": true,
            "front_page": true,
            "context_id": 81001,
            "context_type": "Course",
            "updated_at": "2026-09-01T10:00:00Z"
        },
        {
            "page_id": 61002,
            "url": "lecture-notes",
            "title": "Lecture Notes",
            "published": true,
            "front_page": false,
            "context_id": 81001,
            "context_type": "Course",
            "updated_at": "2026-09-05T10:00:00Z"
        }
    ]);
    let fake = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/pages?per_page=100",
        serde_json::to_vec(&pages_json).unwrap().as_slice(),
    )]);
    let c = client(fake, CanvasAccess::BrowserSession);
    let list = c.pages(&source(), "81001").await.unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].external_id, "page:81001:welcome-page");
    assert_eq!(list[0].payload.page_slug, "welcome-page");
    assert_eq!(list[0].payload.url(), "welcome-page");
    assert!(list[0].payload.front_page.unwrap());

    // Single page detail fetch
    let detail_json = json!({
        "page_id": 61001,
        "url": "welcome-page",
        "title": "Welcome",
        "body": "<h1>Course Welcome</h1><p>Read chapter 1 <a href=\"https://external.org\">here</a>.</p><script>alert('inert')</script>",
        "published": true,
        "front_page": true,
        "context_id": 81001,
        "context_type": "Course",
        "updated_at": "2026-09-01T10:00:00Z"
    });
    let fake_detail = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/pages/welcome-page",
        serde_json::to_vec(&detail_json).unwrap().as_slice(),
    )]);
    let c = client(fake_detail.clone(), CanvasAccess::BrowserSession);
    let page_record = c.page(&source(), "81001", "welcome-page").await.unwrap();
    assert_eq!(page_record.external_id, "page:81001:welcome-page");
    assert_eq!(page_record.payload.title, "Welcome");
    // Body HTML preserved as inert string
    assert!(
        page_record
            .payload
            .body
            .as_ref()
            .unwrap()
            .contains("<script>alert('inert')</script>")
    );
    // Exactly 1 request executed; no external links fetched
    assert_eq!(fake_detail.requests.lock().unwrap().len(), 1);

    // Mismatched returned page slug
    let mismatch_detail = json!({
        "page_id": 61001,
        "url": "different-slug",
        "title": "Welcome",
        "body": "data"
    });
    let fake_mismatch = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/pages/welcome-page",
        serde_json::to_vec(&mismatch_detail).unwrap().as_slice(),
    )]);
    assert!(matches!(
        client(fake_mismatch, CanvasAccess::BrowserSession)
            .page(&source(), "81001", "welcome-page")
            .await,
        Err(ConnectorError::Parse {
            source_name: "Canvas",
            field: "page slug mismatch"
        })
    ));

    // Duplicate page slug in pages list
    let dup_pages = json!([
        {"url": "syllabus", "title": "Syllabus 1"},
        {"url": "SYLLABUS", "title": "Syllabus Dup"}
    ]);
    let fake_dup = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/pages?per_page=100",
        serde_json::to_vec(&dup_pages).unwrap().as_slice(),
    )]);
    assert!(matches!(
        client(fake_dup, CanvasAccess::BrowserSession)
            .pages(&source(), "81001")
            .await,
        Err(ConnectorError::Parse {
            source_name: "Canvas",
            field: "duplicate page slug"
        })
    ));
}

#[tokio::test]
async fn test_announcements_context_code_and_inert_message() {
    let announcements_json = json!([
        {
            "id": 51001,
            "title": "Midterm Exam Notice",
            "message": "<p>Exam on Monday in Hall A. Check <a href='https://example.invalid'>details</a>.</p>",
            "posted_at": "2026-10-15T08:00:00Z",
            "context_code": "course_81001",
            "read_state": "read",
            "user_name": "Prof. Turing"
        }
    ]);
    let fake = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/discussion_topics?only_announcements=true&per_page=100",
        serde_json::to_vec(&announcements_json).unwrap().as_slice(),
    )]);
    let c = client(fake, CanvasAccess::HostToken);
    let records = c.announcements(&source(), "81001").await.unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].external_id, "announcement:81001:51001");
    assert_eq!(records[0].payload.title, "Midterm Exam Notice");
    assert_eq!(
        records[0].payload.user_name.as_deref(),
        Some("Prof. Turing")
    );
    assert!(
        records[0]
            .payload
            .message
            .as_ref()
            .unwrap()
            .contains("<p>Exam on Monday")
    );

    // Context code mismatch rejection
    let mismatch_json = json!([
        {
            "id": 51002,
            "title": "Wrong Course Notice",
            "context_code": "course_99999"
        }
    ]);
    let fake_mismatch = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/discussion_topics?only_announcements=true&per_page=100",
        serde_json::to_vec(&mismatch_json).unwrap().as_slice(),
    )]);
    assert!(matches!(
        client(fake_mismatch, CanvasAccess::HostToken)
            .announcements(&source(), "81001")
            .await,
        Err(ConnectorError::Parse {
            source_name: "Canvas",
            field: "announcement context_code"
        })
    ));

    // Duplicate announcement ID collision
    let dup_announcements = json!([
        {"id": 51001, "title": "A", "context_code": "course_81001"},
        {"id": 51001, "title": "B", "context_code": "course_81001"}
    ]);
    let fake_dup = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/discussion_topics?only_announcements=true&per_page=100",
        serde_json::to_vec(&dup_announcements).unwrap().as_slice(),
    )]);
    assert!(matches!(
        client(fake_dup, CanvasAccess::HostToken)
            .announcements(&source(), "81001")
            .await,
        Err(ConnectorError::Parse {
            source_name: "Canvas",
            field: "duplicate announcement id"
        })
    ));
}

#[tokio::test]
async fn test_huge_canvas_ids_above_js_safe_integer() {
    // Number greater than Number.MAX_SAFE_INTEGER (9007199254740991)
    let huge_id_val = 9007199254740993u64;
    // 25-digit string ID
    let huge_str_id = "9007199254740993123456789";

    let folders = json!([
        {
            "id": huge_id_val,
            "name": "Huge Folder",
            "parent_folder_id": huge_str_id,
            "context_id": 81001
        }
    ]);
    let fake = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/folders?per_page=100",
        serde_json::to_vec(&folders).unwrap().as_slice(),
    )]);
    let c = client(fake, CanvasAccess::HostToken);
    let records = c.folders(&source(), "81001").await.unwrap();
    assert_eq!(records[0].payload.id.0, "9007199254740993");
    assert_eq!(
        records[0].payload.parent_folder_id,
        Some(CanvasId(huge_str_id.into()))
    );

    // Verify CanvasId rejects empty or non-digit strings
    assert!(serde_json::from_str::<CanvasId>("\"\"").is_err());
    assert!(serde_json::from_str::<CanvasId>("\"123a\"").is_err());
    assert!(serde_json::from_str::<CanvasId>("-1").is_err());
}

#[tokio::test]
async fn test_pagination_and_subsequent_page_failure_fail_closed() {
    let mut page1 = response(
        "https://canvas.example.invalid/api/v1/courses/81001/modules?per_page=100",
        serde_json::to_vec(&json!([{"id": 1, "name": "Module 1"}]))
            .unwrap()
            .as_slice(),
    );
    page1.headers = vec![(
        "Link".into(),
        "<https://canvas.example.invalid/api/v1/courses/81001/modules?page=2>; rel=\"next\"".into(),
    )];

    let mut page2_error = response(
        "https://canvas.example.invalid/api/v1/courses/81001/modules?page=2",
        b"{\"errors\":\"unauthorized\"}",
    );
    page2_error.status = 401;

    let fake = FakeTransport::new(vec![page1, page2_error]);
    let c = client(fake.clone(), CanvasAccess::HostToken);
    let err = c.modules(&source(), "81001").await.unwrap_err();
    // Must fail closed with AuthRequired, not return partial [Module 1]
    assert!(matches!(err, ConnectorError::AuthRequired(_)));
    assert_eq!(fake.requests.lock().unwrap().len(), 2);

    // Multi-page success
    let mut page1_ok = response(
        "https://canvas.example.invalid/api/v1/courses/81001/modules?per_page=100",
        serde_json::to_vec(&json!([{"id": 1, "name": "Module 1"}]))
            .unwrap()
            .as_slice(),
    );
    page1_ok.headers = vec![(
        "Link".into(),
        "<https://canvas.example.invalid/api/v1/courses/81001/modules?page=2>; rel=\"next\"".into(),
    )];
    let page2_ok = response(
        "https://canvas.example.invalid/api/v1/courses/81001/modules?page=2",
        serde_json::to_vec(&json!([{"id": 2, "name": "Module 2"}]))
            .unwrap()
            .as_slice(),
    );
    let fake_ok = FakeTransport::new(vec![page1_ok, page2_ok]);
    let c_ok = client(fake_ok, CanvasAccess::HostToken);
    let res = c_ok.modules(&source(), "81001").await.unwrap();
    assert_eq!(res.len(), 2);
    assert_eq!(res[0].payload.id.0, "1");
    assert_eq!(res[1].payload.id.0, "2");
}

#[tokio::test]
async fn test_path_injection_and_unsafe_url_rejected_before_io() {
    let fake = FakeTransport::default();
    let c = client(fake.clone(), CanvasAccess::HostToken);

    // Path injection on course_id
    for bad_course in [
        "../admin",
        "81001/modules",
        "81001;delete",
        "",
        "   ",
        "81 001",
    ] {
        assert!(matches!(
            c.folders(&source(), bad_course).await,
            Err(ConnectorError::InvalidConfiguration("Canvas course id"))
        ));
        assert!(matches!(
            c.modules(&source(), bad_course).await,
            Err(ConnectorError::InvalidConfiguration("Canvas course id"))
        ));
        assert!(matches!(
            c.module_items(&source(), bad_course, "101").await,
            Err(ConnectorError::InvalidConfiguration("Canvas course id"))
        ));
        assert!(matches!(
            c.pages(&source(), bad_course).await,
            Err(ConnectorError::InvalidConfiguration("Canvas course id"))
        ));
        assert!(matches!(
            c.page(&source(), bad_course, "welcome").await,
            Err(ConnectorError::InvalidConfiguration("Canvas course id"))
        ));
        assert!(matches!(
            c.announcements(&source(), bad_course).await,
            Err(ConnectorError::InvalidConfiguration("Canvas course id"))
        ));
    }

    // Path injection on module_id
    for bad_module in ["../secret", "101/items", "101%2f..", "", "   "] {
        assert!(matches!(
            c.module_items(&source(), "81001", bad_module).await,
            Err(ConnectorError::InvalidConfiguration("Canvas module id"))
        ));
    }

    // Path injection on page_slug
    for bad_slug in [
        "../admin",
        "..",
        ".",
        "secret/page",
        "secret\\page",
        "",
        "   ",
    ] {
        assert!(matches!(
            c.page(&source(), "81001", bad_slug).await,
            Err(ConnectorError::InvalidConfiguration("Canvas page slug"))
        ));
    }

    // No network requests should have been attempted
    assert_eq!(fake.requests.lock().unwrap().len(), 0);
}

#[tokio::test]
async fn test_body_and_item_limits_enforced_without_silent_truncation() {
    // 1. Body limit on page
    let long_body = "x".repeat(1024);
    let page_json = json!({
        "url": "long-page",
        "title": "Long Page",
        "body": long_body
    });
    let fake_page = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/pages/long-page",
        serde_json::to_vec(&page_json).unwrap().as_slice(),
    )]);
    let c = client(fake_page, CanvasAccess::HostToken)
        .with_limits(CanvasLimits {
            max_body_bytes: 512,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        c.page(&source(), "81001", "long-page").await.unwrap_err(),
        ConnectorError::LimitExceeded
    );

    // 2. Body limit on announcement
    let ann_json = json!([
        {
            "id": 1,
            "title": "Long Ann",
            "message": "y".repeat(1024),
            "context_code": "course_81001"
        }
    ]);
    let fake_ann = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/discussion_topics?only_announcements=true&per_page=100",
        serde_json::to_vec(&ann_json).unwrap().as_slice(),
    )]);
    let c_ann = client(fake_ann, CanvasAccess::HostToken)
        .with_limits(CanvasLimits {
            max_body_bytes: 512,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        c_ann.announcements(&source(), "81001").await.unwrap_err(),
        ConnectorError::LimitExceeded
    );

    // 3. Item count limit on folders
    let folders_json = json!([
        {"id": 1, "name": "F1"},
        {"id": 2, "name": "F2"},
        {"id": 3, "name": "F3"}
    ]);
    let fake_items = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/folders?per_page=100",
        serde_json::to_vec(&folders_json).unwrap().as_slice(),
    )]);
    let c_items = client(fake_items, CanvasAccess::HostToken)
        .with_limits(CanvasLimits {
            max_items: 2,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        c_items.folders(&source(), "81001").await.unwrap_err(),
        ConnectorError::LimitExceeded
    );
}

#[tokio::test]
async fn test_assignment_backward_compatibility_and_description() {
    // 1. Old fixture without description/html_url deserializes with None
    let old_assignment = br#"[
        {"id": 82001, "course_id": 81001, "name": "Old essay", "due_at": "2026-11-08T15:59:00Z", "submission_types": ["online_upload"]}
    ]"#;
    let parsed = parse_assignments(old_assignment).unwrap();
    assert_eq!(parsed.len(), 1);
    assert_eq!(parsed[0].id.0, "82001");
    assert_eq!(parsed[0].description, None);
    assert_eq!(parsed[0].html_url, None);
    assert_eq!(parsed[0].published, None);

    // 2. New fixture with HTML description and published
    let new_assignment = json!([
        {
            "id": 82002,
            "course_id": 81001,
            "name": "New Essay with Details",
            "due_at": "2026-11-10T12:00:00Z",
            "submission_types": ["online_upload"],
            "published": true,
            "description": "<h2>Essay Prompt</h2><p>Write about Rust local-first core.</p>",
            "html_url": "https://canvas.example.invalid/courses/81001/assignments/82002"
        }
    ]);
    let fake = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/assignments?per_page=100",
        serde_json::to_vec(&new_assignment).unwrap().as_slice(),
    )]);
    let c = client(fake, CanvasAccess::HostToken);
    let records = c.assignments(&source(), "81001").await.unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].payload.published, Some(true));
    assert!(
        records[0]
            .payload
            .description
            .as_ref()
            .unwrap()
            .contains("<h2>Essay Prompt</h2>")
    );

    // 3. Assignment description exceeding max_body_bytes fails closed
    let huge_desc_assignment = json!([
        {
            "id": 82003,
            "course_id": 81001,
            "name": "Huge Desc Essay",
            "description": "z".repeat(1024)
        }
    ]);
    let fake_huge = FakeTransport::new(vec![response(
        "https://canvas.example.invalid/api/v1/courses/81001/assignments?per_page=100",
        serde_json::to_vec(&huge_desc_assignment)
            .unwrap()
            .as_slice(),
    )]);
    let c_huge = client(fake_huge, CanvasAccess::HostToken)
        .with_limits(CanvasLimits {
            max_body_bytes: 256,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        c_huge.assignments(&source(), "81001").await.unwrap_err(),
        ConnectorError::LimitExceeded
    );
}

#[tokio::test]
async fn test_pagination_and_single_resource_reject_cross_collection_paths() {
    // 1. courses/11/modules pagination Link pointing to courses/12/modules (same origin).
    // DTO omits course_id to prove rejection is enforced at the collection path level before sending request 2.
    let mut page1 = response(
        "https://canvas.example.invalid/api/v1/courses/11/modules?per_page=100",
        serde_json::to_vec(&json!([{"id": 101, "name": "Module 1"}]))
            .unwrap()
            .as_slice(),
    );
    page1.headers = vec![(
        "Link".into(),
        "<https://canvas.example.invalid/api/v1/courses/12/modules?page=2>; rel=\"next\"".into(),
    )];

    let fake = FakeTransport::new(vec![page1]);
    let c = client(fake.clone(), CanvasAccess::HostToken);
    let err = c.modules(&source(), "11").await.unwrap_err();
    assert_eq!(err, ConnectorError::UnsafeUrl);
    // Verified: exactly 1 request was executed; the cross-collection 2nd page request was blocked!
    assert_eq!(fake.requests.lock().unwrap().len(), 1);

    // 2. courses/11/modules pagination Link pointing to /api/v1/users/... (same origin)
    let mut page1_user = response(
        "https://canvas.example.invalid/api/v1/courses/11/modules?per_page=100",
        serde_json::to_vec(&json!([{"id": 101, "name": "Module 1"}]))
            .unwrap()
            .as_slice(),
    );
    page1_user.headers = vec![(
        "Link".into(),
        "</api/v1/users/self/modules>; rel=\"next\"".into(),
    )];
    let fake_user = FakeTransport::new(vec![page1_user]);
    let c_user = client(fake_user.clone(), CanvasAccess::HostToken);
    assert_eq!(
        c_user.modules(&source(), "11").await.unwrap_err(),
        ConnectorError::UnsafeUrl
    );
    assert_eq!(fake_user.requests.lock().unwrap().len(), 1);

    // 3. Single resource (page) response.final_url path differs from requested resource path
    let redirected_page = response(
        "https://canvas.example.invalid/api/v1/courses/11/pages/another-page",
        serde_json::to_vec(&json!({
            "url": "another-page",
            "title": "Another Page",
            "body": "<p>Redirected away</p>"
        }))
        .unwrap()
        .as_slice(),
    );
    let fake_single = FakeTransport::new(vec![redirected_page]);
    let c_single = client(fake_single.clone(), CanvasAccess::HostToken);
    let err_single = c_single.page(&source(), "11", "welcome").await.unwrap_err();
    assert_eq!(err_single, ConnectorError::UnsafeUrl);
    assert_eq!(fake_single.requests.lock().unwrap().len(), 1);
}
