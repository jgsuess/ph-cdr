# Adding a New Philippine IG

This guide describes how to register a new Philippine FHIR Implementation Guide in the ph-cdr stack.

## Prerequisites

Your IG must be published as a FHIR npm package (`.tgz`) at a stable URL. The conventional pattern for Philippine IGs hosted on GitHub Pages is:

```
https://<github-username>.github.io/<repo-name>/<version>/package.tgz
```

For example:
- `https://jgsuess.github.io/ph-core/0.1.1/package.tgz`
- `https://jgsuess.github.io/ph-ereferral/0.3.1/package.tgz`

The package must contain `package/package.json` with `name` and `version` fields matching what you register in `hapi/application.yaml`.

---

## Step 1: Register the IG in hapi/application.yaml

Open `hapi/application.yaml` and add a new entry under `hapi.fhir.implementationguides`:

```yaml
hapi:
  fhir:
    implementationguides:
      # ... existing entries ...

      ph_newmodule:                               # arbitrary key — must be unique, no spaces
        name: fhir.ph.newmodule                   # must match package/package.json "name"
        version: "${PH_NEWMODULE_VERSION:0.1.0}"  # Spring property: env-var with default
        reloadExisting: false
        installMode: STORE_AND_INSTALL
        fetchDependencies: true
        packageUrl: "https://<owner>.github.io/<repo>/${PH_NEWMODULE_VERSION:0.1.0}/package.tgz"
        dependencyExcludes:
          - "hl7.fhir.uv.extensions"   # always exclude — bundled in HAPI image
          - "hl7.terminology"           # always exclude — bundled in HAPI image
          - "fhir.ph.core"              # add if your IG depends on ph-core (already loaded above)
          - "fhir.ph.ereferral"         # add if your IG depends on ph-ereferral (already loaded)
```

**Key field notes:**

- `name` must exactly match the `"name"` field in the IG's `package/package.json`. A mismatch causes a silent no-op or an install error during boot.
- The version placeholder `${PH_NEWMODULE_VERSION:0.1.0}` must appear in **both** `version:` and `packageUrl:` and the values must agree.
- Always exclude `hl7.fhir.uv.extensions` and `hl7.terminology` — these are already inside the HAPI Docker image and re-fetching causes version conflicts and ~2 min extra boot time.
- Exclude any Philippine IGs you have already loaded above your new entry to avoid duplicate installs.

---

## Step 2: Pass the version env var to the container

Open `docker-compose.yml` and add the new env var to the `fhir` service's `environment` block:

```yaml
services:
  fhir:
    environment:
      PH_CORE_VERSION: "${PH_CORE_VERSION:-0.1.1}"
      PH_EREFERRAL_VERSION: "${PH_EREFERRAL_VERSION:-0.3.1}"
      PH_NEWMODULE_VERSION: "${PH_NEWMODULE_VERSION:-0.1.0}"   # add this line
```

Open `.env.example` and document the new variable:

```dotenv
# Philippine New Module IG version
# PH_NEWMODULE_VERSION=0.1.0
```

To pin a specific version, add it to your local `.env` (not committed):

```dotenv
PH_NEWMODULE_VERSION=0.1.0
```

---

## Step 3: Add example uploads to scripts/upload.sh

Choose the download pattern that matches how your IG stores examples.

### Option A — package.tgz (examples in `package/example/`)

This is the same pattern as ph-core. Add after the ph-core download section:

```bash
PH_NEWMODULE_VERSION="${4:-0.1.0}"   # 4th positional argument
PH_NEWMODULE_TGZ_URL="https://<owner>.github.io/<repo>/${PH_NEWMODULE_VERSION}/package.tgz"

log "Downloading ph-newmodule ${PH_NEWMODULE_VERSION} package ..."
PH_NEWMODULE_TMP=$(mktemp -d)
# Update the trap to clean up the new temp dir:
# trap 'rm -rf "$PH_CORE_TMP" "$PH_NEWMODULE_TMP"' EXIT
if curl -sL "$PH_NEWMODULE_TGZ_URL" | tar -xzf - -C "$PH_NEWMODULE_TMP" 2>/dev/null; then
  PH_NEWMODULE_EXAMPLE_DIR="$PH_NEWMODULE_TMP/package/example"
  if [ -d "$PH_NEWMODULE_EXAMPLE_DIR" ]; then
    mkdir -p "$OUT_DIR/payloads/ph-newmodule"
    find "$PH_NEWMODULE_EXAMPLE_DIR" -name "*.json" -exec cp {} "$OUT_DIR/payloads/ph-newmodule/" \;
    PH_NEWMODULE_COUNT=$(find "$OUT_DIR/payloads/ph-newmodule/" -name "*.json" | wc -l | tr -d ' ')
    ok "Extracted $PH_NEWMODULE_COUNT ph-newmodule examples"
  fi
fi
```

