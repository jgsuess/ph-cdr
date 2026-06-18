# Compliance Analysis: aiscream-hapi-server spec

Compared against [`niccoreyes/aiscream-jpa` spec](https://github.com/niccoreyes/aiscream-jpa/blob/main/openspec/changes/aiscream-hapi-server/specs/aiscream-hapi-server/spec.md).

---

## Config-level gaps

Fixable via `hapi/application.yaml`.

| Requirement | Spec | Ours | Gap |
|---|---|---|---|
| **ph-core version** | `0.2.0` from `build.fhir.org/ig/UP-Manila-SILab/ph-core` | `0.1.1` from `jgsuess.github.io` | Wrong version and wrong source |
| **ph-ereferral version** | `0.1.0` from `build.fhir.org/ig/ph-ereferral-organization/ph-ereferral` | `0.3.1` from `jgsuess.github.io` | Wrong version and wrong source |
| **Remote terminology** | Single catch-all `system: '*'` → `tx.fhirlab.net/fhir` | Per-system entries; UCUM routed to `tx.fhir.org/r4` | Missing catch-all; UCUM not delegated to fhirlab |
| **`requests_enabled`** | `false` (RepositoryValidatingInterceptor is used instead) | `true` | Fires before dedup interceptor, breaking the dedup flow |
| **`responses_enabled`** | `true` | `false` | Response validation not enabled |
| **`enforce_referential_integrity_on_write`** | `true` | not set (defaults to `false`) | Dangling references not rejected on write |
| **`enable_repository_validating_interceptor`** | `true` | not set | Profile-based enforcement not active |

---

## Code-level gaps

These requirements describe custom Java classes that cannot be addressed by config alone. They require a custom HAPI image built from a fork of `hapi-fhir-jpaserver-starter`.

### 1. Identifier-based deduplication interceptor

A custom `SERVER_INCOMING_REQUEST_PRE_HANDLED` hook that:

- Merges Patient, Practitioner, and Organization on individual POST by matching identifiers (PhilSys / PhilHealth ID for Patient; any identifier for Practitioner and Organization)
- Applies "incoming wins, preserve existing non-empty fields, union identifiers" merge strategy
- Handles dedup within transaction Bundles by converting matched POST entries to PUT against the existing resource ID while preserving `fullUrl` for intra-bundle reference resolution
- Returns HTTP 200 with a `Bundle` of type `collection` containing the merged resource and an informational `OperationOutcome`
- Throws `DeduplicationMatchedException extends BaseServerResponseException` to intercept the outgoing response

### 2. Strict terminology rejection

A custom `RepositoryValidatingInterceptor` built via modifications to `RepositoryValidationInterceptorFactoryR4.java` with:

```java
.rejectOnSeverity(WARNING)
.suppressNoBindingMessage()
.suppressWarningForExtensibleValueSetValidation()
```

This raises unresolvable code system warnings to ERROR severity and rejects the write.

### 3. Custom interceptor registration order

In `StarterJpaConfig.java`, `registerCustomInterceptors()` must be called **before** the `repositoryValidatingInterceptor` registration so the dedup interceptor runs before profile validation.

---

## What we have that the spec does not mention

| Feature | Notes |
|---|---|
| **MDM (`mdm_enabled: true`)** | HAPI's built-in MDM. The spec replaces this with the custom dedup interceptor above. |
| **Lucene / Hibernate Search** | `_content` and `_text` search. Not covered by the spec. |
| **UCUM fragment workaround** | HAPI v8.10.0-specific workaround for issue #7796. Not addressed in the spec. |

---

## Summary

The config gaps are straightforward to close. The dedup and strict-terminology requirements are the substantial delta — they require a custom HAPI image, which is presumably what `niccoreyes/aiscream-jpa` provides.
