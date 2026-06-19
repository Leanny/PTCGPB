use anyhow::{Context, Result};
use axum::{
    body::Body,
    extract::{Query, Request, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{any, get, post},
    Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
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

#[derive(Clone)]
pub struct ServeState {
    root: PathBuf,
    legacy_port: u16,
    client: reqwest::Client,
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
        db_progress,
        db_ensure_mutex: Arc::new(AsyncMutex::new(())),
        sync_mutex: Arc::new(AsyncMutex::new(())),
        active_row_streams: Arc::new(AtomicUsize::new(0)),
    };

    let static_files = ServeDir::new(state.root.clone());

    let dashboard_routes = Router::new()
        .route("/ping", get(ping))
        .route("/shutdown", post(proxy_legacy))
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

    let app = Router::new()
        .nest("/__dashboard", dashboard_routes)
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

fn spawn_background_sync(state: ServeState, interval_secs: u64) {
    tokio::spawn(async move {
        let every = Duration::from_secs(interval_secs.max(5));
        let mut interval = tokio::time::interval(every);
        interval.tick().await;
        loop {
            interval.tick().await;
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

fn with_conn<T>(root: &Path, f: impl FnOnce(&rusqlite::Connection) -> Result<T>) -> Result<T> {
    let conn = crate::dashboard_db::open_connection_public(root)?;
    crate::dashboard_db::init_schema_public(&conn)?;
    f(&conn)
}

async fn ping() -> StatusCode {
    StatusCode::NO_CONTENT
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
