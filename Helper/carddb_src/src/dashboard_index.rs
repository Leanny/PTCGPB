use anyhow::Result;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

pub struct DashboardIndexStats {
    pub account_count: usize,
    pub trade_account_count: usize,
    pub collection_count: usize,
    pub row_count: usize,
    pub total_cards: usize,
    pub unique_card_count: usize,
    pub skipped_count: usize,
}

pub fn dashboard_cache_dir(root: &Path) -> PathBuf {
    super::cards_dir(root).join("database_cache")
}

pub fn summary_json_path(root: &Path) -> PathBuf {
    dashboard_cache_dir(root).join("accounts-summary.json")
}

pub fn rows_jsonl_path(root: &Path) -> PathBuf {
    dashboard_cache_dir(root).join("dashboard-rows.jsonl")
}

fn index_meta_path(root: &Path) -> PathBuf {
    dashboard_cache_dir(root).join("dashboard-index.meta.json")
}

pub fn compute_dashboard_manifest_signature(root: &Path) -> Result<(String, usize, u64)> {
    let paths = super::gather_dashboard_paths(root)?;
    let mut manifest = String::new();
    let mut source_count = 0usize;
    let mut source_bytes = 0u64;

    for (source_name, path) in &paths {
        let metadata = fs::metadata(path)?;
        source_count += 1;
        source_bytes = source_bytes.saturating_add(metadata.len());
        let modified = metadata
            .modified()
            .ok()
            .and_then(|time| {
                time.duration_since(std::time::UNIX_EPOCH)
                    .ok()
                    .map(|d| d.as_nanos())
            })
            .unwrap_or(0);
        manifest.push_str(source_name);
        manifest.push('|');
        manifest.push_str(&metadata.len().to_string());
        manifest.push('|');
        manifest.push_str(&modified.to_string());
        manifest.push('\n');
    }

    let mut hasher = Sha256::new();
    hasher.update(manifest.as_bytes());
    let signature = format!("{:x}", hasher.finalize());
    Ok((signature, source_count, source_bytes))
}

pub fn is_index_current(root: &Path) -> Result<bool> {
    let meta_path = index_meta_path(root);
    if !meta_path.exists() {
        return Ok(false);
    }
    let (signature, _, _) = compute_dashboard_manifest_signature(root)?;
    let meta_text = fs::read_to_string(&meta_path)?;
    let meta: Value = serde_json::from_str(&meta_text)?;
    Ok(meta
        .get("signature")
        .and_then(Value::as_str)
        .is_some_and(|stored| stored == signature))
}

fn json_str_value(value: &Value, keys: &[&str]) -> String {
    for key in keys {
        if let Some(raw) = value.get(*key) {
            if let Some(text) = raw.as_str() {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    return trimmed.to_owned();
                }
            }
        }
    }
    String::new()
}

fn json_i64_value(value: &Value, keys: &[&str]) -> i64 {
    for key in keys {
        if let Some(raw) = value.get(*key) {
            if let Some(number) = raw.as_i64() {
                return number;
            }
            if let Some(text) = raw.as_str() {
                let cleaned = text.trim().replace(',', "");
                if let Ok(number) = cleaned.parse::<i64>() {
                    return number;
                }
            }
        }
    }
    0
}

fn card_ids_from_value(value: &Value) -> Vec<String> {
    match value {
        Value::Array(items) => items
            .iter()
            .filter_map(|item| item.as_str().map(str::trim).filter(|s| !s.is_empty()))
            .map(str::to_owned)
            .collect(),
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return Vec::new();
            }
            let separator = if trimmed.contains('|') {
                '|'
            } else if trimmed.contains(';') {
                ';'
            } else {
                ' '
            };
            trimmed
                .split(separator)
                .map(str::trim)
                .filter(|part| !part.is_empty())
                .map(|part| part.trim_matches('"').trim_matches('\'').to_owned())
                .collect()
        }
        _ => Vec::new(),
    }
}

fn card_ids_from_pull(pull: &Value) -> Vec<String> {
    card_ids_from_value(
        &pull
            .get("cards")
            .or_else(|| pull.get("Cards"))
            .or_else(|| pull.get("cardIds"))
            .or_else(|| pull.get("CardIds"))
            .or_else(|| pull.get("card"))
            .or_else(|| pull.get("Card"))
            .cloned()
            .unwrap_or(Value::Null),
    )
}

