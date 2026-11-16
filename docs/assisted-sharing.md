# Assisted card gifting

Share an exact card with a phone recipient using the donor's ADB-connected emulator. The worker supports the English game at **540 × 960**, verifies each confirmation screen, and records a local journal before sending input.

Sharing accepts **1–4 diamond** rarities, including eligible foil variants. Promo cards are excluded by the planner. Star and shiny cards require trading. Sharing unlocks after 14 days, costs no shinedust and uses the recipient's single daily receive slot. Saved metadata cannot verify that slot or server eligibility; check the game. See [Pokémon Support](https://support.pokemon.com/hc/en-us/articles/30332621133204-Pok%C3%A9mon-TCG-Pocket-Sharing-and-Social-FAQ) and the [official app description](https://play.google.com/store/apps/details?id=jp.pokemon.pokemontcgp).

## Install and find a donor

Use Python 3.10 or later and the same dependencies as the trade worker:

```powershell
py -m pip install -r Scripts/trade-requirements.txt
py Accounts/plan_trade.py --mode share --card-id EXACT_CARD_ID
```

Use the exact version ID: foil and regular cards can have identical names and artwork. The planner validates sharing rarity against `Helper/cardmaster.json`, accounts for past trades/shares and checks saved-login paths without reading credentials. Unknown shinedust does not block sharing.

## Send a gift

1. Safely preserve and stop farming using your installation's normal procedure. Suspend any watchdog that could restart it; give the worker exclusive emulator control.
2. Load the donor and add the recipient as a friend. They accept the request on their phone. Open **Social Hub → Share**, choose the recipient and select the exact card/version.
3. Leave the full-card preview showing **Share Partner**, **Number owned** and the **Share** button open. Start a fresh private run directory:

```powershell
py Scripts/share_worker.py --adb "C:\path\to\adb.exe" --serial "127.0.0.1:16416" --recipient "Verified profile name and friend ID" --card "Exact card name, set, number and foil/regular version" --run-dir Accounts/Trades/share-001
```

Open the printed screenshot and verify the exact version and recipient. Type the requested confirmation to authorize sending that card. Add `--allow-last-copy` only when you intend to consume the donor's final copy. The worker compares card and recipient imagery again before acting; animation may conservatively stop the check. The worker does not read identity text itself.

The worker confirms the gift, handles the optional last-copy warning and swipes the card. It records completion only after recognizing the game's **The card was shared with your friend** message. The recipient can claim the card from **Home → Gifts**; they do not select a return card. A donor-side completion journal does not prove the recipient has claimed it.

Record the outgoing shared card in the dashboard, save the donor and restore your farming identity before restarting farming. The worker does not load accounts, handle friends, choose cards, change the inventory ledger, manage watchdogs or restore farming.

## Interrupted or unknown screens

Inputs are journaled before sending. Existing journals block a new send, including when the server may already have accepted it. The completion message is transient: if capture misses it, the worker stops with an unresolved journal. Check **Social Hub → Share → History** and the recipient's Gifts before reconciling; never repeat the send to recover from missing evidence.

ADB calls, transitions and the 20-minute session are bounded. Unknown screens, changed resolution, changed card/recipient and interrupted actions stop the worker. No automatic cancellation or retry occurs. Add `--inspect` to capture and classify without sending input; it can inspect an existing run directory without changing the journal.

The device lock coordinates these Python workers on the same host and lock directory. It does not stop AHK, watchdogs or manual taps. Keep the emulator exclusive until finished. Keep journals and screenshots private; `Accounts/Trades/` is ignored by Git.

## Development checks

```powershell
py -m unittest discover -s Accounts/tests -p "test_plan_trade.py"
py -m unittest discover -s Scripts/tests -p "test_*worker.py"
```

Bundled UI signatures cover preview, confirmation, last-copy warning, send swipe and completion. A manually completed foil gift provided the observed flow; the standalone worker still needs a supervised live run with a recipient's available daily slot.
