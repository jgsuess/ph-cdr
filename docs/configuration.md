# Configuration Reference

This document describes every configurable setting in the ph-cdr stack. Files covered:

- [`hapi/application.yaml`](#happlicationyaml) — HAPI FHIR server settings
- [`docker-compose.yml`](#docker-composeyml) — container orchestration
- [`hapi/mdm-rules.json`](#hapimdm-rulesjson) — patient deduplication rules
- [`hapi/ucum-fragment.json`](#hapiucum-fragmentjson) — UCUM code system fragment

---

## hapi/application.yaml

Official HAPI configuration reference: https://hapifhir.io/hapi-fhir/docs/server_jpa/configuration.html

### Spring DataSource

```yaml
spring:
  datasource:
    url: 'jdbc:postgresql://db:5432/hapi'
    username: admin
    password: admin
    driverClassName: org.postgresql.Driver
```

| Setting | Value | Notes |
|---|---|---|
| `url` | `jdbc:postgresql://db:5432/hapi` | `db` resolves to the PostgreSQL container hostname defined in `docker-compose.yml`. Change to an external host/port for a managed database (e.g. RDS, Cloud SQL). |
| `username` / `password` | `admin` / `admin` | Development defaults. For production, inject via Docker secrets or environment variables referenced with `${DB_PASSWORD}` — do not commit real credentials. |
| `driverClassName` | `org.postgresql.Driver` | Standard PostgreSQL JDBC driver bundled in the HAPI image. Do not change unless switching databases. |

### Spring JPA / Hibernate

```yaml
  jpa:
    properties:
      hibernate.dialect: ca.uhn.fhir.jpa.model.dialect.HapiFhirPostgresDialect
      hibernate.search.enabled: false
```

| Setting | Value | Notes |
|---|---|---|
| `hibernate.dialect` | `HapiFhirPostgresDialect` | HAPI's PostgreSQL-specific dialect. Required for correct schema generation and JSON column handling. Do not swap for a generic PostgreSQL dialect — HAPI relies on dialect-specific SQL extensions. |
| `hibernate.search.enabled` | `false` | Disables Hibernate Search (Lucene/Elasticsearch full-text indexing). HAPI uses its own SQL-based FHIR search; Hibernate Search is only needed for `_text` or `_content` search parameters, which are not used here. Enabling it requires configuring a backend and increases memory by ~500 MB. |

### FHIR Version

```yaml
hapi:
  fhir:
    fhir_version: R4
```

Sets the FHIR version for all endpoints and package loading. The Philippine Core and eReferral IGs are R4. Changing this to R4B or R5 will break IG loading because the package URLs serve R4 content and the package manifests declare R4.

### Terminology Deferred Indexing

```yaml
    defer_indexing_for_codesystems_of_size: 100000
```

When HAPI loads an IG package, it indexes each CodeSystem's concepts into its internal term table (TRM_CONCEPT). By default, code systems with more than 100 concepts are deferred to a background job. This means large code systems like v3-Race (~900 concepts), v3-ActCode (500+), and v3-RouteOfAdministration (600+) may not be fully indexed until several seconds after boot.

Setting this to `100000` forces all code systems to be indexed synchronously during the package load, regardless of size. This makes first boot slower (by ~30–60 seconds) but eliminates the race condition where valid codes return "unknown" during the startup window.

**When to lower this value**: only in development when you need fast restarts and don't need large v3 code systems to validate immediately.

### Validation

```yaml
    validation:
      requests_enabled: true
      responses_enabled: false
```

| Setting | Effect |
|---|---|
| `requests_enabled: true` | HAPI validates every incoming create/update against loaded profiles. Resources that do not conform are rejected with HTTP 422 and an `OperationOutcome` listing violations. |
| `responses_enabled: false` | HAPI does not validate outgoing read responses. Enabling this would validate every `GET` response — expensive and rarely useful in production. Validation errors in reads typically indicate a data migration issue, better caught during ingest. |

**Important limitation**: HAPI only enforces profiles whose StructureDefinition has `"status": "active"`. Profiles with `"status": "draft"` are loaded and stored but not enforced on writes. See [Known Issues](known-issues.md#c-profile-validation-inactive-for-draft-status-igs).

### MDM (Master Data Management)

```yaml
    mdm_enabled: true
    mdm_rules_json_location: "mdm-rules.json"
```

Enables HAPI's built-in MDM engine for automatic patient deduplication. When a new Patient is written, HAPI scores it against existing Patients using the rules in `mdm-rules.json`. Matches create or update a Golden Patient record that links duplicates.

`mdm_rules_json_location` is resolved relative to the HAPI config directory (`/app/config/`). The file is mounted into the container via Docker Configs (see [docker-compose.yml](#docker-composeyml)).

Setting `mdm_enabled: false` disables deduplication entirely. The `mdm_rules_json_location` has no effect when MDM is disabled.

### External References

```yaml
    allow_external_references: true
```

Allows resource fields to reference URLs outside the local HAPI server — for example, `"reference": "https://fhir.philhealth.gov.ph/Patient/123"`. Without this, HAPI rejects any reference not resolvable on the local server with HTTP 422. Philippine IGs routinely use references to national registry resources.

### Remote Terminology Services

```yaml
    remote_terminology_service:
      loinc:
        system: "http://loinc.org"
        url: "https://tx.fhirlab.net/fhir"
      snomed:
        system: "http://snomed.info/sct"
        url: "https://tx.fhirlab.net/fhir"
      ucum:
        system: "http://unitsofmeasure.org"
        url: "https://tx.fhir.org/r4"
```

When HAPI cannot resolve a code locally (the code is not in any loaded package's CodeSystem or ValueSet), it forwards the validation call to the configured remote server.

| Code system | Remote server | Notes |
|---|---|---|
| LOINC (`http://loinc.org`) | tx.fhirlab.net | CSIRO's public Ontoserver instance. Returns `true` for valid LOINC codes. |
| SNOMED CT (`http://snomed.info/sct`) | tx.fhirlab.net | Same instance. Supports the International Edition; for Philippine National Release, point to an NRC-licensed server. |
| UCUM (`http://unitsofmeasure.org`) | tx.fhir.org/r4 | HL7 reference terminology server. UCUM has a specific chain-ordering workaround; see [hapi/ucum-fragment.json](#hapiucum-fragmentjson) and [Known Issues](known-issues.md#a-hapi-v8100-ucum-chain-regression--issue-7796). Note: tx.fhirlab.net does *not* support UCUM validation, which is why it is routed to tx.fhir.org. |

**Configuration keys** (`loinc`, `snomed`, `ucum`) are arbitrary labels. HAPI matches requests by the `system` URI, not the key name. You can rename them freely.

**Offline environments**: replace the URLs with an internal terminology server. For SNOMED in particular, [Ontoserver](https://ontoserver.csiro.au) can be deployed locally. For LOINC offline, HAPI's bundled `hl7.terminology` package contains LOINC concepts for common codes.

**Important**: the remote services require outbound internet access from the HAPI container. If network egress is blocked, remove the `remote_terminology_service` block; codes not in loaded packages will generate validation warnings rather than hard errors.

### Implementation Guides

```yaml
    implementationguides:
      ph_core:
        name: fhir.ph.core
        version: "${PH_CORE_VERSION:0.1.1}"
        reloadExisting: false
        installMode: STORE_AND_INSTALL
        fetchDependencies: true
        packageUrl: "https://jgsuess.github.io/ph-core/${PH_CORE_VERSION:0.1.1}/package.tgz"
        dependencyExcludes:
          - "hl7.fhir.uv.extensions"
          - "hl7.terminology"
```

Each entry causes HAPI to download, install, and register the named FHIR npm package at boot time.

| Field | Meaning |
|---|---|
| `name` | NPM package name. Must exactly match the `"name"` field in the package's `package/package.json`. HAPI uses this as the registry key; a mismatch causes a silent no-op or install error. |
| `version` | Package version. Uses Spring `${ENV_VAR:default}` syntax: `PH_CORE_VERSION` env var overrides, falls back to the literal value after `:`. Set in `docker-compose.yml` environment block and `.env`. |
| `reloadExisting: false` | If the exact `name@version` is already in the DB, skip re-download. Set to `true` temporarily when debugging a broken install. In normal operation, leave `false` — re-installing adds 1–2 min per package per boot. |
| `installMode: STORE_AND_INSTALL` | Download the package, store it in the DB, *and* install its conformance resources (StructureDefinitions, ValueSets, CodeSystems) as searchable FHIR resources. `STORE_ONLY` would store the package without making resources queryable. |
| `fetchDependencies: true` | HAPI automatically fetches packages declared as dependencies in `package/package.json`. Combined with `dependencyExcludes` to skip large packages already bundled in the HAPI image. |
| `packageUrl` | Direct `.tgz` URL. HAPI downloads from here instead of the npm registry. The GitHub Pages pattern (`https://<owner>.github.io/<repo>/<version>/package.tgz`) is the convention for Philippine IGs not yet on the central FHIR registry. |
| `dependencyExcludes` | Package names HAPI skips when resolving transitive dependencies. `hl7.fhir.uv.extensions` and `hl7.terminology` are already inside the HAPI Docker image — re-fetching them wastes time and risks version conflicts. `fhir.ph.core` is excluded from `ph_ereferral`'s dependencies because it is loaded in the entry above. |

To add a new IG, see [Adding IGs](adding-igs.md).

---

## docker-compose.yml

### fhir service

```yaml
fhir:
  container_name: ph-cdr-hapi
  image: "hapiproject/hapi:v8.10.0-1"
  ports:
    - "8080:8080"
  dns:
    - 8.8.8.8
    - 8.8.4.4
```

**Image**: `hapiproject/hapi:v8.10.0-1` — HAPI FHIR JPA server. The `-1` suffix is a Docker Hub build tag for HAPI v8.10.0. Never use `latest`; pin to a specific tag for reproducibility. When upgrading, always run `docker compose down -v` first to wipe the DB schema (HAPI does not auto-migrate between major versions).

**Ports**: `8080:8080` exposes HAPI on host port 8080. Change the left-hand value to use a different host port (e.g. `8090:8080`).

**DNS override**: Explicitly sets `8.8.8.8` and `8.8.4.4` (Google Public DNS) for the HAPI container. Required on Ubuntu hosts using `systemd-resolved`, which configures the host's DNS to `127.0.0.53` — a loopback address that Docker containers cannot reach. Without this, HAPI cannot download IG packages or call remote terminology services. See [Known Issues](known-issues.md#b-dns-on-systemd-resolved-ubuntu-hosts).

**When to remove `dns:`**: Docker Desktop on macOS/Windows, RHEL/CentOS with NetworkManager, or any Linux host where `/etc/resolv.conf` does not point to a loopback address. The block is harmless if left in on non-Ubuntu hosts.

### Configs mechanism

```yaml
configs:
  hapi-application:
    file: hapi/application.yaml
  hapi-mdm-rules:
    file: hapi/mdm-rules.json
```

Docker Configs mount files into containers without baking them into the image. This is the Docker Swarm config mechanism, but it works with Compose as well. Config sources are read from the host filesystem at compose runtime and mounted at the paths specified in the service's `configs:` block:

| Config | Container path |
|---|---|
| `hapi-application` | `/app/config/application.yaml` |
| `hapi-mdm-rules` | `/app/config/mdm-rules.json` |

HAPI reads `application.yaml` from `/app/config/` by convention (Spring Boot external config directory). The `mdm-rules.json` path is resolved by the `mdm_rules_json_location` setting in `application.yaml`.

**To change configuration**: edit the source file, then `docker compose down && docker compose up -d`. Docker Configs are not hot-reloaded while the container is running.

### db service

```yaml
db:
  image: "postgres:17.2-bookworm"
  restart: always
  environment:
    POSTGRES_PASSWORD: admin
    POSTGRES_USER: admin
    POSTGRES_DB: hapi
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U admin -d hapi"]
    interval: 5s
    timeout: 5s
    retries: 10
  volumes:
    - hapi.postgres.data:/var/lib/postgresql/data
```

**Image**: `postgres:17.2-bookworm` — PostgreSQL 17 on Debian Bookworm. Pinned to a specific patch release for reproducibility.

**restart: always**: PostgreSQL restarts automatically after Docker daemon restart or crash. Essential for persistent data — without this, a host reboot would leave the DB stopped.

**healthcheck**: `pg_isready` polls the TCP port and confirms PostgreSQL is accepting connections. The `fhir` service has `depends_on: db: condition: service_healthy`, so HAPI does not start until this check passes. Without the healthcheck, HAPI would try to connect to PostgreSQL while it is still initializing and crash.

**Credentials**: `admin/admin` are hardcoded development defaults. For production, inject via env files or Docker secrets. The username and password must match `spring.datasource.username` and `spring.datasource.password` in `application.yaml`.

**Volume**: `hapi.postgres.data` is a named Docker volume that persists database state. It survives `docker compose down` and container recreations. To destroy all data: `docker compose down -v`. This is required when upgrading HAPI across major versions because the DB schema changes incompatibly.

---

## hapi/mdm-rules.json

HAPI MDM documentation: https://hapifhir.io/hapi-fhir/docs/mdm/mdm-rules.html

### Overview

MDM (Master Data Management) creates a Golden Patient record that links duplicate Patient resources. When a new Patient is written, HAPI scores it against existing Patients using the rules below. A high-confidence MATCH merges the patient into the existing Golden Patient automatically; a POSSIBLE_MATCH creates a pending link for human review.

### EID Systems (Enterprise Identifiers)

```json
"eidSystems": [
  "https://philsys.gov.ph/identifier/psn",
  "https://philhealth.gov.ph/identifier/member-id"
]
```

Enterprise Identifiers are authoritative, globally unique patient identifiers. When two Patient resources share the same EID value under the same system, HAPI automatically declares them a MATCH without consulting demographic rules.

| EID | Issuing Authority | Identifier |
|---|---|---|
| `https://philsys.gov.ph/identifier/psn` | Philippine Statistics Authority | PhilSys Number (PSN) — national digital ID |
| `https://philhealth.gov.ph/identifier/member-id` | PhilHealth | PhilHealth member ID |

If neither patient has a PhilSys or PhilHealth identifier, HAPI falls through to demographic matching below.

### Matching Algorithm

```json
"algorithm": "SIMILARITY"
```

`SIMILARITY` computes a weighted score across all match fields and applies the `matchResultMap` to the combined result. This is more nuanced than `RULE_BASED` (which requires exact matches on a minimum number of fields) and better handles the common Philippine scenario of name romanisation inconsistency ("Jose" vs "Joseph", "De Leon" vs "Dela Leon").

### Match Fields

| Field | FHIR path | Matcher | Behaviour |
|---|---|---|---|
| `birthdate` | `Patient.birthDate` | `DATE` | Exact calendar date comparison. Birthdate mismatch is a strong signal of different persons. |
| `given` | `Patient.name.given` | `STRING` (fuzzy) | Normalised, accent-stripped string similarity. Catches "Maria" vs "Marie", "Juan" vs "Juanito". |
| `family` | `Patient.name.family` | `STRING` (fuzzy) | Same as given. Catches "De Leon" vs "deLeon", "Garcia" vs "Garsia". |
| `gender` | `Patient.gender` | `STRING` (exact) | Administrative gender must match exactly. |

### Candidate Search Parameters

```json
"candidateSearchParams": [
  {"resourceType": "Patient", "searchParam": "birthdate"},
  {"resourceType": "Patient", "searchParam": "family"}
]
```

Before running similarity scoring, HAPI narrows the candidate pool using these indexed search parameters. Only Patients sharing the same `birthdate` **or** `family` name are scored against an incoming Patient. Without pre-filtering, every new Patient would be scored against every existing Patient — prohibitively slow at scale.

For better performance with large patient volumes, add `given` as a third candidate parameter. Note that each additional parameter increases the candidate set size.

### matchResultMap

```json
"matchResultMap": {
  "given-exact,family-exact,birthdate-exact,gender-exact": "MATCH",
  "given-similar,family-similar,birthdate-exact": "POSSIBLE_MATCH",
  "given-exact,family-exact,birthdate-exact": "MATCH"
}
```

Maps combinations of per-field outcomes to overall MDM decisions. Field outcomes are either `exact` (above a threshold) or `similar` (below exact but above minimum similarity).

| Rule | Outcome | Rationale |
|---|---|---|
| All four fields exact | `MATCH` | High-confidence automatic merge. |
| Similar given + similar family + exact birthdate | `POSSIBLE_MATCH` | Likely the same person with name entry variation — requires human confirmation. |
| Exact given + exact family + exact birthdate (gender may differ) | `MATCH` | Handles gender correction (administrative error) or transgender patients where name/DOB match definitively. |

`MATCH` → patient is automatically merged into an existing Golden Patient (or a new Golden Patient is created).
`POSSIBLE_MATCH` → a candidate link is created, visible via the MDM API at `Patient/$mdm-query-links`. A human must confirm or reject it.

---

## hapi/ucum-fragment.json

### Why this file exists

HAPI FHIR v8 introduced a regression (upstream issue [#7796](https://github.com/hapifhir/hapi-fhir/issues/7796)) where the classpath UCUM CodeSystem stub has `"content": "not-present"`. HAPI's TRM layer (TermReadSvcImpl) intercepts UCUM code validations for FHIR-core ValueSet bindings — including:

- `http://hl7.org/fhir/ValueSet/ucum-vitals-common` used by the `bp` (blood pressure) profile → rejects `mm[Hg]`
- `http://hl7.org/fhir/ValueSet/units-of-time` used by `Timing.repeat.periodUnit` → rejects `d` (day), `h` (hour), etc.

This causes false validation failures for Observations, MedicationRequests, and other resources that use UCUM units.

**The fix**: uploading a `content: fragment` CodeSystem for `http://unitsofmeasure.org` to the HAPI database makes TRM use the stored resource instead of the classpath stub. TRM finds the listed codes and returns them as valid. This is uploaded by `scripts/upload.sh` as step 1b (after server ready, before example uploads).

See [Known Issues](known-issues.md#a-hapi-v8100-ucum-chain-regression--issue-7796) for the full technical explanation.

### Fragment contents

The fragment lists all UCUM codes used by the ph-core and ph-ereferral example resources:

| Code | Unit | Used by |
|---|---|---|
| `mm[Hg]` | Millimetre of mercury | Blood pressure observations |
| `d` | Day | Medication timing (periodUnit) |
| `%` | Percent | Oxygen saturation |
| `Cel` | Degree Celsius | Body temperature |
| `kg` | Kilogram | Body weight |
| `kg/m2` | kg per m² | BMI |
| `cm` | Centimetre | Body height |
| `mg` | Milligram | Medication doses |
| `mg/dL` | mg per decilitre | Lab values (glucose, etc.) |
| `/min` | Per minute | Heart rate, respiratory rate |
| `mmol/L` | Millimole per litre | Lab values (electrolytes, etc.) |
| `{tbl}` | Tablet | Oral medication doses |
| `mL` | Millilitre | Liquid volumes |
| `L` | Litre | Fluid volumes |
| `g` | Gram | Drug masses |
| `h` | Hour | Timing |
| `wk` | Week | Timing |
| `mo` | Month | Timing |
| `a` | Year | Timing |
| `min` | Minute | Timing |
| `s` | Second | Timing |
| `1` | Dimensionless | Ratios, counts |

### How to extend it

If you add an IG that uses UCUM codes not in this list, add them to the `concept` array:

```json
{"code": "mg/kg", "display": "Milligram per kilogram"}
```

The `code` must be a valid UCUM expression. The `display` is informational only and does not affect validation. After editing, re-run `scripts/upload.sh` or PUT the file manually:

```bash
curl -X PUT http://localhost:8080/fhir/CodeSystem/ucum-fragment \
  -H "Content-Type: application/fhir+json" \
  -d @hapi/ucum-fragment.json
```

### Content semantics and fallthrough

`"content": "fragment"` declares that this CodeSystem listing is partial. Per FHIR R4 semantics (http://hl7.org/fhir/codesystem-definitions.html#CodeSystem.content), a `fragment` CodeSystem does not assert that codes absent from the listing are invalid — it only asserts that listed codes *are* valid. HAPI should fall through to the remote UCUM terminology service (`tx.fhir.org/r4`) for any code not in the fragment, where it will be validated algorithmically.

### Persistence

This resource is stored in PostgreSQL via `PUT /CodeSystem/ucum-fragment`. It persists across container restarts (the PostgreSQL volume is preserved by `docker compose down`). If you wipe the database (`docker compose down -v`), re-run `scripts/upload.sh` before uploading any resources that use UCUM codes.
