"""
ph-cdr monitor service — Accept, Observe, Remediate

Event model (hybrid):
  REST-hook Subscription  →  /webhook/patient  (near-real-time missing-profile detection)
  Polling $mdm-query-links every POLL_INTERVAL_SECONDS  (MDM links don't fire Subscriptions)

Endpoints:
  GET  /            live dashboard (SSE-driven)
  GET  /events      SSE stream
  POST /webhook/patient   HAPI REST-hook receiver
  POST /remediate/now     trigger immediate merge pass
"""

import asyncio
import json
import logging
import os
from collections import defaultdict
from contextlib import asynccontextmanager

import httpx
from fastapi import BackgroundTasks, FastAPI, Request, Response
from fastapi.responses import HTMLResponse
from sse_starlette.sse import EventSourceResponse

FHIR_BASE = os.environ.get("FHIR_BASE", "http://fhir:8080/fhir").rstrip("/")
MONITOR_URL = os.environ.get("MONITOR_URL", "http://monitor:8000")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "300"))
# AUTO_MERGE_THRESHOLD: minimum MATCH score to auto-merge. Default "inf" = manual-only.
# Set to e.g. "2.0" to auto-merge strong matches. Never set below 1.0 without review.
_threshold_env = os.environ.get("AUTO_MERGE_THRESHOLD", "inf")
AUTO_MERGE_THRESHOLD = float("inf") if _threshold_env in ("inf", "") else float(_threshold_env)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ── In-memory state (rebuilt from HAPI on every poll cycle) ──────────────────

state: dict = {
    "missing_profile": defaultdict(int),  # facility_ref → count
    "mdm_pending": [],                    # [{source, golden, score}, …]
}
_subscribers: list[asyncio.Queue] = []


async def _push(data: dict) -> None:
    payload = json.dumps(data)
    for q in _subscribers:
        await q.put(payload)


# ── FHIR helpers ─────────────────────────────────────────────────────────────

async def _get(client: httpx.AsyncClient, path: str, **params) -> dict:
    r = await client.get(f"{FHIR_BASE}/{path.lstrip('/')}", params=params, timeout=30.0)
    r.raise_for_status()
    return r.json()


async def _post(client: httpx.AsyncClient, path: str, body: dict) -> dict:
    r = await client.post(
        f"{FHIR_BASE}/{path.lstrip('/')}",
        json=body,
        headers={"Content-Type": "application/fhir+json"},
        timeout=30.0,
    )
    r.raise_for_status()
    return r.json()


# ── Poll: MDM MATCH links ─────────────────────────────────────────────────────

async def poll_mdm_links() -> None:
    try:
        async with httpx.AsyncClient() as client:
            result = await _get(client, "/$mdm-query-links", matchResult="MATCH", _count="200")
        links = []
        for part in result.get("parameter", []):
            if part.get("name") != "link":
                continue
            lp = {p["name"]: p for p in part.get("part", [])}
            source = lp.get("sourceResourceId", {}).get("valueString", "")
            golden = lp.get("goldenResourceId", {}).get("valueString", "")
            score = lp.get("score", {}).get("valueDecimal", 0.0)
            if source:
                links.append({"source": source, "golden": golden, "score": score})
        state["mdm_pending"] = links
        log.info("MDM poll: %d pending links", len(links))
        await _push({"type": "mdm_update", "count": len(links), "links": links[:50]})
    except Exception as exc:
        log.warning("MDM poll failed: %s", exc)


# ── Poll: missing meta.profile ────────────────────────────────────────────────

async def poll_missing_profile() -> None:
    """Reconcile missing-profile counts. Corrects any drift from webhook increments."""
    try:
        async with httpx.AsyncClient() as client:
            global_r = await _get(client, "/Patient", **{"_profile:missing": "true", "_summary": "count"})
            total = global_r.get("total", 0)
            orgs_r = await _get(client, "/Organization", _count="200", _summary="id")
        org_ids = [
            e["resource"]["id"]
            for e in orgs_r.get("entry", [])
            if "resource" in e
        ]
        counts: dict[str, int] = {}
        if org_ids:
            async with httpx.AsyncClient() as client:
                for org_id in org_ids:
                    rc = await _get(client, "/Patient", **{
                        "_profile:missing": "true",
                        "_summary": "count",
                        "organization": f"Organization/{org_id}",
                    })
                    c = rc.get("total", 0)
                    if c:
                        counts[f"Organization/{org_id}"] = c
        else:
            if total:
                counts["(all facilities)"] = total
        state["missing_profile"] = defaultdict(int, counts)
        log.info("Profile poll: %d resources without profile across %d facilities", total, len(counts))
        await _push({"type": "profile_update", "total": total, "by_facility": counts})
    except Exception as exc:
        log.warning("Profile poll failed: %s", exc)


# ── Merge pass ────────────────────────────────────────────────────────────────

