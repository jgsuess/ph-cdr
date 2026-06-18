#!/usr/bin/env bash
# Upload ph-core and ph-ereferral example resources to the ph-cdr FHIR server.
#
# Sources:
#   ph-core:     package/example/*.json from fhir.ph.core package.tgz
#   ph-ereferral: input/examples-json-source/*.json from GitHub
#
# The script also:
#   - Seeds hapi/ucum-fragment.json before uploads (HAPI v8 UCUM regression workaround)
#   - Post-processes Provenance files to fix BCP:13 MIME type codes
#   - Executes transaction/batch Bundles via POST to base URL (not PUT /Bundle/{id})
#
# Usage:
#   ./scripts/upload.sh [BASE_URL] [PH_CORE_VERSION] [PH_EREFERRAL_VERSION]
#
# Examples:
#   ./scripts/upload.sh
#   ./scripts/upload.sh http://localhost:8080/fhir 0.1.1 0.3.1
set -euo pipefail

BASE_URL="${1:-http://localhost:8080/fhir}"
PH_CORE_VERSION="${2:-0.1.1}"
PH_EREFERRAL_VERSION="${3:-0.3.1}"
EREFERRAL_REPO="${EREFERRAL_REPO:-jgsuess/ph-ereferral}"
EREFERRAL_BRANCH="${EREFERRAL_BRANCH:-main}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="fhir-upload-results-${TIMESTAMP}"
mkdir -p "$OUT_DIR/logs" "$OUT_DIR/payloads/ph-core" "$OUT_DIR/payloads/ph-ereferral"

REPORT_MD="$OUT_DIR/upload-report.md"
REPORT_HTML="$OUT_DIR/upload-report.html"
SUMMARY_JSON="$OUT_DIR/summary.json"

PH_CORE_TGZ_URL="https://jgsuess.github.io/ph-core/${PH_CORE_VERSION}/package.tgz"
EREFERRAL_RAW_BASE="https://raw.githubusercontent.com/${EREFERRAL_REPO}/${EREFERRAL_BRANCH}/input/examples-json-source"

PASS=0
FAIL=0
SKIP=0
declare -a RESULTS=()

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { printf '\033[0;36m%s\033[0m\n' "$*" >&2; }
ok()  { printf '\033[0;32m✓ %s\033[0m\n' "$*" >&2; }
err() { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; }

resource_type_from_file() {
  python3 - "$1" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('resourceType',''))
except Exception:
    print('')
PY
}

resource_id_from_file() {
  python3 - "$1" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('id',''))
except Exception:
    print('')
PY
}

bundle_type_from_file() {
  python3 - "$1" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('type',''))
except Exception:
    print('')
PY
}

brief_outcome() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("non-JSON response"); raise SystemExit
rt = d.get('resourceType','')
if rt == 'OperationOutcome':
    issues = d.get('issue', [])
    errors = [i for i in issues if i.get('severity') in ('error','fatal')]
    if errors:
        diag = errors[0].get('diagnostics') or errors[0].get('details',{}).get('text','')
        print(f"{len(errors)} error(s): {diag[:120]}")
    else:
        print("OK (no errors in OperationOutcome)")
elif rt:
    rid = d.get('id','')
    print(f"{rt}/{rid}" if rid else rt)
else:
    print("no resourceType")
PY
}

