# Known Issues

---

## (a) HAPI v8.10.0 UCUM Chain Regression — Issue #7796

### What it is

HAPI FHIR v8.x ships with a UCUM stub CodeSystem on the classpath with `"content": "not-present"`. This is the correct FHIR declaration for a code system whose concepts are not distributed in the package (UCUM license prohibits redistribution of the full concept list). However, HAPI's terminology validation layer (TRM / `TermReadSvcImpl`) incorrectly intercepts UCUM code validations when a FHIR-core ValueSet binding is involved, returning "code not found" instead of falling through to `CommonCodeSystemsTerminologyService` (which validates UCUM algorithmically):

```
Unknown code 'mm[Hg]' in the CodeSystem 'http://unitsofmeasure.org' version '2.1.1'
Unknown code 'd' in the CodeSystem 'http://unitsofmeasure.org' version '2.1.1'
```

Affected scenarios:
- Any Observation profiled against `http://hl7.org/fhir/StructureDefinition/bp` (blood pressure) — its `component.valueQuantity.code` is bound to `ucum-vitals-common`
- Any MedicationRequest / MedicationStatement with `dosageInstruction.timing.repeat.periodUnit` — bound to `units-of-time`

This regression was introduced in HAPI v8. HAPI v7.x handled the classpath stub differently and did not exhibit this behaviour.

### Why the fragment fixes it

HAPI's TRM gives precedence to a CodeSystem stored in the database over the classpath stub. Uploading a `content: fragment` CodeSystem at `http://unitsofmeasure.org` registers the listed codes as known-valid in the DB, and TRM uses the stored resource instead of the classpath stub for those codes.

Per FHIR R4 `content: fragment` semantics: codes not listed are not declared invalid — they are simply absent from the fragment. HAPI should fall through to the remote UCUM service (`tx.fhir.org/r4`) for unlisted codes, where UCUM is validated algorithmically.

### The workaround applied here

