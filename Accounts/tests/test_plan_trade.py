import importlib.util
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("plan_trade", Path(__file__).parents[1] / "plan_trade.py")
planner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(planner)
CARD = "PK_20_000010_00"
OTHER = "PK_20_000020_00"
ACCOUNT = "1234567890abcdef"
NOW = datetime(2026, 10, 18, 12, tzinfo=timezone.utc)


def document():
    return {"deviceAccount": ACCOUNT,
            "metadata": {"createdAt": "20261004120000", "shinedust": {"value": 4000}},
            "pulls": [{"cards": [CARD, CARD]}], "tradedCards": {}, "sharedCards": {}}


class PlanTradeTests(unittest.TestCase):
    def inspect(self, doc, saved=None):
        return planner.inspect_account(doc, Path(ACCOUNT + ".json"),
                                       saved if saved is not None else {ACCOUNT: [Path("login.xml")]},
                                       CARD, 4000, NOW, 14)

    def test_exact_fourteen_day_boundary_and_dust_boundary(self):
        result = self.inspect(document())
        self.assertTrue(result["candidate"])
        self.assertFalse(result["in_game_verified"])
        doc = document()
        doc["metadata"]["createdAt"] = "20261004120001"
        doc["metadata"]["shinedust"]["value"] = 3999
        self.assertEqual(self.inspect(doc)["blockers"], ["too_young", "insufficient_shinedust"])

    def test_counts_versions_pairings_and_prior_transfers(self):
        doc = document()
        doc["pulls"][0]["cards"].append(CARD + "_other_version")
        doc["registeredCards"] = [CARD] * 100
        doc["tradedCards"] = {CARD: {"count": 2}, OTHER: {"count": 1, "pairings": [{"receivedCardId": CARD}]}}
        doc["sharedCards"] = {CARD: {"count": 1}}
        self.assertEqual(planner.available_copies(doc, CARD), 0)
        self.assertIn("no_remaining_copy", self.inspect(doc)["blockers"])

    def test_incoming_legacy_pairing_is_inventory(self):
        doc = document()
        doc["pulls"] = []
        doc["tradedCards"] = {OTHER: {"receivedCardId": CARD}}
        self.assertEqual(planner.available_copies(doc, CARD), 1)

    def test_missing_values_do_not_look_like_zero_cost_eligibility(self):
        doc = document()
        doc["metadata"] = {}
        result = self.inspect(doc, {})
        self.assertEqual(result["blockers"], ["unknown_creation_time", "unknown_shinedust", "missing_saved_login"])

    def test_ambiguous_login_and_account_mismatch_block(self):
        doc = document()
        doc["deviceAccount"] = "0000000000000000"
        result = self.inspect(doc, {doc["deviceAccount"]: [Path("1.xml"), Path("2.xml")]})
        self.assertIn("invalid_or_mismatched_account_id", result["blockers"])
        self.assertIn("ambiguous_saved_login", result["blockers"])

    def test_invalid_card_arrays_are_not_silently_understood(self):
        doc = document()
        doc["pulls"][0]["cards"] = CARD
        with self.assertRaises(ValueError):
            planner.available_copies(doc, CARD)

    def test_scan_is_read_only_and_reports_corrupt_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            accounts, saved = base / "accounts", base / "saved" / "1"
            accounts.mkdir()
            saved.mkdir(parents=True)
            login = saved / (ACCOUNT + ".xml")
            login.write_bytes(b"THIS IS NOT XML AND MUST NEVER BE PARSED")
            account = accounts / (ACCOUNT + ".json")
            account.write_text(json.dumps(document()), encoding="utf-8-sig")
            corrupt = accounts / "broken.json"
            corrupt.write_text("{", encoding="utf-8")
            before = {p: p.read_bytes() for p in base.rglob("*") if p.is_file()}
            result = planner.plan(accounts, saved.parent, CARD, 4000, NOW, 14)
            self.assertTrue(result["donors"][0]["candidate"])
            self.assertEqual(len(result["errors"]), 1)
            self.assertEqual(before, {p: p.read_bytes() for p in before})


if __name__ == "__main__":
    unittest.main()