upload_resource() {
  local label="$1"
  local source="$2"   # "ph-core" or "ph-ereferral"
  local payload="$3"
  local rt
  rt=$(resource_type_from_file "$payload")
  local rid
  rid=$(resource_id_from_file "$payload")

  if [ -z "$rt" ]; then
    err "Skipping $label: could not determine resourceType"
    RESULTS+=("| $label | $source | — | — | ⚠️ skipped (no resourceType) |")
    SKIP=$((SKIP + 1))
    return
  fi

  # ── Transaction / batch Bundle routing ───────────────────────────────────
  # HAPI rejects PUT /Bundle/{id} for transaction and batch Bundles — these
  # are meant to be executed, not stored. POST to the base FHIR endpoint instead.
  # See docs/known-issues.md#d-transaction-bundle-storage
  local endpoint method
  if [ "$rt" = "Bundle" ]; then
    local btype
    btype=$(bundle_type_from_file "$payload")
    if [ "$btype" = "transaction" ] || [ "$btype" = "batch" ]; then
      endpoint="$BASE_URL"
      method="POST"
      rid=""
    elif [ -n "$rid" ]; then
      endpoint="${BASE_URL}/${rt}/${rid}"
      method="PUT"
    else
      endpoint="${BASE_URL}/${rt}"
      method="POST"
    fi
  elif [ -n "$rid" ]; then
    endpoint="${BASE_URL}/${rt}/${rid}"
    method="PUT"
  else
    endpoint="${BASE_URL}/${rt}"
    method="POST"
  fi

  local slug
  slug="$(echo "$label" | tr ' /' '_-')"
  local out_file="$OUT_DIR/logs/${source}-${slug}.json"
  local status_file="$OUT_DIR/logs/${source}-${slug}.status"

  HTTP_STATUS=$(curl -sS -o "$out_file" -w "%{http_code}" \
    -X "$method" "$endpoint" \
    -H "Content-Type: application/fhir+json" \
    -H "Accept: application/fhir+json" \
    --data-binary "@$payload" 2>/dev/null | tee "$status_file" || true)

  HTTP_STATUS=$(cat "$status_file")
  local finding
  finding=$(brief_outcome "$out_file")

  local display_ref="${rt}/${rid}"
  [ -z "$rid" ] && display_ref="$rt"

  if [[ "$HTTP_STATUS" =~ ^2 ]]; then
    ok "$label ($display_ref) → HTTP $HTTP_STATUS"
    RESULTS+=("| \`$label\` | $source | \`$method $display_ref\` | $HTTP_STATUS | ✅ $finding |")
    PASS=$((PASS + 1))
  else
    err "$label ($display_ref) → HTTP $HTTP_STATUS: $finding"
    RESULTS+=("| \`$label\` | $source | \`$method $display_ref\` | $HTTP_STATUS | ❌ $finding |")
    FAIL=$((FAIL + 1))
  fi
}

# ── 1a. Wait for server ───────────────────────────────────────────────────────

log "Checking server at $BASE_URL ..."
for i in $(seq 1 12); do
  if curl -sf "${BASE_URL}/metadata" > /dev/null 2>&1; then
    ok "Server is up"
    break
  fi
  if [ "$i" -eq 12 ]; then
    err "Server not ready after 60s — aborting"
    exit 1
  fi
  log "Waiting for server... ($i/12)"
  sleep 5
done