async def run_merge_pass() -> None:
    """Merge MATCH links at or above AUTO_MERGE_THRESHOLD. Default = inf (manual-only)."""
    if AUTO_MERGE_THRESHOLD == float("inf"):
        log.info("Auto-merge disabled (AUTO_MERGE_THRESHOLD=inf)")
        return
    to_merge = [l for l in state["mdm_pending"] if l["score"] >= AUTO_MERGE_THRESHOLD]
    if not to_merge:
        log.info("Merge pass: no links above threshold %.2f", AUTO_MERGE_THRESHOLD)
        return
    log.info("Merge pass: merging %d link(s) at score >= %.2f", len(to_merge), AUTO_MERGE_THRESHOLD)
    async with httpx.AsyncClient() as client:
        for link in to_merge:
            try:
                src_id = link["source"].split("/")[-1]
                await _post(client, f"/Patient/{src_id}/$merge", {
                    "resourceType": "Parameters",
                    "parameter": [
                        {"name": "source-patient",
                         "valueReference": {"reference": link["source"]}},
                        {"name": "result-patient",
                         "valueReference": {"reference": link["golden"]}},
                    ],
                })
                log.info("Merged %s → %s (score %.2f)", link["source"], link["golden"], link["score"])
            except Exception as exc:
                log.error("Merge failed for %s: %s", link["source"], exc)
    await poll_mdm_links()


# ── Subscription seeding ──────────────────────────────────────────────────────

async def _seed_subscription() -> None:
    """
    Create a Patient REST-hook Subscription if none exists.
    Retries until HAPI is up (first boot takes ~2 min to load IGs).
    """
    sub_body = {
        "resourceType": "Subscription",
        "status": "requested",
        "reason": "ph-cdr monitor: missing-profile detection via REST-hook",
        "criteria": "Patient?",
        "channel": {
            "type": "rest-hook",
            "endpoint": f"{MONITOR_URL}/webhook/patient",
            "payload": "application/fhir+json",
        },
    }
    for attempt in range(30):
        try:
            async with httpx.AsyncClient() as client:
                existing = await _get(client, "/Subscription",
                                      criteria="Patient?", status="active",
                                      _count="1")
                if existing.get("total", 0) > 0:
                    log.info("Patient Subscription already active — skipping seed")
                    return
                result = await _post(client, "/Subscription", sub_body)
                log.info("Subscription created: %s (status: %s)",
                         result.get("id"), result.get("status"))
                return
        except Exception as exc:
            log.info("Subscription seed attempt %d/30: waiting for HAPI (%s)", attempt + 1, exc)
            await asyncio.sleep(10)
    log.error("Could not seed Subscription after 30 attempts — check HAPI connectivity")


# ── Background polling loop ───────────────────────────────────────────────────

async def _polling_loop() -> None:
    await asyncio.sleep(15)  # brief startup grace period
    while True:
        await asyncio.gather(poll_mdm_links(), poll_missing_profile(), return_exceptions=True)
        await asyncio.sleep(POLL_INTERVAL)


# ── FastAPI app ───────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Start background tasks — they handle HAPI-not-ready gracefully
    asyncio.create_task(_seed_subscription(), name="seed-subscription")
    asyncio.create_task(_polling_loop(), name="polling-loop")
    yield


app = FastAPI(title="ph-cdr monitor", lifespan=lifespan)


# ── Webhook receiver ──────────────────────────────────────────────────────────

@app.api_route("/webhook/patient/{path:path}", methods=["POST", "PUT"])
@app.api_route("/webhook/patient", methods=["POST", "PUT"])
async def webhook_patient(request: Request, path: str = "") -> Response:
    """
    HAPI REST-hook endpoint. Receives full Patient JSON on every Patient write.
    HAPI R4 appends /{ResourceType}/{id} to the endpoint URL and uses PUT —
    so the actual call arrives as PUT /webhook/patient/Patient/{id}.
    Also handles the empty handshake POST on subscription activation.
    """
    body = await request.body()
    if not body:
        return Response(status_code=200)  # handshake ping
    try:
        resource = json.loads(body)
        if resource.get("resourceType") == "Patient":
            has_profile = bool((resource.get("meta") or {}).get("profile"))
            if not has_profile:
                facility = (resource.get("managingOrganization") or {}).get(
                    "reference", "(unknown facility)"
                )
                state["missing_profile"][facility] += 1
                total = sum(state["missing_profile"].values())
                await _push({
                    "type": "profile_update",
                    "total": total,
                    "by_facility": dict(state["missing_profile"]),
                })
    except Exception as exc:
        log.warning("Webhook parse error: %s", exc)
    return Response(status_code=200)


# ── On-demand remediation ─────────────────────────────────────────────────────

@app.post("/remediate/now")
async def remediate_now(background_tasks: BackgroundTasks) -> dict:
    """Trigger an immediate MDM poll + merge pass (honouring AUTO_MERGE_THRESHOLD)."""
    background_tasks.add_task(poll_mdm_links)
    background_tasks.add_task(run_merge_pass)
    return {"status": "triggered"}


