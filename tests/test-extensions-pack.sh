#!/usr/bin/env bash
# Verifies that hl7.fhir.uv.extensions.r4 v5.3.0 is loaded and active.
#
# The pack provides R4-compatible StructureDefinitions for HL7 extensions.
# Without it, HAPI falls back to built-in R4 spec definitions which may differ
# in type, context, or bound ValueSet from the pack's R4-transformed versions.
# See docs/known-issues.md section D for background.
#
# Exit 0 = all assertions passed
# Exit 1 = one or more assertions failed

set -euo pipefail

BASE_URL="${FHIR_BASE_URL:-http://localhost:8080/fhir}"
PASS=0
FAIL=0

ok() {
    echo "  PASS  $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL  $1"
    echo "        $2"
    FAIL=$((FAIL + 1))
}

fhir_post() {
    curl -s -o /tmp/ext_test_body.json -w "%{http_code}" \
        -X POST "${BASE_URL}/$1" \
        -H "Content-Type: application/fhir+json" \
        -d "$2"
}

diag() {
    python3 -c "
import json,sys
try:
    d=json.load(open('/tmp/ext_test_body.json'))
    issues=[i.get('diagnostics','') for i in d.get('issue',[]) if i.get('severity')=='error']
    print('; '.join(issues[:2]))
except Exception as e:
    print(str(e))
" 2>/dev/null || echo "(could not parse response)"
}

echo "=== HL7 Extensions Pack (.r4) tests ==="
echo "Server: ${BASE_URL}"
echo ""

# ---------------------------------------------------------------------------
# T1: Verify hl7.fhir.uv.extensions.r4 v5.3.0 is loaded
#     Checks that the device-implantStatus StructureDefinition is present at
#     the pack version (5.3.0), not just the built-in base R4 spec version.
# ---------------------------------------------------------------------------
echo "T1: device-implantStatus StructureDefinition present at version 5.3.0"
VERSION=$(curl -sf "${BASE_URL}/StructureDefinition?url=http://hl7.org/fhir/StructureDefinition/device-implantStatus" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
entries=d.get('entry',[])
if not entries: sys.exit(1)
print(entries[0]['resource'].get('version',''))
" 2>/dev/null || echo "NOT_FOUND")
if [ "$VERSION" = "5.3.0" ]; then
    ok "T1 device-implantStatus StructureDefinition version 5.3.0 present"
else
    fail "T1 device-implantStatus StructureDefinition not at 5.3.0 (got: ${VERSION})" \
        "hl7.fhir.uv.extensions.r4 pack may not be loaded"
fi

# ---------------------------------------------------------------------------
# T2: Device with device-implantStatus using correct type (valueCode) and a
#     valid code value — MUST be accepted (HTTP 201).
#     'functional' is a valid code in the implantStatus ValueSet.
# ---------------------------------------------------------------------------
echo "T2: Device with device-implantStatus valueCode=functional → expect HTTP 201"
STATUS=$(fhir_post "Device" '{
  "resourceType": "Device",
  "status": "active",
  "deviceName": [{"name": "Cochlear Implant", "type": "user-friendly-name"}],
  "extension": [{
    "url": "http://hl7.org/fhir/StructureDefinition/device-implantStatus",
    "valueCode": "functional"
  }]
}')
if [ "$STATUS" = "201" ]; then
    ok "T2 Device with valid extension code accepted (HTTP 201)"
else
    fail "T2 Device with valid extension code rejected (HTTP ${STATUS})" "$(diag)"
fi

# ---------------------------------------------------------------------------
# T3: Device with device-implantStatus using wrong type (valueString) —
#     MUST be rejected with a TYPE error, not silently accepted.
#     Confirms the extension definition IS being enforced.
# ---------------------------------------------------------------------------
echo "T3: Device with device-implantStatus valueString → expect HTTP 422 (type error)"
STATUS=$(fhir_post "Device" '{
  "resourceType": "Device",
  "status": "active",
  "deviceName": [{"name": "Bad Device", "type": "user-friendly-name"}],
  "extension": [{
    "url": "http://hl7.org/fhir/StructureDefinition/device-implantStatus",
    "valueString": "this-is-wrong-type"
  }]
}')
if [ "$STATUS" = "422" ] || [ "$STATUS" = "400" ]; then
    ok "T3 Device with wrong extension type rejected (HTTP ${STATUS})"
else
    fail "T3 Device with invalid extension type was accepted (HTTP ${STATUS})" \
        "expected 422 — extension type validation not enforced"
fi

# ---------------------------------------------------------------------------
# T4: Plain Device with no extensions — MUST still be accepted (regression guard)
# ---------------------------------------------------------------------------
echo "T4: Plain Device (no extensions) → expect HTTP 201"
STATUS=$(fhir_post "Device" '{
  "resourceType": "Device",
  "status": "active",
  "deviceName": [{"name": "Plain Device", "type": "user-friendly-name"}]
}')
if [ "$STATUS" = "201" ]; then
    ok "T4 Plain Device accepted (HTTP 201)"
else
    fail "T4 Plain Device rejected (HTTP ${STATUS})" "regression: basic Device create broken"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
