use anyhow::{Context, Result};
use axum::{
    body::Body,
    extract::{Query, Request, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{any, get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::Mutex as AsyncMutex;
use tower_http::cors::CorsLayer;
use std::convert::Infallible;
use tokio_stream::wrappers::ReceiverStream;
use tower_http::services::ServeDir;

use crate::dashboard_db::{
    checkpoint_dashboard_db, ensure_dashboard_db,
    export_account_card_marks_payload, export_accounts_summary_payload,
    export_dashboard_rows_page, read_dashboard_db_build_progress, stream_dashboard_rows_ndjson,
    sync_dashboard_db, sync_dashboard_db_if_dirty, DashboardDbBuildProgress, ProgressHandle,
};

const SHUTDOWN_DELAY: Duration = Duration::from_secs(3);

#[derive(Clone, Default)]
struct ShutdownControl {
    deadline: Arc<Mutex<Option<Instant>>>,
}

impl ShutdownControl {
    fn cancel(&self) {
        *self.deadline.lock().unwrap() = None;
    }

    fn schedule(&self) {
        *self.deadline.lock().unwrap() = Some(Instant::now() + SHUTDOWN_DELAY);
    }

    fn is_due(&self) -> bool {
        self.deadline
            .lock()
            .unwrap()
            .is_some_and(|deadline| Instant::now() >= deadline)
    }
}

#[derive(Clone)]
pub struct ServeState {
    root: PathBuf,
    legacy_port: u16,
    client: reqwest::Client,
    shutdown: ShutdownControl,
    db_progress: ProgressHandle,
    db_ensure_mutex: Arc<AsyncMutex<()>>,
    sync_mutex: Arc<AsyncMutex<()>>,
    active_row_streams: Arc<AtomicUsize>,
}

#[derive(Debug, Deserialize)]
struct RowsPageQuery {
    #[serde(default)]
    offset: usize,
    #[serde(default = "default_rows_page_limit")]
    limit: usize,
}

fn default_rows_page_limit() -> usize {
    25000
}

pub async fn run_serve(
    root: &Path,
    port: u16,
    legacy_port: u16,
    background_sync_interval_secs: u64,
) -> Result<()> {
    let db_progress = Arc::new(Mutex::new(read_dashboard_db_build_progress(root)));

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .build()
        .context("Could not create HTTP client")?;

    let state = ServeState {
        root: root.to_path_buf(),
        legacy_port,
        client,
        shutdown: ShutdownControl::default(),
        db_progress,
        db_ensure_mutex: Arc::new(AsyncMutex::new(())),
        sync_mutex: Arc::new(AsyncMutex::new(())),
        active_row_streams: Arc::new(AtomicUsize::new(0)),
    };

    let static_files = ServeDir::new(state.root.clone());

    let dashboard_routes = Router::new()
        .route("/ping", get(ping))
        .route("/shutdown", post(post_dashboard_shutdown))
        .route("/ui-prefs", get(get_ui_prefs).post(post_ui_prefs))
        .route(
            "/database-index/status",
            get(get_database_index_status),
        )
        .route(
            "/database-index/ensure",
            post(post_database_index_ensure),
        )
        .route("/accounts-summary", get(get_accounts_summary_compat))
        .route("/dashboard-rows", get(get_dashboard_rows_compat))
        .route("/dashboard-rows-page", get(get_dashboard_rows_page_compat))
        .route("/account-card-marks", get(get_account_card_marks_compat).post(post_account_card_marks_compat))
        .route("/account-trade-marks", get(get_account_card_marks_compat).post(post_account_card_marks_compat))
        .fallback(any(proxy_legacy));

    spawn_background_sync(state.clone(), background_sync_interval_secs);
    spawn_shutdown_monitor(state.clone());

    let app = Router::new()
        .nest("/__dashboard", dashboard_routes)
        .route("/Helper/cardmap.json", get(get_cardmap))
        .fallback_service(static_files)
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    eprintln!("carddb serve listening on http://{addr}");
    eprintln!("  root: {}", root.display());
    eprintln!("  legacy proxy: http://127.0.0.1:{legacy_port}/__dashboard/*");

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("Could not bind to port {port}"))?;

    axum::serve(listener, app)
        .await
        .context("HTTP server stopped with error")?;
    Ok(())
}

async fn get_cardmap(State(state): State<ServeState>) -> Result<Response, AppError> {
    let root = state.root.clone();
    let bytes = tokio::task::spawn_blocking(move || {
        let path = crate::ensure_cardmap(&root)?;
        std::fs::read(&path).with_context(|| format!("Could not read {:?}", path))
    })
    .await
    .context("cardmap download task failed")??;

    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/json; charset=utf-8"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        bytes,
    )
        .into_response())
}