# ── SSE stream ────────────────────────────────────────────────────────────────

@app.get("/events")
async def events(request: Request) -> EventSourceResponse:
    q: asyncio.Queue = asyncio.Queue()
    _subscribers.append(q)
    # Send current state immediately on connect
    await q.put(json.dumps({
        "type": "snapshot",
        "by_facility": dict(state["missing_profile"]),
        "mdm_links": state["mdm_pending"][:50],
    }))

    async def generator():
        try:
            while True:
                if await request.is_disconnected():
                    break
                try:
                    data = await asyncio.wait_for(q.get(), timeout=15.0)
                    yield {"data": data}
                except asyncio.TimeoutError:
                    yield {"data": json.dumps({"type": "ping"})}
        finally:
            _subscribers.remove(q)

    return EventSourceResponse(generator())


# ── Dashboard ─────────────────────────────────────────────────────────────────

_DASHBOARD = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>ph-cdr Monitor</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:#F0F4F8;color:#1a2535}
header{background:#1A3A5C;color:#fff;padding:14px 32px;display:flex;align-items:center;gap:12px}
h1{font-size:19px;font-weight:700;flex:1}
#dot{width:9px;height:9px;border-radius:50%;background:#F44336}
#dot.live{background:#4CAF50}
#status{font-size:12px;opacity:.75}
main{max-width:1100px;margin:24px auto;padding:0 20px;display:grid;grid-template-columns:1fr 1fr;gap:18px}
.card{background:#fff;border-radius:10px;box-shadow:0 2px 8px rgba(0,0,0,.08);padding:20px}
h2{font-size:14px;font-weight:700;margin-bottom:12px;color:#1A3A5C;text-transform:uppercase;letter-spacing:.4px}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{padding:8px 10px;text-align:left;border-bottom:1px solid #eee}
th{color:#888;font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.3px}
.badge{padding:2px 8px;border-radius:4px;font-size:11px;font-weight:700}
.badge-warn{background:#FDE8D0;color:#A04000}
.badge-mdm{background:#FEF9E7;color:#B7950B}
.empty{color:#aaa;font-size:13px;text-align:center;padding:20px}
.actions{margin-top:14px}
button{background:#1A3A5C;color:#fff;border:none;border-radius:6px;padding:8px 16px;font-size:13px;cursor:pointer;font-family:inherit}
button:hover{background:#2C5F8A}
</style></head>
<body>
<header>
  <h1>ph-cdr Monitor</h1>
  <div id="dot"></div>
  <span id="status">Connecting…</span>
</header>
<main>
  <div class="card">
    <h2>Missing meta.profile</h2>
    <table><thead><tr><th>Facility</th><th>Count</th></tr></thead>
    <tbody id="pt"></tbody></table>
  </div>
  <div class="card">
    <h2>MDM Pending MATCH links</h2>
    <table><thead><tr><th>Source</th><th>Golden</th><th>Score</th></tr></thead>
    <tbody id="mt"></tbody></table>
    <div class="actions">
      <button onclick="triggerMerge()">Run merge pass now</button>
    </div>
  </div>
</main>
<script>
const es = new EventSource('/events');
es.onopen  = () => { document.getElementById('dot').className='live'; document.getElementById('status').textContent='Live'; };
es.onerror = () => { document.getElementById('dot').className=''; document.getElementById('status').textContent='Reconnecting…'; };

function renderProfile(map) {
  const tb = document.getElementById('pt');
  const rows = Object.entries(map||{}).sort((a,b)=>b[1]-a[1]);
  tb.innerHTML = rows.length
    ? rows.map(([f,c])=>`<tr><td>${f}</td><td><span class="badge badge-warn">${c}</span></td></tr>`).join('')
    : '<tr><td colspan="2" class="empty">None — looking good</td></tr>';
}

function renderMdm(links) {
  const tb = document.getElementById('mt');
  tb.innerHTML = (links||[]).length
    ? links.map(l=>`<tr><td>${l.source}</td><td>${l.golden}</td><td><span class="badge badge-mdm">${(+l.score||0).toFixed(2)}</span></td></tr>`).join('')
    : '<tr><td colspan="3" class="empty">No pending links</td></tr>';
}

es.onmessage = e => {
  const d = JSON.parse(e.data);
  if (d.type==='ping') return;
  if (d.type==='snapshot')       { renderProfile(d.by_facility); renderMdm(d.mdm_links); }
  if (d.type==='profile_update') renderProfile(d.by_facility);
  if (d.type==='mdm_update')     renderMdm(d.links);
};

async function triggerMerge() {
  await fetch('/remediate/now', {method:'POST'});
  document.getElementById('status').textContent = 'Merge pass triggered…';
}
</script>
</body></html>"""


@app.get("/", response_class=HTMLResponse)
async def dashboard() -> str:
    return _DASHBOARD
