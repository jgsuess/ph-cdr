# Contributing

## Scope of this repository

This repository contains only the CDR stack configuration — the Docker Compose file, HAPI server settings, MDM rules, and upload tooling. It does not bundle or redistribute any IG content.

The Philippine FHIR Implementation Guides (`fhir.ph.core`, `fhir.ph.ereferral`) are maintained separately and downloaded at runtime from their respective GitHub Pages package registries. Those packages are derived from open-source IG material and are subject to their own licenses. Refer to the source repositories for details:

- [jgsuess/ph-core](https://github.com/jgsuess/ph-core)
- [jgsuess/ph-ereferral](https://github.com/jgsuess/ph-ereferral)

## Status

This repository is **experimental**. It is not currently accepting external contributions.

The configuration, scripts, and documentation here are evolving alongside active development of the Philippine FHIR Implementation Guides. Interfaces, defaults, and structures may change without notice.

## Reporting issues

If you encounter a problem running the stack or have a question about the configuration, you are welcome to open an issue. Please include:

- Your host OS and Docker version (`docker version`)
- The HAPI version you are using
- Relevant log output (`docker compose logs fhir`)
- Steps to reproduce

## Future contributions

Once the stack stabilises, this policy will be updated. Watch this repository for updates.