fn spawn_background_sync(state: ServeState, interval_secs: u64) {
    tokio::spawn(async move {
        let every = Duration::from_secs(interval_secs.max(5));
        let mut interval = tokio::time::interval(every);
        interval.tick().await;
        loop {
            interval.tick().await;
            if state.shutdown.is_due() {
                break;
            }
            if state.active_row_streams.load(Ordering::SeqCst) > 0 {
                continue;
            }
            let _guard = match state.sync_mutex.try_lock() {
                Ok(guard) => guard,
                Err(_) => continue,
            };
            if state.active_row_streams.load(Ordering::SeqCst) > 0 {
                continue;
            }
            let root = state.root.clone();
            let result = tokio::task::spawn_blocking(move || sync_dashboard_db(&root, None))
                .await;
            match result {
                Ok(Ok(sync)) if sync.reindexed_accounts > 0 => {
                    eprintln!(
                        "dashboard background sync: {} account(s) updated in {} ms ({} dirty)",
                        sync.reindexed_accounts, sync.elapsed_ms, sync.dirty_accounts
                    );
                }
                Ok(Err(err)) => eprintln!("dashboard background sync failed: {err:#}"),
                Err(err) => eprintln!("dashboard background sync join failed: {err:#}"),
                _ => {}
            }
        }
    });
}

fn spawn_shutdown_monitor(state: ServeState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(200));
        loop {
            interval.tick().await;
            if state.shutdown.is_due() {
                eprintln!("carddb serve shutting down (dashboard closed)");
                std::process::exit(0);
            }
        }
    });
}

fn notify_legacy_ping(client: &reqwest::Client, legacy_port: u16) {
    let client = client.clone();
    tokio::spawn(async move {
        let _ = client
            .get(format!(
                "http://127.0.0.1:{legacy_port}/__dashboard/ping"
            ))
            .send()
            .await;
    });
}

fn notify_legacy_shutdown(client: &reqwest::Client, legacy_port: u16) {
    let client = client.clone();
    tokio::spawn(async move {
        let _ = client
            .post(format!(
                "http://127.0.0.1:{legacy_port}/__dashboard/shutdown"
            ))
            .body("close")
            .send()
            .await;
    });
}

fn with_conn<T>(root: &Path, f: impl FnOnce(&rusqlite::Connection) -> Result<T>) -> Result<T> {
    let conn = crate::dashboard_db::open_connection_public(root)?;
    crate::dashboard_db::init_schema_public(&conn)?;
    f(&conn)
}

async fn ping(State(state): State<ServeState>) -> StatusCode {
    state.shutdown.cancel();
    notify_legacy_ping(&state.client, state.legacy_port);
    StatusCode::NO_CONTENT
}

const UI_PREFS_CARD_SIZES: [u32; 4] = [96, 120, 150, 190];
const UI_PREFS_PAGE_SIZES: [u32; 4] = [10, 25, 50, 100];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DashboardUiPrefs {
    #[serde(default = "default_ui_prefs_language")]
    language: String,
    #[serde(default = "default_ui_prefs_theme")]
    theme: String,
    #[serde(default = "default_ui_prefs_card_size")]
    card_size: u32,
    #[serde(default = "default_ui_prefs_page_size")]
    page_size: u32,
    #[serde(default)]
    use_local_card_images: bool,
}

