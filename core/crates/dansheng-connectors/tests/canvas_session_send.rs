use async_trait::async_trait;
use chrono::Utc;
use dansheng_connectors::{
    ConnectorError, ConnectorRequest, ConnectorResponse, ConnectorTransport, HttpMethod,
    TransportAuth,
    canvas::{CanvasAccess, CanvasClient, CanvasWriteError},
    models::SourceContext,
};
use std::sync::{Arc, Mutex};

const ORIGIN: &str = "https://elearning.fudan.edu.cn";
#[derive(Clone)]
struct Trusted {
    dispatched: Arc<Mutex<Vec<ConnectorRequest>>>,
    preflight: Option<ConnectorError>,
    status: u16,
    lose_response: bool,
}
#[async_trait]
impl ConnectorTransport for Trusted {
    async fn execute(&self, _: ConnectorRequest) -> Result<ConnectorResponse, ConnectorError> {
        panic!("session writes must never use ordinary execute or browser fallback")
    }
    async fn execute_canvas_session_write(
        &self,
        request: ConnectorRequest,
    ) -> Result<ConnectorResponse, CanvasWriteError> {
        if let Some(error) = &self.preflight {
            return Err(error.clone().into());
        }
        assert!(
            matches!(&request.auth, TransportAuth::HostSession { account_id } if account_id=="fixture")
        );
        assert_eq!(request.method, HttpMethod::Post);
        assert!(
            !request
                .headers
                .iter()
                .any(|(name, _)| name.to_lowercase().contains("csrf")
                    || name.eq_ignore_ascii_case("cookie"))
        );
        let final_url = request.url.clone();
        let body = if final_url.path().ends_with("add_message") {
            br#"{"id":"9","messages":[{"id":"10","body":"draft"}]}"#.to_vec()
        } else {
            br#"[{"id":"9"}]"#.to_vec()
        };
        self.dispatched.lock().unwrap().push(request);
        if self.lose_response {
            return Err(CanvasWriteError::NeedsReconciliation);
        }
        Ok(ConnectorResponse {
            status: self.status,
            final_url,
            headers: vec![],
            body,
        })
    }
}
fn fixture() -> Trusted {
    Trusted {
        dispatched: Default::default(),
        preflight: None,
        status: 200,
        lose_response: false,
    }
}
fn source() -> SourceContext {
    SourceContext {
        account_id: "fixture".into(),
        source_id: "fixture".into(),
        observed_at: Utc::now(),
    }
}

#[tokio::test]
async fn csrf_permission_preflight_and_dispatch_outcomes_stay_distinct_without_retries() {
    for error in [
        ConnectorError::CanvasCsrfRequired,
        ConnectorError::PermissionDenied,
        ConnectorError::CapabilityUnavailable,
    ] {
        let mut fake = fixture();
        fake.preflight = Some(error.clone());
        let client = CanvasClient::new(fake.clone(), ORIGIN, CanvasAccess::HostSession).unwrap();
        assert!(
            matches!(client.reply_conversation(&source(), "9", "draft").await,
            Err(CanvasWriteError::Rejected(actual)) if actual==error)
        );
        assert!(fake.dispatched.lock().unwrap().is_empty());
    }
    for (status, lost) in [(200, true), (503, false), (302, false)] {
        let mut fake = fixture();
        fake.status = status;
        fake.lose_response = lost;
        let client = CanvasClient::new(fake.clone(), ORIGIN, CanvasAccess::HostSession).unwrap();
        assert!(matches!(
            client.reply_conversation(&source(), "9", "draft").await,
            Err(CanvasWriteError::NeedsReconciliation)
        ));
        assert_eq!(fake.dispatched.lock().unwrap().len(), 1);
    }
    let fake = fixture();
    let client = CanvasClient::new(fake.clone(), ORIGIN, CanvasAccess::HostSession).unwrap();
    assert_eq!(
        client
            .reply_conversation(&source(), "9", "draft")
            .await
            .unwrap()
            .payload
            .id
            .0,
        "9"
    );
    client
        .create_conversation(
            &source(),
            "42",
            &[dansheng_connectors::canvas::CanvasId("7".into())],
            "subject",
            "draft",
        )
        .await
        .unwrap();
    assert_eq!(fake.dispatched.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn browser_and_untrusted_origin_never_dispatch() {
    for (origin, access) in [
        (ORIGIN, CanvasAccess::BrowserSession),
        ("https://other.invalid", CanvasAccess::HostSession),
    ] {
        let fake = fixture();
        let client = CanvasClient::new(fake.clone(), origin, access).unwrap();
        assert!(matches!(
            client.reply_conversation(&source(), "9", "draft").await,
            Err(CanvasWriteError::Rejected(
                ConnectorError::CapabilityUnavailable
            ))
        ));
        assert!(fake.dispatched.lock().unwrap().is_empty());
    }
}
