"""
E2E tests for the ph-cdr monitor service.

Requires the full docker compose stack to be running:
  docker compose up -d

Run with:
  python3 -m pytest tests/test_monitor_e2e.py -v
"""

import json
import time

import httpx
import pytest

FHIR = "http://localhost:8080/fhir"
MON = "http://localhost:8100"

FHIR_HEADERS = {"Content-Type": "application/fhir+json"}


# ── Helpers ───────────────────────────────────────────────────────────────────

def post_patient(extra: dict = {}) -> dict:
    body = {"resourceType": "Patient", **extra}
    r = httpx.post(f"{FHIR}/Patient", json=body, headers=FHIR_HEADERS, timeout=15)
    r.raise_for_status()
    return r.json()


def monitor_snapshot() -> dict:
    """Read the first SSE snapshot from the monitor."""
    with httpx.stream("GET", f"{MON}/events",
                      headers={"Accept": "text/event-stream"},
                      timeout=10) as r:
        for line in r.iter_lines():
            if line.startswith("data:"):
                return json.loads(line.removeprefix("data:").strip())
    return {}


def wait_for_webhook(initial_total: int, timeout: int = 10) -> int:
    """Poll the monitor snapshot until missing-profile total exceeds initial_total."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        snap = monitor_snapshot()
        total = sum(snap.get("by_facility", {}).values())
        if total > initial_total:
            return total
        time.sleep(0.5)
    return sum(monitor_snapshot().get("by_facility", {}).values())


# ── Infrastructure ────────────────────────────────────────────────────────────

class TestInfrastructure:
    def test_hapi_is_up(self):
        r = httpx.get(f"{FHIR}/metadata", timeout=10)
        assert r.status_code == 200
        assert r.json()["resourceType"] == "CapabilityStatement"

    def test_monitor_is_up(self):
        r = httpx.get(f"{MON}/", timeout=10)
        assert r.status_code == 200
        assert "ph-cdr Monitor" in r.text

    def test_subscription_is_active(self):
        r = httpx.get(f"{FHIR}/Subscription",
                      params={"criteria": "Patient?", "status": "active"},
                      timeout=10)
        assert r.status_code == 200
        data = r.json()
        assert data.get("total", 0) >= 1, (
            "No active Patient Subscription found — monitor may not have seeded it yet"
        )

    def test_sse_delivers_snapshot(self):
        snap = monitor_snapshot()
        assert snap.get("type") in ("snapshot", "profile_update")
        assert "by_facility" in snap


# ── Missing-profile detection ─────────────────────────────────────────────────

class TestMissingProfileDetection:
    def test_patient_without_profile_increments_counter(self):
        before = sum(monitor_snapshot().get("by_facility", {}).values())
        post_patient({"name": [{"family": "E2ENoProfile"}]})
        after = wait_for_webhook(before)
        assert after > before, "Missing-profile counter did not increment after posting Patient without meta.profile"

    def test_patient_with_profile_does_not_increment_counter(self):
        before = sum(monitor_snapshot().get("by_facility", {}).values())
        # Post with any non-empty profile list. If HAPI rejects with 422 (profile not
        # loaded in this instance) the resource is never stored so the webhook can't
        # fire either — counter stays the same either way.
        r = httpx.post(f"{FHIR}/Patient",
                       json={"resourceType": "Patient",
                             "meta": {"profile": ["https://example.org/StructureDefinition/AnyProfile"]},
                             "name": [{"family": "E2EHasProfile"}]},
                       headers=FHIR_HEADERS, timeout=15)
        time.sleep(3)  # give webhook time to arrive if it were going to
        after = sum(monitor_snapshot().get("by_facility", {}).values())
        assert after == before, (
            f"Counter incremented for a Patient that had meta.profile "
            f"(HAPI status={r.status_code}, before={before}, after={after})"
        )

    def test_fhir_profile_missing_search_returns_nonzero(self):
        """Verify HAPI _profile:missing=true search works (guards against bug #4799)."""
        post_patient({"name": [{"family": "E2ESearchVerify"}]})
        r = httpx.get(f"{FHIR}/Patient",
                      params={"_profile:missing": "true", "_summary": "count"},
                      timeout=10)
        assert r.status_code == 200
        assert r.json().get("total", 0) > 0, (
            "_profile:missing=true returned 0 — HAPI bug #4799 may be present on this version"
        )


# ── MDM deduplication ─────────────────────────────────────────────────────────

class TestMDMDeduplication:
    PHILHEALTH_ID = "E2E-PH-99999"

    def test_duplicate_identifier_creates_match_link(self):
        identifier = [{"system": "https://philhealth.gov.ph", "value": self.PHILHEALTH_ID}]
        p1 = post_patient({"identifier": identifier, "name": [{"family": "MDMFirst"}]})
        p2 = post_patient({"identifier": identifier, "name": [{"family": "MDMSecond"}]})
        assert p1["id"] != p2["id"]

        # Poll $mdm-query-links for either resource
        deadline = time.time() + 30
        found = False
        while time.time() < deadline:
            r = httpx.get(f"{FHIR}/$mdm-query-links",
                          params={"matchResult": "MATCH", "_count": "200"},
                          timeout=10)
            if r.status_code == 200:
                params = r.json().get("parameter", [])
                links = [p for p in params if p.get("name") == "link"]
                if links:
                    found = True
                    break
            time.sleep(2)

        assert found, "No POSSIBLE_MATCH links found after posting two Patients with the same PhilHealth ID"

    def test_monitor_mdm_poll_reflects_match_links(self):
        """After the duplicate above, the monitor's MDM poll should show pending links."""
        deadline = time.time() + 60  # poll interval is 300s but primed at startup
        # Trigger an immediate poll via /remediate/now
        httpx.post(f"{MON}/remediate/now", timeout=10)
        while time.time() < deadline:
            snap = monitor_snapshot()
            if len(snap.get("mdm_links", [])) > 0:
                return
            time.sleep(2)
        pytest.fail("Monitor MDM links still empty after triggering remediate/now")


# ── Remediation endpoint ──────────────────────────────────────────────────────

class TestRemediationEndpoint:
    def test_remediate_now_returns_triggered(self):
        r = httpx.post(f"{MON}/remediate/now", timeout=10)
        assert r.status_code == 200
        assert r.json() == {"status": "triggered"}
