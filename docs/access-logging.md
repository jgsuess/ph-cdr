# Access Logging

ph-cdr logs every inbound FHIR request for statistical accounting and governance purposes. This page describes the log format, available fields, how to consume the log, and how to customise the user-facing notice.

---

## How it works

HAPI's built-in `LoggingInterceptor` intercepts every request and emits one record per request to an SLF4J logger named `fhirtest.access`. A Logback configuration (`hapi/logback-spring.xml`) routes that logger to stdout as **one JSON object per line** using Logback's built-in `JsonEncoder` (no extra dependency — `logback-classic` is bundled in the HAPI image).

This is entirely config-driven — no custom Java code is involved. The configuration follows the akkadakka pattern:

| File | Mounted at | Purpose |
|------|-----------|---------|
| `hapi/application.yaml` | `/app/config/application.yaml` | Logger name, format string, `logging.config` pointer |
| `hapi/logback-spring.xml` | `/app/config/logback-spring.xml` | Routes `fhirtest.access` to JSON stdout appender |
| `hapi/custom/about.html` | `/app/config/custom/about.html` | Logging notice shown in HAPI web UI |

### Docker Compose wiring

`docker-compose.yml` wires the logging config into the container via the `configs:` top-level block and the `fhir.configs:` service entries:

```yaml
configs:
  hapi-logback:
    file: hapi/logback-spring.xml   # ← source on the Docker host

services:
  fhir:
    configs:
      - source: hapi-logback
        target: /app/config/logback-spring.xml   # ← where HAPI reads it
```

`application.yaml` tells Spring Boot where to find the Logback config before the application context starts:

```yaml
logging:
  config: file:/app/config/logback-spring.xml
```

Container stdout (where Logback writes) is captured by Docker's **json-file** logging driver, which rotates the log to prevent disk exhaustion:

```yaml
services:
  fhir:
    logging:
      driver: "json-file"
      options:
        max-size: "20m"   # rotate at 20 MB
        max-file: "5"     # keep 5 rotated files (100 MB max total)
```

The rotated files live at `/var/lib/docker/containers/<id>/<id>-json.log` on the Docker host. Each line in those files is Docker's envelope:

```json
{"log":"{...logback JSON...}\n","stream":"stdout","time":"2026-06-19T..."}
```

`docker compose logs` unwraps the envelope and prepends a service prefix, so what you see on screen (and what `grep` works against) is the raw Logback JSON line.

---

## Log format

Each access log entry is a JSON object on stdout. The envelope is Logback's `JsonEncoder` format:

```json
{
  "sequenceNumber": 42,
  "timestamp": 1750320612345,
  "nanoseconds": 345000000,
  "level": "INFO",
  "threadName": "http-nio-8080-exec-2",
  "loggerName": "fhirtest.access",
  "context": {"name": "default", "birthdate": 1750320000000, "properties": {}},
  "mdc": {},
  "message": "verb=GET path=/fhir/Patient/123 op=read opName= resource=123 ...",
  "throwable": null
}
```

Key field notes:
- `timestamp` is Unix epoch milliseconds (not ISO-8601). Convert: `python3 -c "import datetime; print(datetime.datetime.fromtimestamp(1750320612))"`.
- `loggerName` (camelCase) is how the field appears — use this when writing log queries.
- `message` contains the structured `key=value` FHIR accounting fields.

Filter on `loggerName == "fhirtest.access"` to isolate access records from HAPI application log lines.

### Fields in `message`

| Field | Source | Example | Notes |
|-------|--------|---------|-------|
| `verb` | HTTP method | `GET`, `POST` | |
| `path` | Servlet path | `/fhir/Patient/123` | |
| `op` | FHIR operation type | `read`, `search-type`, `create`, `transaction` | Set by HAPI — see operation type codes below |
| `opName` | Extended operation name | `$validate`, `$everything` | Empty string if not an extended operation |
| `resource` | Resource name or ID | `Patient`, `123` | Type-level requests show resource name; instance-level show ID |
| `remoteAddr` | Originating IP | `192.168.1.10` | Direct client IP |
| `forwardedFor` | `X-Forwarded-For` header | `203.0.113.5` | Populated when server is behind a proxy/load balancer |
| `userAgent` | `User-Agent` header | `HAPI-FHIR/7.0.0` | Client software identifier |
| `requestId` | `X-Request-ID` or HAPI-assigned | `abc-123` | Correlate with HAPI application logs |
| `params` | Query string | `family=Smith&_count=10` | Empty for non-search operations |
| `processingMs` | Integer milliseconds | `42` | End-to-end request processing time |