fn default_ui_prefs_language() -> String {
    "en_US".into()
}
fn default_ui_prefs_theme() -> String {
    "dark".into()
}
fn default_ui_prefs_card_size() -> u32 {
    120
}
fn default_ui_prefs_page_size() -> u32 {
    25
}

fn ui_prefs_path(root: &Path) -> PathBuf {
    root.join("Accounts").join("Cards").join(".dashboard_ui_prefs.json")
}

fn normalize_ui_prefs(raw: Option<DashboardUiPrefs>) -> DashboardUiPrefs {
    let mut prefs = raw.unwrap_or(DashboardUiPrefs {
        language: default_ui_prefs_language(),
        theme: default_ui_prefs_theme(),
        card_size: default_ui_prefs_card_size(),
        page_size: default_ui_prefs_page_size(),
        use_local_card_images: false,
    });
    if prefs.language.trim().is_empty() {
        prefs.language = default_ui_prefs_language();
    }
    if prefs.theme != "light" && prefs.theme != "dark" {
        prefs.theme = default_ui_prefs_theme();
    }
    if !UI_PREFS_CARD_SIZES.contains(&prefs.card_size) {
        prefs.card_size = default_ui_prefs_card_size();
    }
    if !UI_PREFS_PAGE_SIZES.contains(&prefs.page_size) {
        prefs.page_size = default_ui_prefs_page_size();
    }
    prefs
}

fn read_ui_prefs(root: &Path) -> DashboardUiPrefs {
    let path = ui_prefs_path(root);
    match std::fs::read_to_string(&path) {
        Ok(text) => normalize_ui_prefs(serde_json::from_str(&text).ok()),
        Err(_) => normalize_ui_prefs(None),
    }
}

fn write_ui_prefs(root: &Path, prefs: &DashboardUiPrefs) -> Result<()> {
    let path = ui_prefs_path(root);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Could not create {:?}", parent))?;
    }
    let json = serde_json::to_string_pretty(prefs).context("Could not serialize ui prefs")?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json.as_bytes())
        .with_context(|| format!("Could not write {:?}", tmp))?;
    std::fs::rename(&tmp, &path)
        .with_context(|| format!("Could not replace {:?}", path))?;
    Ok(())
}

