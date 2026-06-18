# Access Logging

ph-cdr logs every inbound FHIR request for statistical accounting and governance purposes. This page describes the log format, available fields, how to consume the log, and how to customise the user-facing notice.

---

## How it works

HAPI's built-in `LoggingInterceptor` intercepts every request and emits one record per request to an SLF4J logger named `fhirtest.access`. A Logback configuration (`hapi/logback-spring.xml`) routes that logger to stdout as **one JSON object per line** using the Logstash encoder.

This is entirely config-driven — no custom Java code is involved. The configuration follows the akkadakka pattern:

| File | Mounted at | Purpose |
|------|-----------|---------|
| `hapi/application.yaml` | `/app/config/application.yaml` | Logger name, format string, `logging.config` pointer |
| `hapi/logback-spring.xml` | `/app/config/logback-spring.xml` | Routes `fhirtest.access` to JSON stdout appender |
| `hapi/custom/about.html` | `/app/config/custom/about.html` | Logging notice shown in HAPI web UI |

---

## Log format

Each access log entry is a JSON object on stdout. The outer envelope is standard Logstash format:

```json
{
  "@timestamp": "2026-06-18T07:30:12.345Z",
  "@version": "1",
  "message": "verb=GET path=/fhir/Patient/123 op=read opName= resource=123 ...",
  "logger_name": "fhirtest.access",
  "level": "INFO"
}
```

The `message` field contains a structured `key=value` string with all FHIR-specific accounting fields. Filter on `logger_name == "fhirtest.access"` to isolate access records from HAPI application log lines.

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

```bash
# Stream access lines only
docker compose logs fhir --follow | grep '"fhirtest.access"'

# Pretty-print a single access line
docker compose logs fhir 2>/dev/null | grep '"fhirtest.access"' | head -1 | python3 -m json.tool

# Count operations by type in the last 100 access lines
docker compose logs fhir 2>/dev/null \
  | grep '"fhirtest.access"' | tail -100 \
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

In production, ship container stdout to a log aggregator (ELK, Grafana Loki, AWS CloudWatch, etc.). Filter by `logger_name = "fhirtest.access"` to separate access records. The `message` field key=value pairs can be further parsed with a KV filter (Logstash `kv` filter, Loki's `pattern` parser, etc.).

Example Loki LogQL:

```logql
{container="ph-cdr-hapi"} | json | logger_name="fhirtest.access" | pattern `verb=<verb> path=<path> op=<op> <_>`
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
