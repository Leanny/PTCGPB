use anyhow::{Context, Result};
use chrono::{NaiveDateTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::dashboard_index::{
    build_account_summary, compact_rows_from_doc, dashboard_cache_dir, scan_compact_pulls,
    AccountSummaryRecord, CompactRow,
};

const SCHEMA_VERSION: &str = "3";

pub fn dashboard_db_path(root: &Path) -> PathBuf {
    dashboard_cache_dir(root).join("dashboard.db")
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct DashboardDbStats {
    pub account_count: usize,
    pub trade_account_count: usize,
    pub collection_count: usize,
    pub row_count: usize,
    pub total_cards: usize,
    pub unique_card_count: usize,
    pub skipped_count: usize,
    pub db_bytes: u64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SyncResult {
    pub scanned_files: usize,
    pub dirty_accounts: usize,
    pub reindexed_accounts: usize,
    pub removed_accounts: usize,
    pub skipped_files: usize,
    pub elapsed_ms: u128,
}

#[derive(Debug, Clone, serde::Serialize, Default)]
pub struct DashboardDbBuildProgress {
    pub phase: String,
    pub mode: String,
    pub current: usize,
    pub total: usize,
    pub message: String,
    pub account_count: usize,
    pub row_count: usize,
    pub elapsed_ms: u128,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct EnsureDbResult {
    pub ok: bool,
    pub mode: String,
    pub account_count: usize,
    pub row_count: usize,
    pub reindexed_accounts: usize,
    pub skipped_files: usize,
    pub elapsed_ms: u128,
    pub db_bytes: u64,
}

pub type ProgressHandle = Arc<Mutex<DashboardDbBuildProgress>>;

fn touch_progress(progress: &Option<ProgressHandle>, update: impl FnOnce(&mut DashboardDbBuildProgress)) {
    if let Some(handle) = progress {
        if let Ok(mut guard) = handle.lock() {
            update(&mut guard);
        }
    }
}

pub fn rebuild_dashboard_db(root: &Path) -> Result<DashboardDbStats> {
    rebuild_dashboard_db_with_progress(root, None)
}

pub fn rebuild_dashboard_db_with_progress(
    root: &Path,
    progress: Option<ProgressHandle>,
) -> Result<DashboardDbStats> {
    let started = Instant::now();
    touch_progress(&progress, |p| {
        p.phase = "indexing".into();
        p.mode = "full_rebuild".into();
        p.message = "Preparing SQLite index…".into();
        p.current = 0;
        p.total = 0;
        p.error = None;
    });
    remove_database_files(root)?;
    fs::create_dir_all(dashboard_cache_dir(root))?;
    let conn = open_connection(root)?;
    init_schema(&conn)?;
    let stats = index_all_sources(root, &conn, progress.as_ref(), started)?;
    checkpoint_database(&conn)?;
    touch_progress(&progress, |p| {
        p.phase = "checkpoint".into();
        p.message = "Finalizing SQLite index…".into();
        p.account_count = stats.account_count;
        p.row_count = stats.row_count;
        p.elapsed_ms = started.elapsed().as_millis();
    });
    Ok(stats)
}

pub fn sync_dashboard_db(root: &Path, max_accounts: Option<usize>) -> Result<SyncResult> {
    sync_dashboard_db_with_progress(root, max_accounts, None)
}

/// Sync only when account JSON files are dirty. Returns true when a sync ran.
pub fn sync_dashboard_db_if_dirty(root: &Path) -> Result<bool> {
    let conn = open_connection(root)?;
    init_schema(&conn)?;
    let paths = crate::gather_dashboard_paths(root)?;
    let dirty = find_dirty_sources(&conn, &paths)?;
    if dirty.is_empty() {
        return Ok(false);
    }
    sync_dashboard_db(root, None)?;
    Ok(true)
}

pub fn sync_dashboard_db_with_progress(
    root: &Path,
    max_accounts: Option<usize>,
    progress: Option<ProgressHandle>,
) -> Result<SyncResult> {
    let started = Instant::now();
    touch_progress(&progress, |p| {
        p.phase = "syncing".into();
        p.mode = "incremental_sync".into();
        p.message = "Scanning account JSON files…".into();
        p.current = 0;
        p.total = 0;
        p.error = None;
    });
    fs::create_dir_all(dashboard_cache_dir(root))?;
    let conn = open_connection(root)?;
    init_schema(&conn)?;

    let paths = crate::gather_dashboard_paths(root)?;
    let mut dirty = find_dirty_sources(&conn, &paths)?;
    let removed_sources = remove_orphan_sources(root, &conn, &paths)?;
    let removed_accounts = remove_orphan_accounts(&conn)?;
    let removed = removed_sources + removed_accounts;

    if let Some(limit) = max_accounts {
        dirty.truncate(limit);
    }

    touch_progress(&progress, |p| {
        p.total = dirty.len();
        p.message = if dirty.is_empty() {
            "SQLite index is up to date.".into()
        } else {
            format!("Updating {} changed account file(s)…", dirty.len())
        };
    });

    let mut skipped_files = 0usize;
    let tx = conn.unchecked_transaction()?;
    {
        let mut inserter = AccountInserter::new(&tx)?;
        for (idx, (source_key, path)) in dirty.iter().enumerate() {
            touch_progress(&progress, |p| {
                p.current = idx + 1;
                p.total = dirty.len();
                p.elapsed_ms = started.elapsed().as_millis();
                p.message = format!(
                    "Syncing account files ({}/{})…",
                    idx + 1,
                    dirty.len()
                );
            });
            if let Err(err) =
                reindex_source_in_tx(root, &tx, &mut inserter, source_key, path)
            {
                skipped_files += 1;
                eprintln!("dashboard_db: skipped {source_key}: {err:#}");
            }
        }
    }
    tx.commit()?;

    set_meta(&conn, "last_sync_at", &Utc::now().to_rfc3339())?;
    touch_progress(&progress, |p| {
        p.phase = "checkpoint".into();
        p.message = "Finalizing SQLite updates…".into();
        p.elapsed_ms = started.elapsed().as_millis();
    });
    checkpoint_database(&conn)?;

    if let Ok(stats) = read_db_stats(&conn, root) {
        touch_progress(&progress, |p| {
            p.account_count = stats.account_count;
            p.row_count = stats.row_count;
        });
    }

    Ok(SyncResult {
        scanned_files: paths.len(),
        dirty_accounts: dirty.len(),
        reindexed_accounts: dirty.len().saturating_sub(skipped_files),
        removed_accounts: removed,
        skipped_files,
        elapsed_ms: started.elapsed().as_millis(),
    })
}

pub fn read_dashboard_db_build_progress(root: &Path) -> DashboardDbBuildProgress {
    if !dashboard_db_path(root).exists() {
        return DashboardDbBuildProgress {
            phase: "missing".into(),
            message: "SQLite index not built yet.".into(),
            ..DashboardDbBuildProgress::default()
        };
    }

    match open_connection(root).and_then(|conn| {
        init_schema(&conn)?;
        read_db_stats(&conn, root)
    }) {
        Ok(stats) if stats.account_count > 0 => DashboardDbBuildProgress {
            phase: "ready".into(),
            mode: "ready".into(),
            account_count: stats.account_count,
            row_count: stats.row_count,
            message: "SQLite index ready.".into(),
            ..DashboardDbBuildProgress::default()
        },
        _ => DashboardDbBuildProgress {
            phase: "missing".into(),
            message: "SQLite index is empty.".into(),
            ..DashboardDbBuildProgress::default()
        },
    }
}

pub fn ensure_dashboard_db(
    root: &Path,
    progress: Option<ProgressHandle>,
) -> Result<EnsureDbResult> {
    let started = Instant::now();
    let needs_full = !dashboard_db_path(root).exists()
        || open_connection(root)
            .ok()
            .and_then(|conn| init_schema(&conn).ok().map(|_| conn))
            .and_then(|conn| {
                conn.query_row("SELECT COUNT(*) FROM accounts", [], |row| row.get(0))
                    .ok()
            })
            .unwrap_or(0) == 0;

    if needs_full {
        let stats = rebuild_dashboard_db_with_progress(root, progress.clone())?;
        touch_progress(&progress, |p| {
            p.phase = "ready".into();
            p.mode = "full_rebuild".into();
            p.account_count = stats.account_count;
            p.row_count = stats.row_count;
            p.elapsed_ms = started.elapsed().as_millis();
            p.message = "SQLite index ready.".into();
        });
        return Ok(EnsureDbResult {
            ok: true,
            mode: "full_rebuild".into(),
            account_count: stats.account_count,
            row_count: stats.row_count,
            reindexed_accounts: stats.account_count,
            skipped_files: stats.skipped_count,
            elapsed_ms: started.elapsed().as_millis(),
            db_bytes: stats.db_bytes,
        });
    }

    // Block boot until dirty account JSON is synced into SQLite so row streams
    // are complete when the dashboard loader finishes.
    let sync = sync_dashboard_db_with_progress(root, None, progress.clone())?;
    let stats = open_connection(root)
        .and_then(|conn| read_db_stats(&conn, root))
        .unwrap_or(DashboardDbStats {
            account_count: 0,
            trade_account_count: 0,
            collection_count: 0,
            row_count: 0,
            total_cards: 0,
            unique_card_count: 0,
            skipped_count: 0,
            db_bytes: dashboard_db_path(root)
                .metadata()
                .map(|meta| meta.len())
                .unwrap_or(0),
        });
    let mode = if sync.dirty_accounts > 0 {
        "incremental_sync"
    } else {
        "ready"
    };
    touch_progress(&progress, |p| {
        p.phase = "ready".into();
        p.mode = mode.into();
        p.account_count = stats.account_count;
        p.row_count = stats.row_count;
        p.elapsed_ms = started.elapsed().as_millis();
        p.message = if sync.dirty_accounts > 0 {
            format!(
                "Synced {} account file(s) into SQLite.",
                sync.reindexed_accounts
            )
        } else {
            "SQLite index ready.".into()
        };
    });
    Ok(EnsureDbResult {
        ok: true,
        mode: mode.into(),
        account_count: stats.account_count,
        row_count: stats.row_count,
        reindexed_accounts: sync.reindexed_accounts,
        skipped_files: sync.skipped_files,
        elapsed_ms: started.elapsed().as_millis(),
        db_bytes: stats.db_bytes,
    })
}

pub fn query_accounts(conn: &Connection, offset: usize, limit: usize) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare(
        "SELECT account_key, source_type, source_file_name, file_label, display_name,
                account_name, friend_code, instance, device_account, collection_id,
                created_at, last_logged_in, last_pack_pulled, last_modified, pack_count,
                shinedust, shinedust_updated_at, pull_count, card_count, unique_card_count,
                registry_card_count, registered_cards_json, registry_imported_at
         FROM accounts
         ORDER BY account_key
         LIMIT ?1 OFFSET ?2",
    )?;
    let rows = stmt.query_map(params![limit as i64, offset as i64], |row| {
        Ok(json!({
            "account": row.get::<_, String>(0)?,
            "sourceType": row.get::<_, String>(1)?,
            "sourceFileName": row.get::<_, String>(2)?,
            "fileLabel": row.get::<_, String>(3)?,
            "displayName": row.get::<_, String>(4)?,
            "accountName": row.get::<_, String>(5)?,
            "friendCode": row.get::<_, String>(6)?,
            "instance": row.get::<_, String>(7)?,
            "deviceAccount": row.get::<_, String>(8)?,
            "collectionId": row.get::<_, String>(9)?,
            "metadata": {
                "createdAt": row.get::<_, String>(10)?,
                "lastLoggedIn": row.get::<_, String>(11)?,
                "lastPackPulled": row.get::<_, String>(12)?,
                "lastModified": row.get::<_, String>(13)?,
                "packCount": row.get::<_, i64>(14)?,
                "accountName": row.get::<_, String>(5)?,
                "friendCode": row.get::<_, String>(6)?,
                "instance": row.get::<_, String>(7)?,
                "registryImportedAt": row.get::<_, String>(22)?,
            },
            "shinedust": row.get::<_, i64>(15)?,
            "pullCount": row.get::<_, i64>(17)?,
            "cardCount": row.get::<_, i64>(18)?,
            "uniqueCardCount": row.get::<_, i64>(19)?,
            "registryCardCount": row.get::<_, i64>(20)?,
            "registeredCards": serde_json::from_str::<Value>(&row.get::<_, String>(21)?).unwrap_or(json!([])),
        }))
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub fn query_rows(
    conn: &Connection,
    offset: usize,
    limit: usize,
    account: Option<&str>,
    pack: Option<&str>,
) -> Result<Vec<Value>> {
    let sql = match (account, pack) {
        (Some(_), Some(_)) => {
            "SELECT account_key, pack, source_pack, timestamp, card_ids_json
             FROM rows WHERE account_key = ?3 AND pack = ?4
             ORDER BY id LIMIT ?1 OFFSET ?2"
        }
        (Some(_), None) => {
            "SELECT account_key, pack, source_pack, timestamp, card_ids_json
             FROM rows WHERE account_key = ?3
             ORDER BY id LIMIT ?1 OFFSET ?2"
        }
        (None, Some(_)) => {
            "SELECT account_key, pack, source_pack, timestamp, card_ids_json
             FROM rows WHERE pack = ?3
             ORDER BY id LIMIT ?1 OFFSET ?2"
        }
        (None, None) => {
            "SELECT account_key, pack, source_pack, timestamp, card_ids_json
             FROM rows ORDER BY id LIMIT ?1 OFFSET ?2"
        }
    };

    let mut stmt = conn.prepare(sql)?;
    let map_row = |row: &rusqlite::Row<'_>| {
        let card_ids: Value =
            serde_json::from_str(&row.get::<_, String>(4)?).unwrap_or(json!([]));
        Ok(json!({
            "account": row.get::<_, String>(0)?,
            "pack": row.get::<_, String>(1)?,
            "sourcePack": row.get::<_, String>(2)?,
            "timestamp": row.get::<_, String>(3)?,
            "cardIds": card_ids,
        }))
    };

    let rows = match (account, pack) {
        (Some(acct), Some(p)) => stmt.query_map(params![limit as i64, offset as i64, acct, p], map_row)?,
        (Some(acct), None) => stmt.query_map(params![limit as i64, offset as i64, acct], map_row)?,
        (None, Some(p)) => stmt.query_map(params![limit as i64, offset as i64, p], map_row)?,
        (None, None) => stmt.query_map(params![limit as i64, offset as i64], map_row)?,
    };

    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub fn query_row_total(conn: &Connection) -> Result<usize> {
    let total: usize = conn.query_row("SELECT COUNT(*) FROM rows", [], |row| row.get(0))?;
    Ok(total)
}

pub fn export_dashboard_rows_page(
    conn: &Connection,
    offset: usize,
    limit: usize,
) -> Result<Value> {
    let total = query_row_total(conn)?;
    let rows = query_rows(conn, offset, limit, None, None)?;
    let next_offset = offset.saturating_add(rows.len());
    Ok(json!({
        "ok": true,
        "source": "dashboard.db",
        "offset": offset,
        "limit": limit,
        "total": total,
        "count": rows.len(),
        "hasMore": next_offset < total,
        "nextOffset": if next_offset < total {
            json!(next_offset)
        } else {
            Value::Null
        },
        "rows": rows,
    }))
}

pub fn export_accounts_summary_payload(root: &Path) -> Result<Value> {
    let conn = open_connection(root)?;
    init_schema(&conn)?;
    let stats = read_db_stats(&conn, root)?;
    let accounts = query_accounts(&conn, 0, stats.account_count.max(1))?;
    Ok(json!({
        "ok": true,
        "source": "dashboard.db",
        "accountCount": stats.account_count,
        "tradeAccountCount": stats.trade_account_count,
        "collectionRegistryCount": stats.collection_count,
        "rowCount": stats.row_count,
        "totalCards": stats.total_cards,
        "uniqueCardCount": stats.unique_card_count,
        "skippedCount": stats.skipped_count,
        "skipped": [],
        "accounts": accounts,
    }))
}

pub fn stream_dashboard_rows_ndjson(
    root: PathBuf,
    tx: tokio::sync::mpsc::Sender<Result<bytes::Bytes, std::convert::Infallible>>,
) -> Result<()> {
    let conn = open_connection(&root)?;
    init_schema(&conn)?;
    let mut stmt = conn.prepare(
        "SELECT account_key, pack, source_pack, timestamp, card_ids_json
         FROM rows ORDER BY id",
    )?;
    let mut rows = stmt.query([])?;
    let mut batch = Vec::with_capacity(256 * 1024);

    while let Some(row) = rows.next()? {
        let account: String = row.get(0)?;
        let pack: String = row.get(1)?;
        let source_pack: String = row.get(2)?;
        let timestamp: String = row.get(3)?;
        let card_ids: Value =
            serde_json::from_str(&row.get::<_, String>(4)?).unwrap_or(json!([]));
        let line = json!({
            "account": account,
            "pack": pack,
            "sourcePack": source_pack,
            "timestamp": timestamp,
            "cardIds": card_ids,
        });
        serde_json::to_writer(&mut batch, &line)?;
        batch.write_all(b"\n")?;
        if batch.len() >= 256 * 1024 {
            if tx
                .blocking_send(Ok(bytes::Bytes::from(std::mem::take(&mut batch))))
                .is_err()
            {
                return Ok(());
            }
        }
    }
    if !batch.is_empty() {
        let _ = tx.blocking_send(Ok(bytes::Bytes::from(batch)));
    }
    Ok(())
}

pub fn export_account_card_marks_payload(root: &Path) -> Result<Value> {
    let started = Instant::now();
    let conn = open_connection(root)?;
    init_schema(&conn)?;
    let mut stmt = conn.prepare(
        "SELECT account_key, card_id, mark_type, count, mark_value_json
         FROM card_marks
         ORDER BY account_key, mark_type, card_id",
    )?;
    let mut rows = stmt.query([])?;

    let mut accounts: HashMap<String, (Map<String, Value>, Map<String, Value>)> = HashMap::new();
    while let Some(row) = rows.next()? {
        let account_key: String = row.get(0)?;
        let card_id: String = row.get(1)?;
        let mark_type: String = row.get(2)?;
        let count: i64 = row.get(3)?;
        let mark_value_json: Option<String> = row.get(4)?;
        let mark_value = mark_value_json
            .as_deref()
            .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
            .unwrap_or_else(|| json!(count.max(1)));

        let entry = accounts
            .entry(account_key)
            .or_insert_with(|| (Map::new(), Map::new()));
        match mark_type.as_str() {
            "traded" => {
                entry.0.insert(card_id, mark_value);
            }
            "shared" => {
                entry.1.insert(card_id, mark_value);
            }
            _ => {}
        }
    }

    let mut account_keys: Vec<String> = accounts.keys().cloned().collect();
    account_keys.sort();
    let mut account_entries = Vec::with_capacity(account_keys.len());
    for device_account in account_keys {
        let (traded_cards, shared_cards) = accounts.remove(&device_account).unwrap_or_default();
        let mut entry = Map::new();
        entry.insert("deviceAccount".into(), json!(device_account));
        if !traded_cards.is_empty() {
            entry.insert("tradedCards".into(), Value::Object(traded_cards));
        }
        if !shared_cards.is_empty() {
            entry.insert("sharedCards".into(), Value::Object(shared_cards));
        }
        account_entries.push(Value::Object(entry));
    }

    let marks_found = account_entries.len();
    Ok(json!({
        "ok": true,
        "accountCount": marks_found,
        "accounts": account_entries,
        "build": {
            "cacheHit": false,
            "source": "dashboard.db",
            "sourceFilesScanned": 0,
            "marksFound": marks_found,
            "rebuildMs": started.elapsed().as_millis(),
        }
    }))
}

pub fn open_connection_public(root: &Path) -> Result<Connection> {
    open_connection(root)
}

pub fn init_schema_public(conn: &Connection) -> Result<()> {
    init_schema(conn)
}

fn open_connection(root: &Path) -> Result<Connection> {
    let db_path = dashboard_db_path(root);
    let conn = Connection::open(&db_path).with_context(|| format!("Could not open {:?}", db_path))?;
    conn.busy_timeout(Duration::from_secs(10))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "temp_store", "MEMORY")?;
    // Merge WAL back into the main DB periodically (pages, not bytes).
    conn.pragma_update(None, "wal_autocheckpoint", 1000)?;
    Ok(conn)
}

fn checkpoint_database(conn: &Connection) -> Result<()> {
    let busy: i32 = conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
        Ok(row.get::<_, i32>(0)?)
    })?;
    if busy != 0 {
        // Active readers (e.g. a long dashboard-rows stream) block TRUNCATE.
        let _ = conn.query_row("PRAGMA wal_checkpoint(RESTART)", [], |row| {
            Ok(row.get::<_, i32>(0)?)
        });
    }
    Ok(())
}

pub fn checkpoint_dashboard_db(root: &Path) -> Result<()> {
    let conn = open_connection(root)?;
    init_schema(&conn)?;
    checkpoint_database(&conn)
}

fn remove_database_files(root: &Path) -> Result<()> {
    let db_path = dashboard_db_path(root);
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("dashboard.db");
    let parent = db_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| dashboard_cache_dir(root));
    for suffix in ["", "-wal", "-shm"] {
        let path = parent.join(format!("{file_name}{suffix}"));
        if path.exists() {
            fs::remove_file(&path).with_context(|| format!("Could not remove {:?}", path))?;
        }
    }
    Ok(())
}

fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS db_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS source_files (
            source_key TEXT PRIMARY KEY,
            account_key TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            modified_ns INTEGER NOT NULL,
            indexed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_source_files_account ON source_files(account_key);

        CREATE TABLE IF NOT EXISTS accounts (
            account_key TEXT PRIMARY KEY,
            source_type TEXT NOT NULL,
            source_file_name TEXT NOT NULL,
            file_label TEXT NOT NULL DEFAULT '',
            display_name TEXT NOT NULL DEFAULT '',
            account_name TEXT NOT NULL DEFAULT '',
            friend_code TEXT NOT NULL DEFAULT '',
            instance TEXT NOT NULL DEFAULT '',
            device_account TEXT NOT NULL DEFAULT '',
            collection_id TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT '',
            last_logged_in TEXT NOT NULL DEFAULT '',
            last_pack_pulled TEXT NOT NULL DEFAULT '',
            last_modified TEXT NOT NULL DEFAULT '',
            pack_count INTEGER NOT NULL DEFAULT 0,
            shinedust INTEGER NOT NULL DEFAULT 0,
            shinedust_updated_at TEXT NOT NULL DEFAULT '',
            pull_count INTEGER NOT NULL DEFAULT 0,
            card_count INTEGER NOT NULL DEFAULT 0,
            unique_card_count INTEGER NOT NULL DEFAULT 0,
            registry_card_count INTEGER NOT NULL DEFAULT 0,
            registered_cards_json TEXT NOT NULL DEFAULT '[]',
            registry_imported_at TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_accounts_source_type ON accounts(source_type);

        CREATE TABLE IF NOT EXISTS rows (
            id INTEGER PRIMARY KEY,
            account_key TEXT NOT NULL REFERENCES accounts(account_key) ON DELETE CASCADE,
            pack TEXT NOT NULL,
            source_pack TEXT NOT NULL,
            timestamp TEXT NOT NULL DEFAULT '',
            timestamp_ms INTEGER,
            card_count INTEGER NOT NULL,
            card_ids_json TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX IF NOT EXISTS idx_rows_account ON rows(account_key);
        CREATE INDEX IF NOT EXISTS idx_rows_pack ON rows(pack);
        CREATE INDEX IF NOT EXISTS idx_rows_timestamp_ms ON rows(timestamp_ms);

        CREATE TABLE IF NOT EXISTS account_card_counts (
            account_key TEXT NOT NULL,
            card_id TEXT NOT NULL,
            count INTEGER NOT NULL,
            PRIMARY KEY (account_key, card_id)
        );
        CREATE INDEX IF NOT EXISTS idx_account_card_counts_card ON account_card_counts(card_id);

        CREATE TABLE IF NOT EXISTS card_marks (
            account_key TEXT NOT NULL,
            card_id TEXT NOT NULL,
            mark_type TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 1,
            mark_value_json TEXT,
            PRIMARY KEY (account_key, card_id, mark_type)
        );
        CREATE INDEX IF NOT EXISTS idx_card_marks_card ON card_marks(card_id);
        ",
    )?;
    ensure_card_marks_value_column(conn)?;
    set_meta(conn, "schema_version", SCHEMA_VERSION)?;
    Ok(())
}

fn ensure_card_marks_value_column(conn: &Connection) -> Result<()> {
    let mut stmt = conn.prepare("PRAGMA table_info(card_marks)")?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if !columns.iter().any(|name| name == "mark_value_json") {
        conn.execute("ALTER TABLE card_marks ADD COLUMN mark_value_json TEXT", [])?;
    }
    Ok(())
}

fn set_meta(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO db_meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

fn configure_bulk_import(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "
        PRAGMA synchronous = OFF;
        PRAGMA temp_store = MEMORY;
        PRAGMA cache_size = -128000;
        ",
    )?;
    Ok(())
}

fn restore_bulk_import(conn: &Connection) -> Result<()> {
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    Ok(())
}

struct AccountInserter<'conn> {
    insert_account: rusqlite::Statement<'conn>,
    insert_row: rusqlite::Statement<'conn>,
    insert_card_count: rusqlite::Statement<'conn>,
    insert_card_mark: rusqlite::Statement<'conn>,
    upsert_source_file: rusqlite::Statement<'conn>,
}

impl<'conn> AccountInserter<'conn> {
    fn new(conn: &'conn Connection) -> Result<Self> {
        Ok(Self {
            insert_account: conn.prepare(
                "INSERT INTO accounts (
                    account_key, source_type, source_file_name, file_label, display_name, account_name,
                    friend_code, instance, device_account, collection_id, created_at, last_logged_in,
                    last_pack_pulled, last_modified, pack_count, shinedust, shinedust_updated_at,
                    pull_count, card_count, unique_card_count, registry_card_count,
                    registered_cards_json, registry_imported_at
                ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23)",
            )?,
            insert_row: conn.prepare(
                "INSERT INTO rows(account_key, pack, source_pack, timestamp, timestamp_ms, card_count, card_ids_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            )?,
            insert_card_count: conn.prepare(
                "INSERT INTO account_card_counts(account_key, card_id, count) VALUES (?1, ?2, ?3)",
            )?,
            insert_card_mark: conn.prepare(
                "INSERT INTO card_marks(account_key, card_id, mark_type, count, mark_value_json)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )?,
            upsert_source_file: conn.prepare(
                "INSERT INTO source_files(source_key, account_key, file_size, modified_ns, indexed_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(source_key) DO UPDATE SET
                    account_key = excluded.account_key,
                    file_size = excluded.file_size,
                    modified_ns = excluded.modified_ns,
                    indexed_at = excluded.indexed_at",
            )?,
        })
    }

    fn index_document(
        &mut self,
        conn: &Connection,
        source_key: &str,
        path: &Path,
        doc: &Value,
        replace_existing: bool,
    ) -> Result<()> {
        let summary = build_account_summary(doc)
            .with_context(|| format!("Could not build summary for {source_key}"))?;
        let (size, modified_ns) = file_fingerprint(path)?;

        if let Ok(old_key) = conn.query_row(
            "SELECT account_key FROM source_files WHERE source_key = ?1",
            params![source_key],
            |row| row.get::<_, String>(0),
        ) {
            if old_key != summary.account {
                delete_account(conn, &old_key)?;
            }
        }

        if replace_existing {
            delete_account(conn, &summary.account)?;
        }

        self.insert_account.execute(params![
            summary.account,
            summary.source_type,
            summary.source_file_name,
            summary.file_label,
            summary.display_name,
            summary.account_name,
            summary.friend_code,
            summary.instance,
            summary.device_account,
            summary.collection_id,
            summary.created_at,
            summary.last_logged_in,
            summary.last_pack_pulled,
            summary.last_modified,
            summary.pack_count,
            summary.shinedust,
            summary.shinedust_updated_at,
            summary.pull_count,
            summary.card_count,
            summary.unique_card_count,
            summary.registry_card_count,
            serde_json::to_string(&summary.registered_cards)?,
            summary.registry_imported_at,
        ])?;

        insert_rows_and_cards_prepared(self, &summary, doc)?;
        insert_card_marks_prepared(self, &summary.account, doc)?;

        self.upsert_source_file.execute(params![
            source_key,
            summary.account,
            size as i64,
            modified_ns_to_i64(modified_ns),
            Utc::now().to_rfc3339(),
        ])?;
        Ok(())
    }
}

fn index_all_sources(
    root: &Path,
    conn: &Connection,
    progress: Option<&ProgressHandle>,
    started: Instant,
) -> Result<DashboardDbStats> {
    configure_bulk_import(conn)?;
    let paths = crate::gather_dashboard_paths(root)?;
    touch_progress(&progress.cloned(), |p| {
        p.phase = "indexing".into();
        p.mode = "full_rebuild".into();
        p.total = paths.len();
        p.current = 0;
        p.message = format!("Indexing {} account JSON file(s)…", paths.len());
    });
    let tx = conn.unchecked_transaction()?;
    tx.execute("DELETE FROM card_marks", [])?;
    tx.execute("DELETE FROM account_card_counts", [])?;
    tx.execute("DELETE FROM rows", [])?;
    tx.execute("DELETE FROM accounts", [])?;
    tx.execute("DELETE FROM source_files", [])?;

    let mut skipped = 0usize;
    {
        let mut inserter = AccountInserter::new(&tx)?;
        for (idx, (source_key, path)) in paths.iter().enumerate() {
            touch_progress(&progress.cloned(), |p| {
                p.current = idx + 1;
                p.total = paths.len();
                p.elapsed_ms = started.elapsed().as_millis();
                p.message = format!(
                    "Indexing account files ({}/{})…",
                    idx + 1,
                    paths.len()
                );
            });
            let doc = match crate::load_dashboard_account_document(path, source_key) {
                Ok(doc) => doc,
                Err(_) => {
                    skipped += 1;
                    continue;
                }
            };
            if inserter
                .index_document(&tx, source_key, path, &doc, false)
                .is_err()
            {
                skipped += 1;
            }
        }
    }
    tx.commit()?;
    restore_bulk_import(conn)?;
    set_meta(conn, "last_full_rebuild_at", &Utc::now().to_rfc3339())?;
    checkpoint_database(conn)?;
    read_db_stats(conn, root).map(|mut stats| {
        stats.skipped_count = skipped;
        stats
    })
}

fn find_dirty_sources(
    conn: &Connection,
    paths: &[(String, PathBuf)],
) -> Result<Vec<(String, PathBuf)>> {
    let mut dirty = Vec::new();
    for (source_key, path) in paths {
        let (size, modified_ns) = file_fingerprint(path)?;
        let stored: Option<(i64, i64)> = conn
            .query_row(
                "SELECT file_size, modified_ns FROM source_files WHERE source_key = ?1",
                params![source_key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .ok();

        let linked_account_key: Option<String> = conn
            .query_row(
                "SELECT account_key FROM source_files WHERE source_key = ?1",
                params![source_key],
                |row| row.get(0),
            )
            .optional()?;
        let account_exists = linked_account_key
            .as_deref()
            .map(|key| account_exists(conn, key))
            .transpose()?
            .unwrap_or(false);

        let needs_reindex = match stored {
            None => true,
            Some((stored_size, stored_modified)) => {
                stored_size as u64 != size || stored_modified != modified_ns_to_i64(modified_ns)
            }
        };

        if needs_reindex || !account_exists {
            dirty.push((source_key.clone(), path.clone()));
        }
    }
    Ok(dirty)
}

fn remove_orphan_sources(
    root: &Path,
    conn: &Connection,
    paths: &[(String, PathBuf)],
) -> Result<usize> {
    let live: HashSet<String> = paths.iter().map(|(key, _)| key.clone()).collect();
    let mut orphans = Vec::new();
    let mut stmt = conn.prepare("SELECT source_key, account_key FROM source_files")?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (source_key, account_key) = row?;
        if !live.contains(&source_key) {
            orphans.push((source_key, account_key));
        }
    }

    for (_source_key, account_key) in &orphans {
        delete_account(conn, account_key)?;
    }
    let _ = root;
    Ok(orphans.len())
}

fn remove_orphan_accounts(conn: &Connection) -> Result<usize> {
    let mut orphans = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT account_key FROM accounts
         WHERE account_key NOT IN (SELECT account_key FROM source_files)",
    )?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
    for row in rows {
        orphans.push(row?);
    }
    for account_key in &orphans {
        delete_account(conn, account_key)?;
    }
    Ok(orphans.len())
}

pub fn reindex_account_source_file(root: &Path, device_account: &str) -> Result<()> {
    let path = crate::account_file_path(root, device_account);
    if !path.exists() {
        anyhow::bail!("Account file not found for {device_account}");
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let source_key = format!("accounts/{file_name}");
    let conn = open_connection(root)?;
    init_schema(&conn)?;
    reindex_source_file(root, &conn, &source_key, &path)?;
    checkpoint_database(&conn)?;
    Ok(())
}

fn reindex_source_file(root: &Path, conn: &Connection, source_key: &str, path: &Path) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    {
        let mut inserter = AccountInserter::new(&tx)?;
        reindex_source_in_tx(root, &tx, &mut inserter, source_key, path)?;
    }
    tx.commit()?;
    Ok(())
}

enum AppendPlan {
    FullReindex,
    AppendNewRows(Vec<CompactRow>),
    MetadataOnly,
}

fn plan_append(
    conn: &Connection,
    source_key: &str,
    path: &Path,
    summary: &AccountSummaryRecord,
    doc: &Value,
) -> Result<AppendPlan> {
    if summary.source_type == "collection" {
        return Ok(AppendPlan::FullReindex);
    }

    let stored_file: Option<(i64, i64)> = conn
        .query_row(
            "SELECT file_size, modified_ns FROM source_files WHERE source_key = ?1",
            params![source_key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((stored_size, _)) = stored_file else {
        return Ok(AppendPlan::FullReindex);
    };

    let (new_size, _) = file_fingerprint(path)?;
    if new_size < stored_size as u64 {
        return Ok(AppendPlan::FullReindex);
    }

    let stored_rows: i64 = conn.query_row(
        "SELECT COUNT(*) FROM rows WHERE account_key = ?1",
        params![summary.account],
        |row| row.get(0),
    )?;
    let stored_rows = stored_rows as usize;
    let (new_count, boundary_row, new_rows) =
        scan_compact_pulls(doc, &summary.account, stored_rows);

    if new_count < stored_rows {
        return Ok(AppendPlan::FullReindex);
    }
    if new_count == stored_rows {
        return Ok(AppendPlan::MetadataOnly);
    }
    if stored_rows > 0 {
        let Some(expected) = boundary_row.as_ref() else {
            return Ok(AppendPlan::FullReindex);
        };
        if !last_row_matches(conn, &summary.account, expected)? {
            return Ok(AppendPlan::FullReindex);
        }
    }

    Ok(AppendPlan::AppendNewRows(new_rows))
}

fn reindex_source_in_tx(
    root: &Path,
    conn: &Connection,
    inserter: &mut AccountInserter<'_>,
    source_key: &str,
    path: &Path,
) -> Result<()> {
    let doc = crate::load_dashboard_account_document(path, source_key)?;
    let summary = build_account_summary(&doc)
        .with_context(|| format!("Could not build summary for {source_key}"))?;

    match plan_append(conn, source_key, path, &summary, &doc)? {
        AppendPlan::FullReindex => {
            let replace = account_exists(conn, &summary.account)?;
            inserter.index_document(conn, source_key, path, &doc, replace)?;
        }
        AppendPlan::AppendNewRows(new_rows) => {
            sync_append_or_metadata(
                inserter,
                conn,
                source_key,
                path,
                &doc,
                &summary,
                &new_rows,
                true,
            )?;
        }
        AppendPlan::MetadataOnly => {
            sync_append_or_metadata(
                inserter,
                conn,
                source_key,
                path,
                &doc,
                &summary,
                &[],
                false,
            )?;
        }
    }
    let _ = root;
    Ok(())
}

fn account_exists(conn: &Connection, account_key: &str) -> Result<bool> {
    conn.query_row(
        "SELECT 1 FROM accounts WHERE account_key = ?1",
        params![account_key],
        |_| Ok(true),
    )
    .optional()
    .map(|value| value.is_some())
    .with_context(|| format!("Could not check account existence for {account_key}"))
}

fn sync_append_or_metadata(
    inserter: &mut AccountInserter<'_>,
    conn: &Connection,
    source_key: &str,
    path: &Path,
    doc: &Value,
    summary: &AccountSummaryRecord,
    new_rows: &[CompactRow],
    appended_new_rows: bool,
) -> Result<()> {
    if appended_new_rows && !new_rows.is_empty() {
        let mut card_deltas: HashMap<String, i64> = HashMap::new();
        for row in new_rows {
            let timestamp_ms = parse_timestamp_ms(&row.timestamp);
            let card_ids_json = serde_json::to_string(&row.card_ids)?;
            inserter.insert_row.execute(params![
                row.account,
                row.pack,
                row.source_pack,
                row.timestamp,
                timestamp_ms,
                row.card_ids.len() as i64,
                card_ids_json,
            ])?;
            for card_id in &row.card_ids {
                *card_deltas.entry(card_id.clone()).or_insert(0) += 1;
            }
        }
        for (card_id, count) in card_deltas {
            conn.execute(
                "INSERT INTO account_card_counts(account_key, card_id, count) VALUES (?1, ?2, ?3)
                 ON CONFLICT(account_key, card_id) DO UPDATE SET
                    count = account_card_counts.count + excluded.count",
                params![summary.account, card_id, count],
            )?;
        }
    }

    update_account_record(conn, summary)?;
    if !appended_new_rows {
        refresh_card_marks(conn, inserter, &summary.account, doc)?;
    }

    let (size, modified_ns) = file_fingerprint(path)?;
    inserter.upsert_source_file.execute(params![
        source_key,
        summary.account,
        size as i64,
        modified_ns_to_i64(modified_ns),
        Utc::now().to_rfc3339(),
    ])?;
    Ok(())
}

fn last_row_matches(
    conn: &Connection,
    account_key: &str,
    expected: &CompactRow,
) -> Result<bool> {
    let stored: Option<(String, String, String, String)> = conn
        .query_row(
            "SELECT pack, source_pack, timestamp, card_ids_json
             FROM rows WHERE account_key = ?1 ORDER BY id DESC LIMIT 1",
            params![account_key],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    let Some((pack, source_pack, timestamp, card_ids_json)) = stored else {
        return Ok(false);
    };
    let card_ids: Vec<String> = serde_json::from_str(&card_ids_json).unwrap_or_default();
    Ok(pack == expected.pack
        && source_pack == expected.source_pack
        && timestamp == expected.timestamp
        && card_ids == expected.card_ids)
}

fn update_account_record(conn: &Connection, summary: &AccountSummaryRecord) -> Result<()> {
    conn.execute(
        "UPDATE accounts SET
            source_type = ?2,
            source_file_name = ?3,
            file_label = ?4,
            display_name = ?5,
            account_name = ?6,
            friend_code = ?7,
            instance = ?8,
            device_account = ?9,
            collection_id = ?10,
            created_at = ?11,
            last_logged_in = ?12,
            last_pack_pulled = ?13,
            last_modified = ?14,
            pack_count = ?15,
            shinedust = ?16,
            shinedust_updated_at = ?17,
            pull_count = ?18,
            card_count = ?19,
            unique_card_count = ?20,
            registry_card_count = ?21,
            registered_cards_json = ?22,
            registry_imported_at = ?23
         WHERE account_key = ?1",
        params![
            summary.account,
            summary.source_type,
            summary.source_file_name,
            summary.file_label,
            summary.display_name,
            summary.account_name,
            summary.friend_code,
            summary.instance,
            summary.device_account,
            summary.collection_id,
            summary.created_at,
            summary.last_logged_in,
            summary.last_pack_pulled,
            summary.last_modified,
            summary.pack_count,
            summary.shinedust,
            summary.shinedust_updated_at,
            summary.pull_count,
            summary.card_count,
            summary.unique_card_count,
            summary.registry_card_count,
            serde_json::to_string(&summary.registered_cards)?,
            summary.registry_imported_at,
        ],
    )?;
    Ok(())
}

fn refresh_card_marks(
    conn: &Connection,
    inserter: &mut AccountInserter<'_>,
    account_key: &str,
    doc: &Value,
) -> Result<()> {
    conn.execute(
        "DELETE FROM card_marks WHERE account_key = ?1",
        params![account_key],
    )?;
    insert_card_marks_prepared(inserter, account_key, doc)?;
    Ok(())
}

fn delete_account(conn: &Connection, account_key: &str) -> Result<()> {
    conn.execute("DELETE FROM card_marks WHERE account_key = ?1", params![account_key])?;
    conn.execute(
        "DELETE FROM account_card_counts WHERE account_key = ?1",
        params![account_key],
    )?;
    conn.execute("DELETE FROM rows WHERE account_key = ?1", params![account_key])?;
    conn.execute("DELETE FROM accounts WHERE account_key = ?1", params![account_key])?;
    conn.execute("DELETE FROM source_files WHERE account_key = ?1", params![account_key])?;
    Ok(())
}

fn insert_rows_and_cards_prepared(
    inserter: &mut AccountInserter<'_>,
    summary: &AccountSummaryRecord,
    doc: &Value,
) -> Result<()> {
    if summary.source_type == "collection" {
        return Ok(());
    }

    let rows = compact_rows_from_doc(doc);
    let mut card_totals: HashMap<String, i64> = HashMap::new();

    for row in rows {
        let timestamp_ms = parse_timestamp_ms(&row.timestamp);
        let card_ids_json = serde_json::to_string(&row.card_ids)?;
        inserter.insert_row.execute(params![
            row.account,
            row.pack,
            row.source_pack,
            row.timestamp,
            timestamp_ms,
            row.card_ids.len() as i64,
            card_ids_json,
        ])?;
        for card_id in &row.card_ids {
            *card_totals.entry(card_id.clone()).or_insert(0) += 1;
        }
    }

    for (card_id, count) in card_totals {
        inserter
            .insert_card_count
            .execute(params![summary.account, card_id, count])?;
    }
    Ok(())
}

fn insert_card_marks_prepared(
    inserter: &mut AccountInserter<'_>,
    account_key: &str,
    doc: &Value,
) -> Result<()> {
    for (mark_type, key) in [("traded", "tradedCards"), ("shared", "sharedCards")] {
        let Some(obj) = doc.get(key).and_then(Value::as_object) else {
            continue;
        };
        for (card_id, value) in obj {
            let count = mark_count(value);
            if count <= 0 {
                continue;
            }
            let mark_value_json = serde_json::to_string(value)?;
            inserter.insert_card_mark.execute(params![
                account_key,
                card_id,
                mark_type,
                count,
                mark_value_json
            ])?;
        }
    }
    Ok(())
}

fn mark_count(value: &Value) -> i64 {
    match value {
        Value::Number(number) => number.as_i64().unwrap_or(1).max(1),
        Value::Object(obj) => obj
            .get("count")
            .or_else(|| obj.get("Count"))
            .and_then(Value::as_i64)
            .unwrap_or(1)
            .max(1),
        Value::Bool(true) => 1,
        _ => 1,
    }
}

fn read_db_stats(conn: &Connection, root: &Path) -> Result<DashboardDbStats> {
    let account_count: usize = conn.query_row("SELECT COUNT(*) FROM accounts", [], |row| row.get(0))?;
    let trade_account_count: usize = conn.query_row(
        "SELECT COUNT(*) FROM accounts WHERE source_type = 'trade'",
        [],
        |row| row.get(0),
    )?;
    let collection_count: usize = conn.query_row(
        "SELECT COUNT(*) FROM accounts WHERE source_type = 'collection'",
        [],
        |row| row.get(0),
    )?;
    let row_count: usize = conn.query_row("SELECT COUNT(*) FROM rows", [], |row| row.get(0))?;
    let total_cards: usize =
        conn.query_row("SELECT COALESCE(SUM(card_count), 0) FROM rows", [], |row| row.get(0))?;
    let unique_card_count: usize = conn.query_row(
        "SELECT COUNT(DISTINCT card_id) FROM account_card_counts",
        [],
        |row| row.get(0),
    )?;
    let db_bytes = database_bytes(root);

    Ok(DashboardDbStats {
        account_count,
        trade_account_count,
        collection_count,
        row_count,
        total_cards,
        unique_card_count,
        skipped_count: 0,
        db_bytes,
    })
}

fn file_fingerprint(path: &Path) -> Result<(u64, u128)> {
    let meta = fs::metadata(path).with_context(|| format!("Could not stat {:?}", path))?;
    let modified_ns = meta
        .modified()
        .unwrap_or(SystemTime::UNIX_EPOCH)
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_nanos();
    Ok((meta.len(), modified_ns))
}

fn modified_ns_to_i64(modified_ns: u128) -> i64 {
    modified_ns.min(i64::MAX as u128) as i64
}

fn database_bytes(root: &Path) -> u64 {
    let cache_dir = dashboard_cache_dir(root);
    ["dashboard.db", "dashboard.db-wal", "dashboard.db-shm"]
        .iter()
        .map(|name| cache_dir.join(name))
        .filter_map(|path| fs::metadata(path).ok())
        .map(|meta| meta.len())
        .sum()
}

fn account_key_from_source(source_key: &str, path: &Path) -> String {
    path.file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| source_key.replace('/', "_"))
}

fn parse_timestamp_ms(text: &str) -> Option<i64> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(dt) = NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%d %H:%M:%S") {
        return Utc.from_utc_datetime(&dt).timestamp_millis().into();
    }
    if trimmed.len() == 14 && trimmed.chars().all(|c| c.is_ascii_digit()) {
        if let Ok(dt) = NaiveDateTime::parse_from_str(trimmed, "%Y%m%d%H%M%S") {
            return Utc.from_utc_datetime(&dt).timestamp_millis().into();
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;

    fn test_root() -> PathBuf {
        std::env::temp_dir().join(format!("carddb_sqlite_test_{}", std::process::id()))
    }

    #[test]
    fn parse_timestamp_ms_supports_common_formats() {
        assert!(parse_timestamp_ms("2026-05-05 04:53:46").is_some());
        assert!(parse_timestamp_ms("20260505045346").is_some());
    }

    #[test]
    fn sqlite_rebuild_and_incremental_sync_round_trip() {
        let root = test_root();
        let _ = fs::remove_dir_all(&root);
        let accounts_dir = root.join("Accounts/Cards/accounts");
        fs::create_dir_all(&accounts_dir).unwrap();
        let doc = json!({
            "deviceAccount": "dev1",
            "metadata": { "accountName": "Test" },
            "pulls": [
                { "timestamp": "2026-05-05 04:53:46", "pack": "A1", "cards": ["PK_01_000001", "PK_01_000002"] }
            ],
            "tradedCards": { "PK_01_000001": 1 },
            "sharedCards": {}
        });
        fs::write(
            accounts_dir.join("dev1.json"),
            serde_json::to_string_pretty(&doc).unwrap(),
        )
        .unwrap();

        let stats = rebuild_dashboard_db(&root).unwrap();
        assert_eq!(stats.account_count, 1);
        assert_eq!(stats.row_count, 1);
        assert_eq!(stats.total_cards, 2);

        let cold = sync_dashboard_db(&root, None).unwrap();
        assert_eq!(cold.dirty_accounts, 0);

        fs::write(
            accounts_dir.join("dev1.json"),
            serde_json::to_string_pretty(&json!({
                "deviceAccount": "dev1",
                "metadata": { "accountName": "Test" },
                "pulls": [
                    { "timestamp": "2026-05-05 04:53:46", "pack": "A1", "cards": ["PK_01_000001"] },
                    { "timestamp": "2026-05-05 05:00:00", "pack": "A1", "cards": ["PK_01_000003"] }
                ],
                "tradedCards": {},
                "sharedCards": {}
            }))
            .unwrap(),
        )
        .unwrap();

        let warm = sync_dashboard_db(&root, None).unwrap();
        assert_eq!(warm.dirty_accounts, 1);
        assert_eq!(warm.reindexed_accounts, 1);

        let conn = open_connection(&root).unwrap();
        let row_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rows", [], |row| row.get(0))
            .unwrap();
        assert_eq!(row_count, 2);

        let _ = fs::remove_dir_all(&root);
    }
}