async fn get_ui_prefs(State(state): State<ServeState>) -> Result<Response, AppError> {
    let root = state.root.clone();
    let prefs = tokio::task::spawn_blocking(move || read_ui_prefs(&root))
        .await
        .context("ui-prefs read join failed")?;
    Ok(json_response(json!({
        "ok": true,
        "language": prefs.language,
        "theme": prefs.theme,
        "cardSize": prefs.card_size,
        "pageSize": prefs.page_size,
        "useLocalCardImages": prefs.use_local_card_images,
    })))
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UiPrefsPatch {
    language: Option<String>,
    theme: Option<String>,
    card_size: Option<u32>,
    page_size: Option<u32>,
    use_local_card_images: Option<bool>,
}

async fn post_ui_prefs(
    State(state): State<ServeState>,
    Json(patch): Json<UiPrefsPatch>,
) -> Result<Response, AppError> {
    let root = state.root.clone();
    let prefs = tokio::task::spawn_blocking(move || {
        let mut current = read_ui_prefs(&root);
        if let Some(language) = patch.language {
            if !language.trim().is_empty() {
                current.language = language;
            }
        }
        if let Some(theme) = patch.theme {
            current.theme = theme;
        }
        if let Some(card_size) = patch.card_size {
            current.card_size = card_size;
        }
        if let Some(page_size) = patch.page_size {
            current.page_size = page_size;
        }
        if let Some(use_local) = patch.use_local_card_images {
            current.use_local_card_images = use_local;
        }
        let normalized = normalize_ui_prefs(Some(current));
        write_ui_prefs(&root, &normalized)?;
        Ok::<_, anyhow::Error>(normalized)
    })
    .await
    .context("ui-prefs write join failed")??;

    Ok(json_response(json!({
        "ok": true,
        "language": prefs.language,
        "theme": prefs.theme,
        "cardSize": prefs.card_size,
        "pageSize": prefs.page_size,
        "useLocalCardImages": prefs.use_local_card_images,
    })))
}

async fn post_dashboard_shutdown(State(state): State<ServeState>) -> StatusCode {
    state.shutdown.schedule();
    notify_legacy_shutdown(&state.client, state.legacy_port);
    StatusCode::ACCEPTED
}

fn active_build_phase(phase: &str) -> bool {
    matches!(
        phase,
        "starting" | "scanning" | "indexing" | "syncing" | "checkpoint"
    )
}

async fn get_database_index_status(
    State(state): State<ServeState>,
) -> Result<Response, AppError> {
    let live = state.db_progress.lock().unwrap().clone();
    if active_build_phase(&live.phase) {
        return Ok(json_response(serde_json::to_value(live)?));
    }

    let root = state.root.clone();
    let disk = tokio::task::spawn_blocking(move || read_dashboard_db_build_progress(&root))
        .await
        .context("database index status join failed")?;
    Ok(json_response(serde_json::to_value(disk)?))
}

async fn post_database_index_ensure(
    State(state): State<ServeState>,
) -> Result<Response, AppError> {
    let _guard = state.db_ensure_mutex.lock().await;
    let root = state.root.clone();
    let progress = state.db_progress.clone();
    {
        let mut live = progress.lock().unwrap();
        *live = DashboardDbBuildProgress {
            phase: "starting".into(),
            mode: String::new(),
            message: "Preparing SQLite index…".into(),
            ..DashboardDbBuildProgress::default()
        };
    }

    let result = tokio::task::spawn_blocking(move || ensure_dashboard_db(&root, Some(progress)))
        .await
        .context("database index ensure join failed")??;

    Ok(json_response(serde_json::to_value(result)?))
}

async fn sync_if_dirty_blocking(state: &ServeState) -> Result<(), AppError> {
    let _guard = state.sync_mutex.lock().await;
    let root = state.root.clone();
    tokio::task::spawn_blocking(move || sync_dashboard_db_if_dirty(&root))
        .await
        .context("sync-if-dirty join failed")??;
    Ok(())
}

async fn get_accounts_summary_compat(
    State(state): State<ServeState>,
) -> Result<Response, AppError> {
    sync_if_dirty_blocking(&state).await?;
    let root = state.root.clone();
    let payload = tokio::task::spawn_blocking(move || export_accounts_summary_payload(&root))
        .await
        .context("summary export join failed")??;
    Ok(json_response(payload))
}

async fn get_dashboard_rows_page_compat(
    State(state): State<ServeState>,
    Query(query): Query<RowsPageQuery>,
) -> Result<Response, AppError> {
    let root = state.root.clone();
    let offset = query.offset;
    let limit = query.limit.clamp(1, 50_000);
    let payload = tokio::task::spawn_blocking(move || {
        with_conn(&root, |conn| export_dashboard_rows_page(conn, offset, limit))
    })
    .await
    .context("rows page export join failed")??;
    Ok(json_response(payload))
}

async fn get_dashboard_rows_compat(State(state): State<ServeState>) -> Result<Response, AppError> {
    sync_if_dirty_blocking(&state).await?;
    let root = state.root.clone();
    state.active_row_streams.fetch_add(1, Ordering::SeqCst);
    let active_row_streams = state.active_row_streams.clone();
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<bytes::Bytes, Infallible>>(32);
    tokio::task::spawn_blocking(move || {
        let stream_result = stream_dashboard_rows_ndjson(root.clone(), tx);
        active_row_streams.fetch_sub(1, Ordering::SeqCst);
        if let Err(err) = stream_result {
            eprintln!("dashboard rows stream failed: {err}");
        }
        if let Err(err) = checkpoint_dashboard_db(&root) {
            eprintln!("dashboard db checkpoint after rows stream failed: {err}");
        }
    });
    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/x-ndjson; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        Body::from_stream(ReceiverStream::new(rx)),
    )
        .into_response())
}

