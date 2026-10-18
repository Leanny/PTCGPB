#!/usr/bin/env python3
"""Read-only donor preflight. Estimates from saved metadata require in-game verification."""
import argparse
from collections import Counter
from datetime import datetime, timedelta
import json
import math
from pathlib import Path
import re
import sys

DUST_COSTS = {100: 0, 200: 0, 300: 1200, 400: 5000, 500: 4000,
              600: 25000, 700: 25000, 830: 10000, 860: 30000}
ACCOUNT_ID = re.compile(r"[0-9a-fA-F]{16}\Z")


def read_json(path):
    with path.open(encoding="utf-8-sig") as stream:
        return json.load(stream)


def parse_time(value, timezone):
    value = str(value).strip()
    stamp = (datetime.strptime(value, "%Y%m%d%H%M%S") if
             re.fullmatch(r"\d{14}", value) else
             datetime.fromisoformat(value.replace("Z", "+00:00")))
    return stamp.replace(tzinfo=timezone) if stamp.tzinfo is None else stamp


def mark_count(value):
    # A legacy true/object mark without an explicit count represents one copy.
    if value is False or value is None:
        return 0
    if isinstance(value, dict):
        count = value.get("count", 1)
        if not isinstance(count, (int, float)) or isinstance(count, bool) or count <= 0:
            return 1
        return count
    return 1


def pairings(meta):
    if not isinstance(meta, dict):
        return []
    values = meta.get("pairings", [])
    if isinstance(values, dict):
        values = [values] if "receivedCardId" in values else list(values.values())
    if not isinstance(values, list):
        raise ValueError("invalid trade pairings")
    received = [str(p["receivedCardId"]).strip() for p in values
                if isinstance(p, dict) and p.get("receivedCardId")]
    if not received and meta.get("receivedCardId"):
        received = [str(meta["receivedCardId"]).strip()]
    return received


def available_copies(doc, card_id):
    counts = Counter()
    pulls = doc.get("pulls", [])
    if not isinstance(pulls, list):
        raise ValueError("invalid pulls")
    for pull in pulls:
        cards = pull.get("cards", [])
        if not isinstance(cards, list):
            raise ValueError("pull cards must be an array")
        counts.update(str(card).strip() for card in cards)
    traded, shared = doc.get("tradedCards", {}), doc.get("sharedCards", {})
    if not isinstance(traded, dict) or not isinstance(shared, dict):
        raise ValueError("invalid card marks")
    for meta in traded.values():
        counts.update(pairings(meta))
    # registeredCards is a Pokédex set, not an inventory quantity.
    return max(0, counts[card_id] - mark_count(traded.get(card_id)) -
               mark_count(shared.get(card_id)))


def inspect_account(doc, source, saved_files, card_id, cost, now, minimum_age_days):
    account = str(doc.get("deviceAccount", ""))
    metadata = doc.get("metadata", {})
    if not isinstance(metadata, dict):
        raise ValueError("invalid metadata")
    blockers = []
    if not ACCOUNT_ID.fullmatch(account) or source.stem.lower() != account.lower():
        blockers.append("invalid_or_mismatched_account_id")
    copies = available_copies(doc, card_id)
    if copies < 1:
        blockers.append("no_remaining_copy")
    age = None
    unlock_at = None
    try:
        created = parse_time(metadata.get("createdAt", ""), now.tzinfo)
        age = (now - created).total_seconds() / 86400
        unlock_at = (created + timedelta(days=minimum_age_days)).isoformat()
        if age < minimum_age_days:
            blockers.append("too_young")
    except (ValueError, TypeError, OverflowError):
        blockers.append("unknown_creation_time")
    dust = metadata.get("shinedust")
    if isinstance(dust, dict):
        dust = dust.get("value")
    try:
        if dust is None or isinstance(dust, bool):
            raise ValueError()
        dust = int(str(dust).replace(",", ""))
        if dust < 0:
            raise ValueError()
        if dust < cost:
            blockers.append("insufficient_shinedust")
    except (ValueError, TypeError):
        dust = None
        blockers.append("unknown_shinedust")
    saved = saved_files.get(account.lower(), [])
    if not saved:
        blockers.append("missing_saved_login")
    elif len(saved) > 1:
        blockers.append("ambiguous_saved_login")
    return {"account_id": account, "account_name": metadata.get("accountName", ""),
            "source": str(source), "saved_login": str(saved[0]) if len(saved) == 1 else None,
            "remaining_copies": copies, "age_days": round(age, 4) if age is not None else None,
            "minimum_age_reached_at": unlock_at, "shinedust": dust,
            "blockers": blockers, "candidate": not blockers,
            "in_game_verified": False}