### Common FHIR operation type codes (`op`)

| Code | Meaning |
|------|---------|
| `read` | GET `/fhir/{type}/{id}` |
| `vread` | GET `/fhir/{type}/{id}/_history/{vid}` |
| `search-type` | GET `/fhir/{type}?...` |
| `create` | POST `/fhir/{type}` |
| `update` | PUT `/fhir/{type}/{id}` |
| `delete` | DELETE `/fhir/{type}/{id}` |
| `transaction` | POST `/fhir` with Bundle type=transaction |
| `history-type` | GET `/fhir/{type}/_history` |
| `history-instance` | GET `/fhir/{type}/{id}/_history` |
| `extended-operation-type` | Extended operation on a type |
| `extended-operation-instance` | Extended operation on an instance |
| `capabilities` | GET `/fhir/metadata` |

---

## Consuming the log

### Docker Compose (local)

`docker compose logs` prepends a `<service>  | ` prefix to each line. Strip it with `awk '{$1=$2=""; print substr($0,3)}'` before parsing JSON.

```bash
# Stream access lines only (no JSON parsing needed)
docker compose logs fhir --follow | grep '"fhirtest.access"'

# Pretty-print a single access line (strip the compose prefix first)
docker compose logs fhir 2>/dev/null \
  | grep '"fhirtest.access"' | head -1 \
  | awk '{$1=$2=""; print substr($0,3)}' \
  | python3 -m json.tool

# Count operations by type in the last 100 access lines
docker compose logs fhir 2>/dev/null \
  | grep '"fhirtest.access"' | tail -100 \
  | awk '{$1=$2=""; print substr($0,3)}' \
  | python3 -c "
import sys, json, collections
counts = collections.Counter()
for line in sys.stdin:
    try:
        msg = json.loads(line.strip())['message']
        for part in msg.split():
            if part.startswith('op='):
                counts[part[3:]] += 1
    except Exception:
        pass
for op, n in counts.most_common():
    print(f'{n:5d}  {op}')
"
```

### Structured log shipping

In production, ship container stdout to a log aggregator (ELK, Grafana Loki, AWS CloudWatch, etc.). Filter by `loggerName = "fhirtest.access"` to separate access records. The `message` field key=value pairs can be further parsed with a KV filter (Logstash `kv` filter, Loki's `pattern` parser, etc.).

Example Loki LogQL:

```logql
{container="ph-cdr-hapi"} | json | loggerName="fhirtest.access" | pattern `verb=<verb> path=<path> op=<op> <_>`
```

---

## What is NOT logged

- FHIR resource body content (`requestBodyFhir` is intentionally excluded from the format string)
- HTTP response bodies
- Authentication tokens or session secrets
- Patient-identifiable clinical data

---

## User notice {#user-notice}

The HAPI web UI displays a notice on the About page informing users that access logging is active. This is implemented via `hapi.fhir.custom_content_path` (akkadakka template-inclusion pattern):

- `hapi/custom/about.html` — HTML fragment displayed in the About page
- Mounted read-only at `/app/config/custom/` in the container
- HAPI's about-page JavaScript fetches `content/custom/about.html` if it exists

To update the notice text, edit `hapi/custom/about.html` and redeploy (`docker compose up -d --force-recreate fhir`). No image rebuild is needed.

If the file is absent or the volume mount is misconfigured, the notice is silently absent (the JS `fileExists()` check degrades gracefully).

---

## Disabling access logging

To disable without removing the configuration:

```yaml
# In hapi/application.yaml — silence the access logger
logging:
  level:
    fhirtest.access: "OFF"
```

To remove entirely: delete the `hapi.fhir.logger.*` keys from `application.yaml`, remove the `hapi-logback` config entry from `docker-compose.yml`, and delete `hapi/logback-spring.xml`.