fn pack_from_pull(pull: &Value) -> String {
    let value = pull
        .get("pack")
        .or_else(|| pull.get("Pack"))
        .or_else(|| pull.get("packCode"))
        .or_else(|| pull.get("PackCode"))
        .or_else(|| pull.get("expansion"))
        .or_else(|| pull.get("Expansion"))
        .cloned()
        .unwrap_or(Value::Null);

    match value {
        Value::Array(items) => items
            .iter()
            .filter_map(|item| item.as_str().map(str::trim).filter(|s| !s.is_empty()))
            .collect::<Vec<_>>()
            .join(", "),
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                "(blank pack)".to_owned()
            } else {
                trimmed.to_owned()
            }
        }
        _ => "(blank pack)".to_owned(),
    }
}

fn timestamp_from_pull(pull: &Value) -> String {
    json_str_value(
        pull,
        &[
            "timestamp",
            "Timestamp",
            "time",
            "date",
            "datetime",
            "createdAt",
        ],
    )
}

pub(crate) struct AccountSummaryRecord {
    pub(crate) account: String,
    pub(crate) source_type: String,
    pub(crate) source_file_name: String,
    pub(crate) file_label: String,
    pub(crate) display_name: String,
    pub(crate) account_name: String,
    pub(crate) friend_code: String,
    pub(crate) instance: String,
    pub(crate) created_at: String,
    pub(crate) last_logged_in: String,
    pub(crate) last_pack_pulled: String,
    pub(crate) last_modified: String,
    pub(crate) pack_count: i64,
    pub(crate) shinedust: i64,
    pub(crate) shinedust_updated_at: String,
    pub(crate) pull_count: i64,
    pub(crate) card_count: i64,
    pub(crate) unique_card_count: i64,
    pub(crate) registry_card_count: i64,
    pub(crate) registered_cards: Vec<String>,
    pub(crate) device_account: String,
    pub(crate) registry_imported_at: String,
    pub(crate) collection_id: String,
}

#[derive(Clone)]
pub(crate) struct CompactRow {
    pub(crate) account: String,
    pub(crate) pack: String,
    pub(crate) source_pack: String,
    pub(crate) timestamp: String,
    pub(crate) card_ids: Vec<String>,
}