`scripts/upload.sh` seeds `hapi/ucum-fragment.json` as step 1b before any example uploads. The fragment lists all UCUM codes used by ph-core and ph-ereferral. See [Configuration Reference — ucum-fragment.json](configuration.md#hapiucum-fragmentjson) for the full list.

If you wipe the database (`docker compose down -v`) and restart, re-run `scripts/upload.sh` (or PUT the fragment manually) before uploading resources that use UCUM codes.

### Upstream status

Tracked at https://github.com/hapifhir/hapi-fhir/issues/7796. PR #7798 was merged into v8.10.0 but the fix appears incomplete (follow-up PR #7816 is open). As of v8.10.0, the fragment workaround is still necessary. Monitor the issue; when fixed in a future HAPI release, the fragment can be removed.

---

## (b) DNS Failures on systemd-resolved Ubuntu Hosts

### Symptom

On Ubuntu hosts using `systemd-resolved` (default on Ubuntu 20.04, 22.04, 24.04), HAPI containers fail to resolve external hostnames. This causes:

- IG package download failing on first boot (`UnknownHostException: jgsuess.github.io`)
- Remote terminology service calls failing silently (LOINC/SNOMED codes not validated against tx.fhirlab.net)
- `UCUM` fragment upload failing if validation of the CodeSystem itself requires the remote server

Error in HAPI logs:
```
ca.uhn.fhir.rest.client.exceptions.FhirClientConnectionException: Failed to parse response
from server — java.net.UnknownHostException: tx.fhirlab.net: No address associated with hostname
```

### Why it happens

Ubuntu's `systemd-resolved` configures the host's `/etc/resolv.conf` to point to the stub resolver at `127.0.0.53` (a loopback address). Docker containers have their own network namespace; `127.0.0.53` inside a container refers to the container's loopback, not the host's. The Docker daemon normally detects this and substitutes upstream DNS servers, but this detection is unreliable when `/etc/resolv.conf` is a symlink to `systemd-resolved`'s stub config rather than the fallback resolv file.

### The fix in docker-compose.yml

```yaml
dns:
  - 8.8.8.8
  - 8.8.4.4
```

This tells Docker to write `8.8.8.8` and `8.8.4.4` into the container's `/etc/resolv.conf`, bypassing the systemd-resolved stub entirely.

For environments that cannot reach Google Public DNS (corporate networks, air-gapped), replace with your internal DNS resolver IP:

```yaml
dns:
  - 10.0.0.53   # replace with your internal resolver
```

### When to remove this

The `dns:` block is safe to leave in on all platforms — it is harmless on non-Ubuntu hosts. Remove it if:
- You are on Docker Desktop (macOS/Windows) — DNS is handled by the VM and works without this
- Your Ubuntu host does not use `systemd-resolved` (verify with `resolvectl status`)
- Your corporate policy prohibits outbound DNS to 8.8.8.8

---

## (c) Profile Validation Inactive for Draft-Status IGs

### Why this happens

HAPI enforces profile validation only for StructureDefinitions with `"status": "active"`. This is correct FHIR behaviour: draft profiles are works-in-progress and are not intended to be binding constraints in a production server.

All current ph-ereferral StructureDefinitions have `"status": "draft"`. As a result:
- Resources claiming `meta.profile = "https://fhir.doh.gov.ph/pheref/StructureDefinition/..."` are *not* rejected if they violate the profile
- HAPI loads and stores the profiles, but the `RequestValidatingInterceptor` does not enforce them

### What still works

- Profiles are stored and searchable: `GET /fhir/StructureDefinition?url=https://fhir.doh.gov.ph/pheref/...`
- Explicit `$validate` works against draft profiles: `POST /fhir/Patient/$validate?profile=<url>`
- MDM deduplication is independent of profile status and always active
- ph-core profiles with `status: active` are enforced normally

### Workaround

Call `$validate` explicitly in client code before or after writing resources to validate against ph-ereferral profiles. The `$validate` operation honours draft profiles.

Alternatively, post-process the ph-ereferral IG package `.tgz` to change `"status": "draft"` to `"status": "active"` in all StructureDefinitions before loading (requires rebuilding the package).

### Expected resolution

Once ph-ereferral advances to formal publication with `status: active`, this issue resolves automatically with no configuration change needed.

---

## (d) Transaction Bundle Storage

### What the error is

HAPI FHIR rejects `PUT /Bundle/{id}` for Bundles with `"type": "transaction"` or `"type": "batch"`:

```
HTTP 400: HAPI-0522: Unable to store a Bundle resource on this server
with a Bundle.type value of: transaction.
```

This is correct FHIR server behaviour. Transaction and batch Bundles are meant to be *executed* (HAPI processes each entry's `request.method` and `request.url`), not stored as resources. Storing them as static resources would bypass the transactional semantics.

### What the upload script does instead

`scripts/upload.sh` detects transaction and batch Bundles in `upload_resource()`: if `resourceType == "Bundle"` and `type` is `"transaction"` or `"batch"`, the script sets `method=POST` and `endpoint=$BASE_URL` (the FHIR base URL without a resource path). HAPI then executes the bundle rather than stores it.

The response is a Bundle of type `transaction-response` (or `batch-response`). Any HTTP 2xx is counted as a pass.

### Implication

The ph-core package contains `Bundle/transaction-example`, which is a transaction bundle containing Patient, Practitioner, Encounter, Condition, Medication, Observation, AllergyIntolerance, and Immunization resources. When executed as a transaction, HAPI creates/updates all the contained resources — the bundle itself is not stored as a retrievable resource at `/Bundle/transaction-example`.

---

## (e) Provenance BCP:13 MIME Type Fix (patch applied in upload script)

### What the error is

The ph-core package's `Provenance/provenance-single-example` uses code `xml` in `urn:ietf:bcp:13` for `Signature.targetFormat` and `Signature.sigFormat`:

```json
"targetFormat": "xml",
"sigFormat": "xml"
```

`xml` is not a valid MIME type in the IANA registry (BCP:13). The correct code is `application/xml`.

HAPI rejects this with:
```
HTTP 422: Unknown code 'xml' in the CodeSystem 'urn:ietf:bcp:13'
```

### The patch applied in upload.sh

After downloading the ph-core package, `scripts/upload.sh` (step 2b) post-processes Provenance JSON files to replace `"xml"` with `"application/xml"` in `targetFormat` and `sigFormat` fields. This fix is applied in-memory to the downloaded copy; it does not modify the published package.

### Long-term fix

A bug report should be filed with the ph-core IG authors to correct `provenance-single-example.fsh` to use `#application/xml` instead of `#xml`. Once fixed and a new package version is published, the patch in the upload script can be removed.