def plan(accounts, saved, card_id, cost, now, minimum_age_days):
    saved_files = {}
    # Only enumerate paths. Login XML contents are never opened.
    for path in saved.rglob("*.xml"):
        saved_files.setdefault(path.stem.lower(), []).append(path)
    results, errors = [], []
    seen = set()
    for source in sorted(accounts.glob("*.json")):
        try:
            doc = read_json(source)
            result = inspect_account(doc, source, saved_files, card_id, cost, now, minimum_age_days)
            account = result["account_id"].lower()
            if account in seen:
                raise ValueError("duplicate account ID")
            seen.add(account)
            results.append(result)
        except (ValueError, TypeError, AttributeError, OSError) as exc:
            errors.append({"source": str(source), "error": str(exc)})
    # Eligible first, then older accounts; deterministic tie-break by ID.
    results.sort(key=lambda r: (not r["candidate"], -(r["age_days"] or 0), r["account_id"]))
    return {"card_id": card_id, "required_shinedust": cost, "as_of": now.isoformat(),
            "minimum_age_days": minimum_age_days,
            "notice": "Saved estimates only. Confirm trading unlock, card/version, stamina, dust and recipient in-game.",
            "donors": results, "errors": errors}


def main(argv=None):
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--card-id", required=True, help="Exact internal card ID, including version suffix")
    parser.add_argument("--accounts", type=Path, default=root / "Cards" / "accounts")
    parser.add_argument("--saved", type=Path, default=root / "Saved")
    parser.add_argument("--cardmaster", type=Path, default=root.parent / "Helper" / "cardmaster.json")
    parser.add_argument("--dust-cost", type=int, help="Explicit cost when cardmaster is unavailable")
    parser.add_argument("--minimum-age-days", type=float, default=14)
    parser.add_argument("--at", help="ISO timestamp or local YYYYMMDDHHMMSS (default: now). Naive saved timestamps use this offset.")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if (not math.isfinite(args.minimum_age_days) or args.minimum_age_days < 0 or
            (args.dust_cost is not None and args.dust_cost < 0)):
        parser.error("age and cost must be non-negative")
    if not args.accounts.is_dir() or not args.saved.is_dir():
        parser.error("accounts and saved must be existing directories")
    try:
        now = datetime.now().astimezone()
        now = parse_time(args.at, now.tzinfo) if args.at else now
        cost = args.dust_cost
        if cost is None:
            master = read_json(args.cardmaster)
            rarity = master[args.card_id]["Rarity"]
            if rarity not in DUST_COSTS:
                parser.error("no supported trade cost for this rarity")
            cost = DUST_COSTS[rarity]
        result = plan(args.accounts, args.saved, args.card_id, cost, now, args.minimum_age_days)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.error(str(exc))
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(result["notice"])
        print(f"{args.card_id}; required Shinedust: {cost}; minimum age: {args.minimum_age_days:g} days")
        for donor in result["donors"]:
            status = "CANDIDATE" if donor["candidate"] else ", ".join(donor["blockers"])
            print(f"{donor['account_id']} ({donor['account_name']}): {status}; copies={donor['remaining_copies']}; age={donor['age_days']}; dust={donor['shinedust']}")
        for error in result["errors"]:
            print(f"Could not inspect {error['source']}: {error['error']}", file=sys.stderr)
    return 0 if any(d["candidate"] for d in result["donors"]) and not result["errors"] else 1


if __name__ == "__main__":
    sys.exit(main())
