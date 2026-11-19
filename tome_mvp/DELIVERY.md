# Source release and build inputs

Create a source bundle from a committed revision:

```
python scripts/package_release.py build --commit <commit> --kernel <kernel-directory> --config <external-config.json> --output artifacts/release.tar.gz
python scripts/package_release.py verify artifacts/release.tar.gz --kernel <kernel-directory> --config <external-config.json>
```

The builder uses the selected commit, not uncommitted work. It verifies the archive after creation. The verifier checks the allowlist, required entry files, each size and hash, the external kernel directory tree, structural runtime configuration using the validator in that commit, and selected core Python imports in an isolated process. It records the kernel file list and tree hash. It does not include the config, secrets, kernel, runtime data or player saves. Use only trusted source releases: a manifest inside an archive is an integrity check, not a signature. Successful verification does not prove complete dynamically loaded dependencies, native compatibility or production readiness. Preserve the previous release, compatible kernel, config and state for rollback. Deployment and asset preparation remain separate.

The tracked source allowlist includes current owned modules, selected scripts, specific static rules and web artwork. The old gameplay_mvp package and dm_mvp/tabletop_session.py are excluded; the latter depends on test fixtures and is not a current launch entry. External dependencies include ToME runtime and assets, native kernel, Python dependencies and Node. `requirements-runtime.txt` pins local verified package versions; `requirements-test.txt` adds pytest. Node is needed for ToME build and browser tests. Playwright is optional for browser integration and is not installed by the lightweight Python test set. CI also verifies frozen source/resource manifests before the unit group.

Set `TOME_SOURCE`, `TOME_RUNTIME`, `TOME_ADDON`, `TOME_SDK`, `TOME_INSTALL` and optionally `TOME_TCC` to paths. Unset values retain historical local paths. Source preparation requires an offline complete archive and a trusted independently obtained SHA-256:

```
python scripts/prepare_tome_headless_source.py --archive <offline.tar.bz2> --sha256 <trusted-sha256>
python scripts/doctor_tome_build.py --pins <pins.json>
```

`pins.json` has the form `{"sdk_emcc":"<64 lowercase SHA-256 hex>"}`. Obtain the pin independently. Doctor verifies all files in the source extraction manifest, required source members, fixed project hashes for addon and two runtime rule files, the supplied SDK emcc hash and Node availability. A hash in a locally generated manifest or supplied by the same source does not authenticate provenance. Doctor does not authenticate the whole SDK, runtime, toolchain or all dependencies; the real build applies further fixed checks. The old partial-stream source manifest lacks a complete archive pin and cannot pass. Full Wasm compilation has not been reproduced by this change.

`python scripts/acceptance.py current-unit` runs the bounded current unit set, and is the CI default. `current-integration` includes actual localhost HTTP/RPC and may require network permissions. It also runs separate source identity, native item, zone, handover, XP and save fixtures; those separate fixtures do not form a real native end-to-end chain. The current-unit group also includes one same-state SQLite contract chain through area entry, suspended handover, departure, XP, allocation save and reopening; its native VM, access checks and binding lookup are substitutes. `native-contract` contains protocol and configuration tests with substitutes; it is not a real kernel acceptance. `native-e2e` requires `TOME_HEADLESS_BUILD_DIR` for an isolated real worker and is never run by default; missing input is reported as not prepared. It executes a finite native automation/items sample, not a full game. `history` covers frozen identity and legacy archive readers. `all` explicitly runs the full historical pytest set, including retired behavior and tests requiring external inputs. No group certifies a production release or full game.

Frozen R0 and V2 resources are selected from the manifests in the requested commit, including the three pinned legacy history packages. Verification checks their pinned bytes and executes the frozen installation check. These historical manifests include tracked, non-secret default configuration files; the operator's supplied runtime configuration and credentials remain external. Runtime guide documents, director SOP, companion templates and battle skill references are included. The manifest is an integrity check, not an authenticity signature.