### Option B — GitHub raw files (examples as individual files in a repo)

This is the same pattern as ph-ereferral. Add after the ph-ereferral download section:

```bash
NEWMODULE_REPO="${NEWMODULE_REPO:-<owner>/ph-newmodule}"
NEWMODULE_BRANCH="${NEWMODULE_BRANCH:-main}"
NEWMODULE_RAW_BASE="https://raw.githubusercontent.com/${NEWMODULE_REPO}/${NEWMODULE_BRANCH}/input/examples-json-source"

NEWMODULE_FILES=(
  patient-example-01
  observation-example-01
  # ... list all example file stems (without .json)
)

mkdir -p "$OUT_DIR/payloads/ph-newmodule"
NEWMODULE_COUNT=0
for name in "${NEWMODULE_FILES[@]}"; do
  url="${NEWMODULE_RAW_BASE}/${name}.json"
  dest="$OUT_DIR/payloads/ph-newmodule/${name}.json"
  if curl -sf "$url" -o "$dest" 2>/dev/null; then
    NEWMODULE_COUNT=$((NEWMODULE_COUNT + 1))
  else
    err "Could not download $name from $url"
  fi
done
ok "Downloaded $NEWMODULE_COUNT ph-newmodule examples"
```

### Add an upload section

Add an upload section after the ph-ereferral uploads. Order resources by dependency (Organizations, Practitioners, and Patients before anything that references them):

```bash
NEWMODULE_UPLOAD_ORDER=(
  organization-example-01
  practitioner-example-01
  patient-example-01
  encounter-example-01
  observation-example-01
)

log ""
log "═══════════════════════════════════════════════════════════"
log "Uploading ph-newmodule examples"
log "═══════════════════════════════════════════════════════════"

for name in "${NEWMODULE_UPLOAD_ORDER[@]}"; do
  f="$OUT_DIR/payloads/ph-newmodule/${name}.json"
  [ -f "$f" ] && upload_resource "$name" "ph-newmodule" "$f"
done
```

---

## Step 4: Extend the UCUM fragment if needed

If your IG introduces Observations or Medications that use UCUM unit codes not already in `hapi/ucum-fragment.json`, add them to the `concept` array:

```json
{"code": "mg/kg", "display": "Milligram per kilogram"}
```

See [Configuration Reference — ucum-fragment.json](configuration.md#hapiucum-fragmentjson) for details and a full list of currently included codes.

---

## Step 5: Restart the stack

```bash
docker compose down
docker compose up -d
docker compose logs -f fhir   # watch for IG loading
```

HAPI prints `Installing package fhir.ph.newmodule#0.1.0` during boot. First boot with a new IG takes longer; subsequent restarts skip the download because `reloadExisting: false`.

After boot, run the upload script:

```bash
bash scripts/upload.sh
```

---

## Package URL convention

Philippine IGs in this stack use the GitHub Pages convention:

```
https://<github-username>.github.io/<repo-name>/<version>/package.tgz
```

This is generated automatically when the IG is built with the FHIR IG Publisher and CI workflows that publish to the `gh-pages` branch. The `<version>` path segment must exactly match the version in `package/package.json` and `ImplementationGuide.version`.

If an IG is published to the official FHIR registry (`packages.fhir.org`), you can omit `packageUrl` and HAPI will fetch from the registry automatically. The explicit `packageUrl` is used here because Philippine IGs are not yet on the central registry.

## Notes on dependencyExcludes

The following packages must always be excluded because they ship inside the HAPI Docker image:

| Package | Why excluded |
|---|---|
| `hl7.fhir.uv.extensions` | Bundled in the HAPI image; re-fetching causes version conflicts |
| `hl7.terminology` | Same — contains SNOMED, LOINC, v3 stubs; already present |

Exclude any Philippine IG that you have already loaded earlier in the `implementationguides` list. If ph-core and ph-ereferral are already registered and your new IG lists them as dependencies, add both to `dependencyExcludes` for the new entry.
