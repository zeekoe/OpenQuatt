# Docker development environment

This directory contains the Docker-based development environment for OpenQuatt.
It isolates the host toolchain (Python 3.12, Node.js 22, C++ with ccache and the
pinned clang-format) in a reproducible container, so host CI-equivalent checks,
firmware builds and OTA upgrades run without a local ESPHome/setup.

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the `openquatt-dev` image with the host and firmware toolchains. |
| `dev.sh` | Builds the image and runs the CI-equivalent build/tests inside the container. |
| `ci.sh` | In-container entrypoint executed by `dev.sh`, runs the actual checks per mode. |
| `ota.sh` | Rebuilds web bundles and firmware in the container and OTA-upgrades a controller. |

## dev.sh

Host-side entrypoint for development. Builds (or reuses) the `openquatt-dev`
image and runs `docker/ci.sh` inside a container that mounts the repository at
`/workspace` under your host UID/GID, so build artifacts are owned by you.
User-local caches (npm, ESP-IDF tools, ccache, the ESPHome venv) persist in the
named volume `openquatt-dev-home`.

```sh
./docker/dev.sh                  # host CI-equivalent build and tests
./docker/dev.sh --rebuild ci     # force a fresh image build, then ci
./docker/dev.sh firmware         # ci plus ESPHome config validation
./docker/dev.sh compile          # ci plus full firmware compilation (slow, downloads ESP-IDF)
./docker/dev.sh shell            # interactive shell inside the container
./docker/dev.sh --help
```

Environment overrides: `OQ_DEV_IMAGE` (image name) and `OQ_DEV_HOME_VOLUME`
(volume name).

## ci.sh

In-container runner, not meant to be called directly. Accepts one mode and
forwards extra arguments:

- `ci` (default) — host checks only, no ESP-IDF toolchain: web dependency
  install, settings-backup, Python contract, docs, C++ formatting, web build
  and smoke checks, HIL harness and host regression tests.
- `firmware` — `ci` plus a bootstrapped ESPHome venv and config validation of
  all enabled profiles (`dev.py validate --config-only`).
- `compile` — `ci` plus a full `dev.py validate`, which compiles every enabled
  profile; downloads the ESP-IDF toolchain on first run.
- `shell` — interactive shell inside the container.

## ota.sh

Builds the app and OTA-upgrades the controller. On the host it reuses the
`openquatt-dev` image (like `dev.sh`) and re-runs itself inside the container
with host networking, so mDNS names such as `openquatt.local` resolve from the
container. In the container it bootstraps the ESPHome venv when missing,
rebuilds the embedded web bundles, preflights the target and runs
`esphome run --ota-platform esphome` for the selected config.

```sh
./docker/ota.sh                                  # default config to openquatt.local
./docker/ota.sh configs/heatpump_controller_q/duo.yaml
./docker/ota.sh --rebuild --verbose
```

Environment overrides: `OQ_OTA_DEVICE` (OTA target, default
`http://openquatt.local`), plus `OQ_DEV_IMAGE` and `OQ_DEV_HOME_VOLUME`.