SERVER_NAME=$(curl -s "${BASE_URL}/metadata" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('software',{}).get('name','?'))" 2>/dev/null || echo "?")
FHIR_VERSION=$(curl -s "${BASE_URL}/metadata" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fhirVersion','?'))" 2>/dev/null || echo "?")

# ── 1b. Seed UCUM fragment ───────────────────────────────────────────────────
# HAPI v8 regression: the classpath UCUM CodeSystem has content=not-present,
# causing all UCUM code validations in FHIR-core ValueSet bindings to fail.
# Seeding a content=fragment CodeSystem overrides the stub so TRM finds the codes.
# See docs/known-issues.md#a-hapi-v8100-ucum-chain-regression--issue-7796

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCUM_FRAGMENT="${SCRIPT_DIR}/../hapi/ucum-fragment.json"

if [ -f "$UCUM_FRAGMENT" ]; then
  log "Seeding UCUM fragment CodeSystem ..."
  UCUM_STATUS=$(curl -sS -o "$OUT_DIR/logs/seed-ucum-fragment.json" -w "%{http_code}" \
    -X PUT "${BASE_URL}/CodeSystem/ucum-fragment" \
    -H "Content-Type: application/fhir+json" \
    -H "Accept: application/fhir+json" \
    --data-binary "@$UCUM_FRAGMENT" 2>/dev/null || echo "000")
  if [[ "$UCUM_STATUS" =~ ^2 ]]; then
    ok "UCUM fragment seeded (HTTP $UCUM_STATUS) — waiting for TRM indexing ..."
    sleep 10
  else
    err "UCUM fragment seed failed (HTTP $UCUM_STATUS) — UCUM-dependent examples may fail"
  fi
else
  err "UCUM fragment not found at $UCUM_FRAGMENT — skipping (UCUM codes may fail)"
fi

# ── 2. Download & extract ph-core examples ───────────────────────────────────

log "Downloading ph-core ${PH_CORE_VERSION} package from ${PH_CORE_TGZ_URL} ..."
PH_CORE_TMP=$(mktemp -d)
trap 'rm -rf "$PH_CORE_TMP"' EXIT
if curl -sL "$PH_CORE_TGZ_URL" | tar -xzf - -C "$PH_CORE_TMP" 2>/dev/null; then
  PH_CORE_EXAMPLE_DIR="$PH_CORE_TMP/package/example"
  if [ -d "$PH_CORE_EXAMPLE_DIR" ]; then
    find "$PH_CORE_EXAMPLE_DIR" -name "*.json" -exec cp {} "$OUT_DIR/payloads/ph-core/" \;
    PH_CORE_COUNT=$(find "$OUT_DIR/payloads/ph-core/" -name "*.json" | wc -l | tr -d ' ')
    ok "Extracted $PH_CORE_COUNT ph-core examples"
  else
    err "No example/ dir found in ph-core package"
    PH_CORE_COUNT=0
  fi
else
  err "Failed to download ph-core package from $PH_CORE_TGZ_URL"
  PH_CORE_COUNT=0
fi

# ── 2b. Post-process ph-core Provenance files ────────────────────────────────
# Fix: ph-core Provenance resources use "targetFormat": "xml" and
# "sigFormat": "xml". These are not valid MIME types in urn:ietf:bcp:13.
# The correct MIME type is "application/xml".
# See docs/known-issues.md#e-provenance-bcp13-mime-type-fix

log "Post-processing Provenance files (BCP:13 MIME type fix) ..."
python3 - "$OUT_DIR/payloads/ph-core" <<'PY'
import os, sys, json

payloads_dir = sys.argv[1]
fixed = 0
for fname in sorted(os.listdir(payloads_dir)):
    if not fname.endswith('.json'):
        continue
    path = os.path.join(payloads_dir, fname)
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        continue
    if data.get('resourceType') != 'Provenance':
        continue
    changed = False
    for sig in data.get('signature', []):
        if sig.get('targetFormat') == 'xml':
            sig['targetFormat'] = 'application/xml'
            changed = True
        if sig.get('sigFormat') == 'xml':
            sig['sigFormat'] = 'application/xml'
            changed = True
    if changed:
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        fixed += 1
        print(f"  patched: {fname}")
if fixed:
    print(f"  {fixed} Provenance file(s) patched (targetFormat/sigFormat: xml → application/xml)")
else:
    print("  no Provenance files needed patching")
PY

# ── 3. Download ph-ereferral examples from GitHub ────────────────────────────

log "Fetching ph-ereferral ${PH_EREFERRAL_VERSION} examples from GitHub (${EREFERRAL_REPO}@${EREFERRAL_BRANCH}) ..."
EREFERRAL_FILES=(
  condition-pregnancy-ex
  encounter-anc-ex
  encounter-registration-ex
  medicationadministration-ifa-ex
  observation-blood-pressure-ex
  observation-chief-complaint-ex
  observation-heart-rate-ex
  observation-oxygen-saturation-ex
  observation-respiratory-rate-ex
  observation-temperature-ex
  observation-weight-ex
  organization-receiving-facility-ex
  organization-sending-facility-ex
  patient-charity-ex
  practitioner-abraham-ex
  practitioner-jane-ex
  practitionerrole-abraham-ex
  practitionerrole-jane-ex
  relatedperson-companion-ex
  servicerequest-lab-orders-ex
  servicerequest-ultrasound-ex
  task-referral-ex
)

EREF_COUNT=0
for name in "${EREFERRAL_FILES[@]}"; do
  url="${EREFERRAL_RAW_BASE}/${name}.json"
  dest="$OUT_DIR/payloads/ph-ereferral/${name}.json"
  if curl -sf "$url" -o "$dest" 2>/dev/null; then
    EREF_COUNT=$((EREF_COUNT + 1))
  else
    err "Could not download $name from $url"
  fi
done
ok "Downloaded $EREF_COUNT ph-ereferral examples"

# ── 4. Upload — ordering matters: independent resources first ─────────────────
# Order: Organization/Location → Practitioner → PractitionerRole →
#        Patient/RelatedPerson → Encounter → ServiceRequest/Task/etc.

log ""
log "═══════════════════════════════════════════════════════════"
log "Uploading ph-core examples (${PH_CORE_COUNT} files)"
log "═══════════════════════════════════════════════════════════"

PH_CORE_UPLOAD_ORDER=(
  Organization Location HealthcareService
  Medication Practitioner
  Patient
  Coverage
  RelatedPerson
  PractitionerRole
  Condition
  Encounter
  AllergyIntolerance Immunization
  ServiceRequest
  Observation-observation-bp Observation-observation-environmental Observation-observation-glucose
  Observation-observation-height Observation-observation-weight
  Observation-observation-potassium Observation-observation-sodium
  Observation-observation-based Observation-observation-vitals Observation-observation-performer
  Observation-observation-derived Observation-observation-lab
  Procedure
  Observation-observation-part
  MedicationRequest
  MedicationAdministration MedicationDispense MedicationStatement
  Claim
  Task Provenance
  Bundle
)

uploaded_phcore=()
for rt in "${PH_CORE_UPLOAD_ORDER[@]}"; do
  while IFS= read -r f; do
    name=$(basename "$f" .json)
    upload_resource "$name" "ph-core" "$f"
    uploaded_phcore+=("$name")
  done < <(find "$OUT_DIR/payloads/ph-core/" -name "${rt}-*.json" -o -name "${rt,,}-*.json" 2>/dev/null | sort)
done

# Upload any remaining ph-core files not caught by ordering
while IFS= read -r f; do
  name=$(basename "$f" .json)
  pattern=" ${name} "
  if [[ ! " ${uploaded_phcore[*]} " =~ $pattern ]]; then
    upload_resource "$name" "ph-core" "$f"
  fi
done < <(find "$OUT_DIR/payloads/ph-core/" -name "*.json" | sort)

log ""
log "═══════════════════════════════════════════════════════════"
log "Uploading ph-ereferral examples (${EREF_COUNT} files)"
log "═══════════════════════════════════════════════════════════"

EREF_UPLOAD_ORDER=(
  organization-sending-facility-ex
  organization-receiving-facility-ex
  practitioner-abraham-ex
  practitioner-jane-ex
  patient-charity-ex
  relatedperson-companion-ex
  practitionerrole-abraham-ex
  practitionerrole-jane-ex
  encounter-registration-ex
  encounter-anc-ex
  condition-pregnancy-ex
  observation-chief-complaint-ex
  observation-blood-pressure-ex
  observation-heart-rate-ex
  observation-oxygen-saturation-ex
  observation-respiratory-rate-ex
  observation-temperature-ex
  observation-weight-ex
  medicationadministration-ifa-ex
  servicerequest-lab-orders-ex
  servicerequest-ultrasound-ex
  task-referral-ex
)

for name in "${EREF_UPLOAD_ORDER[@]}"; do
  f="$OUT_DIR/payloads/ph-ereferral/${name}.json"
  [ -f "$f" ] && upload_resource "$name" "ph-ereferral" "$f"
done

# ── 5. Summary JSON ──────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL + SKIP))
python3 - <<PY > "$SUMMARY_JSON"
import json
print(json.dumps({
  "baseUrl": "$BASE_URL",
  "server": "$SERVER_NAME",
  "fhirVersion": "$FHIR_VERSION",
  "phCoreVersion": "$PH_CORE_VERSION",
  "phEreferralVersion": "$PH_EREFERRAL_VERSION",
  "total": $TOTAL,
  "passed": $PASS,
  "failed": $FAIL,
  "skipped": $SKIP,
}, indent=2))
PY

# ── 6. Markdown report ───────────────────────────────────────────────────────

{
cat <<EOFMD
# FHIR Example Upload Report

Generated: $(date -Iseconds)

## Summary

| Property | Value |
|---|---|
| Server | ${BASE_URL} (${SERVER_NAME}, FHIR ${FHIR_VERSION}) |
| ph-core version | ${PH_CORE_VERSION} |
| ph-ereferral version | ${PH_EREFERRAL_VERSION} (from GitHub raw) |
| Total resources | ${TOTAL} |
| Passed | ✅ ${PASS} |
| Failed | ❌ ${FAIL} |
| Skipped | ⚠️ ${SKIP} |

---

## Upload Results

| Resource | Source | Endpoint | HTTP | Result |
|---|---|---|---|---|
EOFMD
for row in "${RESULTS[@]}"; do echo "$row"; done
cat <<EOFMD2

---

## Notes

- ph-core examples extracted from \`${PH_CORE_TGZ_URL}\`
- ph-ereferral examples downloaded from \`https://github.com/${EREFERRAL_REPO}\` (\`${EREFERRAL_BRANCH}\`)
- Resources uploaded in dependency order (Organizations before Patients, etc.)
- Resources with an \`id\` use \`PUT /{resourceType}/{id}\` (idempotent); others use \`POST\`
- Transaction/batch Bundles are executed via \`POST /\` rather than stored (see docs/known-issues.md)
- Provenance BCP:13 fix applied: \`"xml"\` → \`"application/xml"\` in targetFormat/sigFormat

## Log Files

Raw HAPI responses are in: \`${OUT_DIR}/logs/\`

EOFMD2
} > "$REPORT_MD"

# ── 7. HTML report ───────────────────────────────────────────────────────────

python3 - "$REPORT_MD" "$REPORT_HTML" <<'PY'
import sys, html, re
md_path, html_path = sys.argv[1], sys.argv[2]
text = open(md_path, encoding='utf-8').read()

def inline(s):
    s = html.escape(s)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)
    return s

lines = text.splitlines()
out = []
in_code = False; code_lines = []
in_table = False

def close_table():
    global in_table
    if in_table:
        out.append('</tbody></table>')
        in_table = False

for line in lines:
    if line.startswith('```'):
        if not in_code:
            close_table(); in_code = True; code_lines = []
        else:
            out.append('<pre><code>%s</code></pre>' % html.escape('\n'.join(code_lines)))
            in_code = False
        continue
    if in_code: code_lines.append(line); continue
    if not line.strip(): close_table(); continue
    if line.startswith('# '): close_table(); out.append(f'<h1>{inline(line[2:])}</h1>'); continue
    if line.startswith('## '): close_table(); out.append(f'<h2>{inline(line[3:])}</h2>'); continue
    if line.startswith('### '): close_table(); out.append(f'<h3>{inline(line[4:])}</h3>'); continue
    if line.strip() == '---': close_table(); out.append('<hr>'); continue
    if line.startswith('|') and line.endswith('|'):
        cells = [c.strip() for c in line.strip('|').split('|')]
        if all(set(c) <= set('-: ') for c in cells): continue
        if not in_table:
            out.append('<table><tbody>'); in_table = True; tag = 'th'
        else:
            tag = 'td'
        out.append('<tr>' + ''.join(f'<{tag}>{inline(c)}</{tag}>' for c in cells) + '</tr>')
        continue
    if line.startswith('- '): close_table(); out.append(f'<p>• {inline(line[2:])}</p>'); continue
    close_table(); out.append(f'<p>{inline(line)}</p>')
close_table()

css = '''
body{font-family:Arial,Helvetica,sans-serif;max-width:1100px;margin:30px auto;line-height:1.45;color:#111}
h1{font-size:28px;margin-bottom:24px}h2{font-size:22px;margin-top:30px}h3{font-size:18px;margin-top:24px}
hr{border:0;border-top:2px solid #ddd;margin:24px 0}
table{border-collapse:collapse;width:100%;margin:14px 0}
th,td{border:1px solid #ddd;padding:6px 10px;text-align:left;vertical-align:top}
th{background:#f7f7f7;font-weight:700}
code{background:#f4f4f4;padding:2px 4px;border-radius:3px;font-size:0.9em}
pre{background:#f8f8f8;padding:16px;overflow-x:auto;border-radius:4px;border:1px solid #eee}
pre code{background:transparent;padding:0}
p{margin:6px 0}
@media print{body{margin:.5in;max-width:none}h2,h3{page-break-after:avoid}pre,table{page-break-inside:avoid}}
'''
doc = f'<!doctype html><html><head><meta charset="utf-8"><title>FHIR Upload Report</title><style>{css}</style></head><body>' + '\n'.join(out) + '</body></html>'
open(html_path, 'w', encoding='utf-8').write(doc)
PY

# ── 8. Console summary ───────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════"
echo "Upload complete"
echo "  Total  : $TOTAL"
echo "  Passed : $PASS  ✅"
echo "  Failed : $FAIL  ❌"
echo "  Skipped: $SKIP  ⚠️"
echo ""
echo "Reports:"
echo "  Markdown : $REPORT_MD"
echo "  HTML     : $REPORT_HTML"
echo "  JSON     : $SUMMARY_JSON"
echo "  Logs     : $OUT_DIR/logs/"
echo "════════════════════════════════════════════════════"