async fn get_account_card_marks_compat(
    State(state): State<ServeState>,
) -> Result<Response, AppError> {
    let root = state.root.clone();
    let payload = tokio::task::spawn_blocking(move || export_account_card_marks_payload(&root))
        .await
        .context("card marks export join failed")??;
    Ok(json_response(payload))
}

async fn post_account_card_marks_compat(
    State(state): State<ServeState>,
    request: Request<Body>,
) -> Result<Response, AppError> {
    let body = axum::body::to_bytes(request.into_body(), 8 * 1024 * 1024)
        .await
        .context("Could not read card marks body")?;
    if body.is_empty() {
        return Ok(json_error_response(
            StatusCode::BAD_REQUEST,
            "Empty request body.",
        ));
    }
    let payload: Value = match serde_json::from_slice(&body) {
        Ok(value) => value,
        Err(_) => {
            return Ok(json_error_response(
                StatusCode::BAD_REQUEST,
                "Invalid JSON body.",
            ))
        }
    };
    let root = state.root.clone();
    let outcome = tokio::task::spawn_blocking(move || {
        crate::set_account_card_marks_from_payload(&root, payload)
    })
    .await
    .context("card marks write join failed")?;
    let status =
        StatusCode::from_u16(outcome.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    Ok(json_response_with_status(status, outcome.payload))
}

fn json_error_response(status: StatusCode, message: &str) -> Response {
    json_response_with_status(status, json!({ "ok": false, "error": message }))
}

fn json_response_with_status(status: StatusCode, payload: Value) -> Response {
    (
        status,
        [(header::CONTENT_TYPE, "application/json; charset=utf-8")],
        payload.to_string(),
    )
        .into_response()
}

async fn proxy_legacy(
    State(state): State<ServeState>,
    request: Request<Body>,
) -> Result<Response, AppError> {
    let method = request.method().clone();
    let uri = request.uri().clone();
    let headers = request.headers().clone();
    let body = axum::body::to_bytes(request.into_body(), 32 * 1024 * 1024)
        .await
        .context("Could not read proxy request body")?;

    let path_and_query = uri
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/__dashboard/");
    let legacy_path = if path_and_query.starts_with("/__dashboard/") {
        path_and_query.to_string()
    } else if path_and_query.starts_with('/') {
        format!("/__dashboard{path_and_query}")
    } else {
        format!("/__dashboard/{path_and_query}")
    };
    let target = format!("http://127.0.0.1:{}{}", state.legacy_port, legacy_path);

    let mut builder = state.client.request(method.clone(), &target);
    for (name, value) in headers.iter() {
        if name == header::HOST || name == header::CONNECTION {
            continue;
        }
        builder = builder.header(name, value);
    }
    if !body.is_empty() {
        builder = builder.body(body.to_vec());
    }

    let response = builder
        .send()
        .await
        .with_context(|| format!("Legacy proxy request failed for {method} {target}"))?;

    let status =
        StatusCode::from_u16(response.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let resp_headers = response.headers().clone();
    let body = response
        .bytes()
        .await
        .context("Could not read legacy proxy response")?;
    let mut out = Response::builder()
        .status(status)
        .body(Body::from(body))
        .unwrap_or_else(|_| Response::new(Body::empty()));
    let out_headers = out.headers_mut();
    for (name, value) in resp_headers.iter() {
        if name == header::TRANSFER_ENCODING || name == header::CONNECTION {
            continue;
        }
        out_headers.insert(name, value.clone());
    }
    Ok(out)
}

fn json_response(payload: Value) -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/json; charset=utf-8")],
        payload.to_string(),
    )
        .into_response()
}

struct AppError(anyhow::Error);

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let message = self.0.to_string();
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            [(header::CONTENT_TYPE, "application/json; charset=utf-8")],
            json!({ "ok": false, "error": message }).to_string(),
        )
            .into_response()
    }
}

impl<E> From<E> for AppError
where
    E: Into<anyhow::Error>,
{
    fn from(err: E) -> Self {
        Self(err.into())
    }
}
