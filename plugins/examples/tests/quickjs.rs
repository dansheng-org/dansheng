//! Development harness compiled by run-quickjs.ps1 against the actual plugin module.
use async_trait::async_trait;
use dansheng_examples_validation::plugins::{
    PluginError, PluginHost, PluginLimits, PluginManifest, PluginRunner,
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{Arc, Mutex},
};

#[derive(Default)]
struct Host {
    calls: Mutex<Vec<(String, Value)>>,
    replies: Mutex<VecDeque<Value>>,
    authenticated: bool,
}

#[async_trait]
impl PluginHost for Host {
    async fn call(
        &self,
        plugin_id: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, PluginError> {
        self.calls
            .lock()
            .unwrap()
            .push((method.into(), params.clone()));
        match method {
            "storage.get" => {
                assert_eq!(params, json!({"key":"last-check"}));
                Ok(Value::Null)
            }
            "storage.set" => {
                assert_eq!(params["key"], "last-check");
                Ok(Value::Null)
            }
            "ui.publish" => {
                assert!(matches!(
                    params["component"]["type"].as_str(),
                    Some("card" | "list")
                ));
                Ok(json!({"sequence": 1}))
            }
            "auth.status" => Ok(json!({"authenticated":self.authenticated})),
            "auth.requireLogin" => Err(PluginError::new(
                "AuthenticationRequired",
                "complete authentication through the trusted platform adapter",
            )),
            "http.request" => {
                assert_eq!(params["method"], "GET");
                if plugin_id != "official.http-monitor" {
                    assert_eq!(params["account_id"], "test-account");
                }
                self.replies
                    .lock()
                    .unwrap()
                    .pop_front()
                    .ok_or_else(|| PluginError::new("UNEXPECTED_IO", "No offline response queued"))
            }
            "sources.upsert" => {
                assert!(
                    params["source_id"]
                        .as_str()
                        .unwrap()
                        .starts_with(&format!("{plugin_id}."))
                );
                assert!(matches!(
                    params["kind"].as_str(),
                    Some("canvas.course" | "fudan.timetable")
                ));
                Ok(json!({"id":"synthetic-record"}))
            }
            "sources.query" => Ok(json!([])),
            "jobs.schedule" => {
                assert_eq!(params["plugin_id"], plugin_id);
                assert_eq!(params["action"], "check");
                assert!(params["run_at"].is_string());
                Ok(json!({"job_id":"synthetic-job"}))
            }
            _ => Err(PluginError::new(
                "UNEXPECTED_METHOD",
                "Undeclared host method",
            )),
        }
    }
}

async fn run(
    package: &str,
    action: &str,
    input: Value,
    host: Arc<Host>,
) -> Result<Value, PluginError> {
    let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("examples")
        .join(package);
    let manifest =
        PluginManifest::from_slice(&std::fs::read(directory.join("manifest.json")).unwrap())
            .unwrap();
    PluginRunner::run(
        directory,
        manifest,
        action.into(),
        input,
        host,
        PluginLimits::default(),
    )
    .await
}

#[tokio::test]
async fn http_monitor_executes_in_actual_quickjs_and_calls_host_storage_and_ui() {
    let host = Arc::new(Host {
        replies: Mutex::new(VecDeque::from([
            json!({"status":200,"body":"SYNTHETIC-NON-CREDENTIAL"}),
        ])),
        ..Host::default()
    });
    let result = run("http-monitor", "check", json!({}), host.clone())
        .await
        .unwrap();
    assert_eq!(result["status"], 200);
    assert_eq!(result["changed"], false);
    let calls = host.calls.lock().unwrap();
    assert_eq!(
        calls
            .iter()
            .map(|(method, _)| method.as_str())
            .collect::<Vec<_>>(),
        ["storage.get", "http.request", "storage.set", "ui.publish"]
    );
    assert!(
        !serde_json::to_string(&*calls)
            .unwrap()
            .contains("SYNTHETIC-NON-CREDENTIAL")
    );
}

#[tokio::test]
async fn canvas_session_paginates_and_saves_namespaced_sources_in_quickjs() {
    let host = Arc::new(Host {
        authenticated: true,
        replies: Mutex::new(VecDeque::from([
            json!({"status":200,"body":"[]","headers":{"LiNk":"<https://elearning.fudan.edu.cn/api/v1/courses?cursor=opaque>; rel=\"next\""}}),
            json!({"status":200,"body":"[{\"id\":\"9007199254740993\",\"name\":\"Synthetic course\"}]","headers":{}}),
        ])),
        ..Host::default()
    });
    let result = run(
        "canvas-courses",
        "syncCourses",
        json!({"account_id":"test-account"}),
        host.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result["status"], "synced");
    assert_eq!(result["count"], 1);
    let calls = host.calls.lock().unwrap();
    assert_eq!(calls.iter().filter(|(m, _)| m == "http.request").count(), 2);
    assert!(!calls.iter().any(|(m, _)| m == "browser.request"));
    assert!(calls.iter().any(|(m, p)| m == "sources.upsert"
        && p["external_id"] == "test-account:course:9007199254740993"));
}

#[tokio::test]
async fn auth_required_host_error_becomes_an_explicit_result_without_network_or_cache_writes() {
    let host = Arc::new(Host::default());
    let result = run(
        "canvas-courses",
        "syncCourses",
        json!({"account_id":"test-account"}),
        host.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result["status"], "auth_required");
    assert_eq!(result["challenge"]["code"], "AuthenticationRequired");
    assert_eq!(host.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn scheduled_action_uses_host_job_wire_shape_in_quickjs() {
    let host = Arc::new(Host::default());
    let result = run(
        "http-monitor",
        "schedule",
        json!({"run_at":"2099-01-01T00:00:00Z"}),
        host,
    )
    .await
    .unwrap();
    assert_eq!(result["job_id"], "synthetic-job");
}

#[tokio::test]
async fn fudan_undergraduate_session_and_parser_execute_in_quickjs() {
    let body = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/undergraduate.json"),
    )
    .unwrap();
    let host = Arc::new(Host {
        authenticated: true,
        replies: Mutex::new(VecDeque::from([json!({"status":200,"body":body})])),
        ..Host::default()
    });
    let result = run(
        "fudan-timetable",
        "syncUndergraduate",
        json!({"account_id":"test-account","semester_id":"901","starts_on":"2026-03-02"}),
        host.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result["count"], 2);
    let calls = host.calls.lock().unwrap();
    let courses: Vec<_> = calls
        .iter()
        .filter(|(m, _)| m == "sources.upsert")
        .collect();
    assert_eq!(courses[1].1["data"]["weeks"], json!([0, 1, 2]));
    assert_eq!(calls.iter().filter(|(m, _)| m == "http.request").count(), 1);
    assert!(!calls.iter().any(|(m, _)| m == "browser.request"));
}

#[tokio::test]
async fn fudan_postgraduate_session_and_bitmap_execute_in_quickjs() {
    let body = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/postgraduate.json"),
    )
    .unwrap();
    let host = Arc::new(Host {
        authenticated: true,
        replies: Mutex::new(VecDeque::from([json!({"status":200,"body":body})])),
        ..Host::default()
    });
    let result = run(
        "fudan-timetable",
        "syncPostgraduate",
        json!({"account_id":"test-account","semester_id":"current","starts_on":"2026-03-02"}),
        host.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result["count"], 2);
    let calls = host.calls.lock().unwrap();
    let courses: Vec<_> = calls
        .iter()
        .filter(|(m, _)| m == "sources.upsert")
        .collect();
    assert_eq!(courses[0].1["data"]["weeks"], json!([1, 3, 5]));
}