pub(crate) fn build_account_summary(doc: &Value) -> Option<AccountSummaryRecord> {
    if !doc.is_object() {
        return None;
    }

    let source_type = json_str_value(doc, &["sourceType", "SourceType"]);
    let source_file_name = json_str_value(doc, &["sourceFileName", "SourceFileName"]);
    let is_collection =
        source_type.eq_ignore_ascii_case("collection") || source_file_name.starts_with("collections/");

    let mut account = if is_collection {
        let mut collection_account =
            json_str_value(doc, &["collectionId", "CollectionId"]);
        if collection_account.is_empty() {
            if let Some(leaf) = source_file_name.split('/').next_back() {
                collection_account = leaf.trim_end_matches(".json").to_owned();
            }
        }
        collection_account
    } else {
        json_str_value(
            doc,
            &[
                "deviceAccount",
                "DeviceAccount",
                "account",
                "Account",
            ],
        )
    };
    if account.is_empty() {
        return None;
    }

    let metadata = doc
        .get("metadata")
        .or_else(|| doc.get("Metadata"))
        .cloned()
        .unwrap_or_else(|| json!({}));

    let file_label = json_str_value(
        &metadata,
        &[
            "fileName",
            "FileName",
            "cleanFilename",
            "filename",
            "originalFilename",
        ],
    );
    let file_label = if file_label.is_empty() {
        source_file_name.clone()
    } else {
        file_label
    };

    let shinedust_node = metadata
        .get("shinedust")
        .or_else(|| metadata.get("Shinedust"))
        .or_else(|| metadata.get("dust"));
    let shinedust = match shinedust_node {
        Some(Value::Object(obj)) => {
            json_i64_value(&Value::Object(obj.clone()), &["value", "Value", "amount"])
        }
        Some(other) => json_i64_value(other, &[]),
        None => 0,
    };

    let registered_cards = doc
        .get("registeredCards")
        .or_else(|| doc.get("RegisteredCards"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::trim).filter(|s| !s.is_empty()))
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let pulls = doc
        .get("pulls")
        .or_else(|| doc.get("Pulls"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mut unique_cards = HashSet::new();
    let mut card_count = 0i64;
    for pull in &pulls {
        let ids = card_ids_from_pull(pull);
        card_count += ids.len() as i64;
        unique_cards.extend(ids);
    }

    Some(AccountSummaryRecord {
        account: account.clone(),
        source_type: if is_collection {
            "collection".to_owned()
        } else {
            "trade".to_owned()
        },
        source_file_name,
        file_label,
        display_name: json_str_value(doc, &["displayName", "DisplayName"]),
        account_name: json_str_value(&metadata, &["accountName", "AccountName"]),
        friend_code: json_str_value(&metadata, &["friendCode", "FriendCode", "friend_code"]),
        instance: json_str_value(&metadata, &["instance", "Instance"]),
        created_at: json_str_value(&metadata, &["createdAt", "CreatedAt"]),
        last_logged_in: json_str_value(&metadata, &["lastLoggedIn", "LastLoggedIn"]),
        last_pack_pulled: json_str_value(&metadata, &["lastPackPulled", "LastPackPulled"]),
        last_modified: json_str_value(&metadata, &["lastModified", "LastModified"]),
        pack_count: json_i64_value(&metadata, &["packCount", "PackCount"]),
        shinedust,
        shinedust_updated_at: match shinedust_node {
            Some(Value::Object(obj)) => json_str_value(
                &Value::Object(obj.clone()),
                &["lastUpdatedAt", "updatedAt", "timestamp"],
            ),
            _ => String::new(),
        },
        pull_count: if is_collection {
            0
        } else {
            pulls.len() as i64
        },
        card_count,
        unique_card_count: unique_cards.len() as i64,
        registry_card_count: registered_cards.len() as i64,
        registered_cards,
        device_account: json_str_value(doc, &["deviceAccount", "DeviceAccount"]),
        registry_imported_at: json_str_value(
            &metadata,
            &["registryImportedAt", "RegistryImportedAt"],
        ),
        collection_id: json_str_value(doc, &["collectionId", "CollectionId"]),
    })
}

pub(crate) fn compact_rows_from_doc(doc: &Value) -> Vec<CompactRow> {
    let summary = match build_account_summary(doc) {
        Some(summary) => summary,
        None => return Vec::new(),
    };
    compact_rows_for_account(doc, &summary.account, summary.source_type == "collection")
}

pub(crate) fn compact_rows_for_account(
    doc: &Value,
    account: &str,
    is_collection: bool,
) -> Vec<CompactRow> {
    if is_collection {
        return Vec::new();
    }

    let pulls = doc
        .get("pulls")
        .or_else(|| doc.get("Pulls"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    compact_rows_from_pull_values(&pulls, account, 0).2
}

/// Single pass over pulls: total compact row count, optional boundary row at `stored_rows - 1`,
/// and compact rows from index `stored_rows` onward.
pub(crate) fn scan_compact_pulls(
    doc: &Value,
    account: &str,
    stored_rows: usize,
) -> (usize, Option<CompactRow>, Vec<CompactRow>) {
    let pulls = doc
        .get("pulls")
        .or_else(|| doc.get("Pulls"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    compact_rows_from_pull_values(&pulls, account, stored_rows)
}

fn compact_row_from_pull(pull: &Value, account: &str) -> Option<CompactRow> {
    let card_ids = card_ids_from_pull(pull);
    if card_ids.is_empty() {
        return None;
    }
    let pack = pack_from_pull(pull);
    Some(CompactRow {
        account: account.to_owned(),
        pack: pack.clone(),
        source_pack: pack,
        timestamp: timestamp_from_pull(pull),
        card_ids,
    })
}

fn compact_rows_from_pull_values(
    pulls: &[Value],
    account: &str,
    stored_rows: usize,
) -> (usize, Option<CompactRow>, Vec<CompactRow>) {
    let mut compact_index = 0usize;
    let mut boundary_row = None;
    let mut new_rows = Vec::new();

    for pull in pulls {
        let Some(row) = compact_row_from_pull(pull, account) else {
            continue;
        };
        if stored_rows > 0 && compact_index == stored_rows - 1 {
            boundary_row = Some(row.clone());
        }
        if compact_index >= stored_rows {
            new_rows.push(row);
        }
        compact_index += 1;
    }

    (compact_index, boundary_row, new_rows)
}

fn write_compact_row(writer: &mut impl Write, row: &CompactRow) -> Result<()> {
    let line = json!({
        "account": row.account,
        "pack": row.pack,
        "sourcePack": row.source_pack,
        "timestamp": row.timestamp,
        "cardIds": row.card_ids,
    });
    serde_json::to_writer(&mut *writer, &line)?;
    writer.write_all(b"\n")?;
    Ok(())
}

fn summary_entry_json(summary: &AccountSummaryRecord) -> Value {
    json!({
        "account": summary.account,
        "sourceType": summary.source_type,
        "sourceFileName": summary.source_file_name,
        "fileLabel": summary.file_label,
        "displayName": summary.display_name,
        "accountName": summary.account_name,
        "friendCode": summary.friend_code,
        "instance": summary.instance,
        "metadata": {
            "createdAt": summary.created_at,
            "lastLoggedIn": summary.last_logged_in,
            "lastPackPulled": summary.last_pack_pulled,
            "lastModified": summary.last_modified,
            "packCount": summary.pack_count,
            "accountName": summary.account_name,
            "friendCode": summary.friend_code,
            "instance": summary.instance,
            "registryImportedAt": summary.registry_imported_at,
        },
        "shinedust": summary.shinedust,
        "pullCount": summary.pull_count,
        "cardCount": summary.card_count,
        "uniqueCardCount": summary.unique_card_count,
        "registryCardCount": summary.registry_card_count,
        "registeredCards": summary.registered_cards,
        "deviceAccount": summary.device_account,
        "collectionId": summary.collection_id,
    })
}

pub fn build_dashboard_index(
    root: &Path,
    signature: Option<&str>,
    source_count: Option<usize>,
    source_bytes: Option<u64>,
) -> Result<DashboardIndexStats> {
    let (computed_signature, computed_count, computed_bytes) =
        compute_dashboard_manifest_signature(root)?;
    let signature = signature.unwrap_or(&computed_signature);
    let source_count = source_count.unwrap_or(computed_count);
    let source_bytes = source_bytes.unwrap_or(computed_bytes);

    fs::create_dir_all(dashboard_cache_dir(root))?;

    let paths = super::gather_dashboard_paths(root)?;
    let mut summaries = Vec::new();
    let mut skipped = Vec::new();
    let mut row_count = 0usize;
    let mut total_cards = 0usize;
    let mut unique_cards = HashSet::new();
    let mut trade_account_count = 0usize;
    let mut collection_count = 0usize;

    let rows_file = File::create(rows_jsonl_path(root))?;
    let mut rows_writer = BufWriter::with_capacity(8 * 1024 * 1024, rows_file);

    for (source_file_name, path) in &paths {
        match super::load_dashboard_account_document(path, source_file_name) {
            Ok(doc) => {
                let Some(summary) = build_account_summary(&doc) else {
                    continue;
                };
                if summary.source_type == "collection" {
                    collection_count += 1;
                } else {
                    trade_account_count += 1;
                }

                for row in compact_rows_from_doc(&doc) {
                    total_cards += row.card_ids.len();
                    for card_id in &row.card_ids {
                        unique_cards.insert(card_id.clone());
                    }
                    write_compact_row(&mut rows_writer, &row)?;
                    row_count += 1;
                }

                summaries.push(summary);
            }
            Err(err) => skipped.push(json!({
                "file": source_file_name,
                "error": err.to_string(),
            })),
        }
    }
    rows_writer.flush()?;

    summaries.sort_by(|a, b| a.account.cmp(&b.account));

    let account_count = summaries.len();
    let payload = json!({
        "ok": true,
        "source": "Accounts/Cards/accounts+collections",
        "signature": signature,
        "accountCount": account_count,
        "tradeAccountCount": trade_account_count,
        "collectionRegistryCount": collection_count,
        "rowCount": row_count,
        "totalCards": total_cards,
        "uniqueCardCount": unique_cards.len(),
        "skippedCount": skipped.len(),
        "skipped": skipped,
        "accounts": summaries.iter().map(summary_entry_json).collect::<Vec<_>>(),
    });

    super::write_file_atomic(&summary_json_path(root), &serde_json::to_vec(&payload)?)?;

    let meta = json!({
        "signature": signature,
        "sourceCount": source_count,
        "sourceBytes": source_bytes,
        "accountCount": account_count,
        "tradeAccountCount": trade_account_count,
        "collectionRegistryCount": collection_count,
        "rowCount": row_count,
        "totalCards": total_cards,
        "uniqueCardCount": unique_cards.len(),
        "skippedCount": skipped.len(),
        "generatedAt": chrono::Utc::now().to_rfc3339(),
        "generator": "carddb",
        "kind": "dashboard-index",
    });
    super::write_file_atomic(&index_meta_path(root), &serde_json::to_vec(&meta)?)?;

    Ok(DashboardIndexStats {
        account_count,
        trade_account_count,
        collection_count,
        row_count,
        total_cards,
        unique_card_count: unique_cards.len(),
        skipped_count: skipped.len(),
    })
}

pub fn ensure_dashboard_index(root: &Path) -> Result<bool> {
    if is_index_current(root)?
        && summary_json_path(root).exists()
        && rows_jsonl_path(root).exists()
    {
        return Ok(true);
    }
    build_dashboard_index(root, None, None, None)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn card_ids_from_pull_supports_pipe_separated_string() {
        let pull = json!({
            "cards": "PK_01_000001|PK_01_000002",
            "pack": "A1",
            "timestamp": "2026-05-05 04:53:46",
        });
        assert_eq!(
            card_ids_from_pull(&pull),
            vec!["PK_01_000001".to_owned(), "PK_01_000002".to_owned()]
        );
    }
}
