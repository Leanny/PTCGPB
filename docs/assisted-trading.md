# Assisted donor trading

Find a saved donor for an exact card, then run the donor confirmation flow while the recipient responds on their phone. The worker supports the English game at **540 × 960** through ADB. It checks each screen against bundled UI templates and records screenshots and a journal locally.

This is an assisted tool: account loading, adding the recipient as a friend and selecting the exact card remain manual. It does not run alongside the farmer, manage watchdogs, or update the inventory ledger automatically. For gifting eligible diamond cards, see [Assisted card gifting](assisted-sharing.md).

## Install

Use Python 3.10 or later and your emulator's ADB executable:

```powershell
py -m pip install -r Scripts/trade-requirements.txt
```

## Find a donor

Use the exact card ID from the card database. A name alone does not identify its set or rarity. The planner reads inventory metadata and checks saved-login file existence without opening login files.

```powershell
py Accounts/plan_trade.py --card-id PK_20_019750_00
```

Age, inventory and shinedust are estimates from saved metadata. Confirm trading is unlocked, the card is available and the stamina/cost are sufficient in-game. The planner does not query the server.

## Run a trade

1. Stop farming using your installation's account-preserving stop procedure. Suspend anything that could restart farming. Preserve the current account before loading a donor, and give this worker exclusive use of the emulator.
2. Load the saved donor, add the recipient as a friend and have them accept on their phone. Open Trade, choose the recipient, select the exact card and continue to the full outgoing-card preview with its cost and **OK** button. Leave that screen open.
3. Run the worker with a new private directory for this trade:

```powershell
py Scripts/trade_worker.py --adb "C:\path\to\adb.exe" --serial "127.0.0.1:16416" --recipient "Recipient profile name and friend ID" --card "Exact card name, set, collector number and rarity" --run-dir Accounts/Trades/trade-001
```

The worker prints a screenshot path. Open it, verify the card/version, recipient and cost, then type the requested confirmation. The profile name must belong to the friend ID you verified during setup; the worker does not read or verify identity text itself. Add `--allow-last-copy` only if you intend to consume the donor's final copy. The worker compares card and recipient image regions again before sending input; artwork animation can conservatively stop that check.

The worker submits the offer and refreshes while waiting for the recipient. After they respond, inspect the new screenshot and check both cards and the recipient. The second confirmation authorizes finalizing the exchange. The worker sends the card and stops only when it recognizes the **Got it!** screen. It leaves the game there for inspection and saves completion evidence in `journal.json`.

After success, finish any card-registration screens, record the outgoing and incoming card in the dashboard, and save the donor. Restore the farming identity using your installation's normal procedure before resuming farming.

## Interrupted or unfamiliar screens

A session is limited to 20 minutes, including operator input. ADB commands and state transitions have shorter timeouts. A missed transition, changed resolution, unfamiliar modal or interrupted input stops the worker. It never automatically cancels a trade or restarts farming.

Each input is journaled **before** it is sent. An existing journal blocks a new run, including when the previous action may have reached the server. Inspect the game and reconcile the trade first; starting another run directory is not a recovery procedure. A pending trade must be completed or explicitly resolved in-game before its donor returns to farming.

To capture/classify without sending input, add `--inspect` to the same command. It may inspect an existing run directory without changing its journal. Unknown screens are reported as `null`.

Device locks coordinate copies of this Python worker on the same host and lock directory. They do not coordinate with AHK, watchdogs, other hosts or manual taps. Keep those stopped throughout the session and do not operate the emulator while the worker is taking an action.

Keep `Accounts/Trades/` private: its screenshots and journal contain profile names, card information and recipient details. No account credentials are stored by these tools.

## Development checks

```powershell
py -m unittest discover -s Accounts/tests -p "test_plan_trade.py"
py -m unittest discover -s Scripts/tests -p "test_trade_worker.py"
```

UI signatures cover preview, offer confirmation, last-copy warning, offered, waiting, response, final confirmation, send swipe and receipt. Templates contain only UI text and buttons. Changes to game language, layout or rendering can require new signatures; do not increase tolerance to bypass an unrecognized screen.
