# AutoHotkey fallback for the Rust helpers

AHK v1 ports of `Helper\carddb.exe` and `Helper\cardimage.exe`. Use them on systems where antivirus software quarantines the Rust binaries. They are not wired into the bot yet.

| File | Replaces |
|---|---|
| `carddb.ahk` | `carddb.exe` (all bot-facing subcommands) |
| `cardimage.ahk` | `cardimage.exe` |
| `lib\Json.ahk` | JSON library that matches serde_json's output (ordered keys, case-sensitive keys) |
| `lib\Common.ahk` | Shared helpers: files, time, SHA-256, downloads, cardmap lookups, CLI parsing |

## Usage

The command lines are the same as for the exe files, with the interpreter in front:

```
"<AutoHotkey.exe>" "Helper\ahk\carddb.ahk" --root "<bot folder>" schedule-accounts --instance 1 ...
"<AutoHotkey.exe>" "Helper\ahk\cardimage.ahk" list.txt out.png --cols 3 --highlight A,B
```

From the bot, `A_AhkPath` gives the interpreter path. The following behave the same as with the exe files: exit codes, stdout, the progress and result files in `Accounts\Saved`, `carddb_error.txt` and `carddb_balance.log`.

Requirements: AutoHotkey v1.1.31 or newer, Unicode build (tested on 1.1.37.02). `cardimage.ahk` also includes `Scripts\Include\Gdip_All.ahk` and the font `Helper\cardimage_src\src\font.ttf`.

## What is ported

Ported: `merge-card-db`, `merge-metadata`, `ensure-metadata`, `schedule-accounts`, `balance-xmls`, `extract-metadata`, `clear-flag`, `clear-pull-history`, `import-history`, `import-registry`, `import-collection`, `format-account`, `append-pull`, `snapshot-accounts`, `repair-accounts-from-snapshot`.

Not ported: `serve` and the dashboard index/SQLite commands (`build-dashboard-index`, `ensure-dashboard-index`, `rebuild-dashboard-db`, `sync-dashboard-db`, `checkpoint-dashboard-db`). `start_card_dashboard_server.ps1` already runs the dashboard when `carddb.exe` is missing. These commands exit with code 1.

## Compatibility

The ports were diff-tested against the Rust builds on generated account folders. Account, collection, list and result files are byte-identical (apart from timestamps taken a second apart). Both implementations can therefore work on the same data and be swapped at any time.

Known differences:

- **Corruption check.** An account file in the usual pretty-printed layout is accepted when its top-level structure is intact (not empty, not zero-filled, not truncated). The nested pull history is not fully validated. This keeps `schedule-accounts`, `clear-flag` and similar commands from parsing every pull. Files in any other layout get a full parse, as in Rust.
- **Repair archive layout.** `accounts-repair.archive.json` is written with one compact account per line instead of a single line. It is still valid JSON and `carddb.exe` reads it. Archives written by `carddb.exe` are read as well.
- **Argument errors** exit with code 2 like clap, with shorter messages and no usage text.
- **cardimage rendering** uses GDI+ instead of the Rust image libraries. The layout, sizes, colors and badge match; anti-aliasing and resampling differ slightly.

## Performance

Measured on 1,500 accounts with 300 pulls each (106 MB):

| Command | carddb.exe | carddb.ahk |
|---|---|---|
| schedule-accounts | 2.1 s | 1.9 s |
| append-pull | 0.02 s | 0.05 s |
| clear-flag | 16 s | 17.5 s |
| balance-xmls | 6.1 s | 6.6 s |
| snapshot-accounts | 20 s | 4–5 s |
