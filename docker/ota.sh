#!/usr/bin/env bash
# Build the OpenQuatt app and OTA-upgrade the controller at http://openquatt.local.
#
# Host side (default): builds or reuses the openquatt-dev image (like
# docker/dev.sh) and re-runs this script inside the container with host
# networking, so mDNS names such as openquatt.local resolve from the container
# (see docker/Dockerfile, nss-mdns).
#
# Container side (OQ_OTA_CONTAINER=1): bootstraps the ESPHome venv when
# missing, rebuilds the embedded web bundles, checks that the target answers
# and runs `esphome run --device <host> --ota-platform esphome --no-logs
# <config>`, which compiles the firmware and pushes it over ESPHome OTA.
#
# Usage:
#   docker/ota.sh [--rebuild] [config] [extra esphome run args...]
#
#   --rebuild  Rebuild the image even if one already exists.
#   config     Firmware entrypoint (default configs/heatpump_controller_q/duo.yaml).
#   extra      Forwarded to `esphome run` (e.g. --verbose).
#
# Environment: OQ_OTA_DEVICE OTA target (default http://openquatt.local)
#              OQ_DEV_IMAGE / OQ_DEV_HOME_VOLUME as in docker/dev.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="${OQ_DEV_IMAGE:-openquatt-dev}"
HOME_VOLUME="${OQ_DEV_HOME_VOLUME:-openquatt-dev-home}"
VENV_DIR="/home/dev/openquatt-venv"
DEFAULT_DEVICE="http://openquatt.local"
DEFAULT_CONFIG="configs/heatpump_controller_q/duo.yaml"

step() {
    echo ""
    echo "================================================================"
    echo "[openquatt-ota] $*"
    echo "================================================================"
}

device_host() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    url="${url%%/*}"
    printf '%s' "${url}"
}

container_main() {
    local config="${DEFAULT_CONFIG}"
    if [[ $# -gt 0 && "$1" != -* ]]; then
        config="$1"
        shift
    fi
    if [[ ! -f "${config}" ]]; then
        echo "Unknown config: ${config}" >&2
        exit 2
    fi

    local device="${OQ_OTA_DEVICE:-${DEFAULT_DEVICE}}"
    local host
    host="$(device_host "${device}")"

    step "Preflight: controller at ${device}"
    local status
    status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${device}/" || true)"
    if [[ -z "${status}" || "${status}" == "000" ]]; then
        echo "[openquatt-ota] Controller not reachable at ${device}. Is it online and on mDNS?" >&2
        exit 1
    fi

    if [[ ! -x "${VENV_DIR}/bin/esphome" ]]; then
        step "Bootstrap ESPHome virtual environment"
        python3 scripts/dev.py bootstrap --venv-dir "${VENV_DIR}"
    fi

    step "Install web build dependencies and rebuild embedded web bundles"
    npm ci
    npm run build:web

    step "Compile and OTA-upgrade ${config} to ${device}"
    "${VENV_DIR}/bin/esphome" run \
        --device "${host}" \
        --ota-platform esphome \
        --no-logs \
        "${config}" \
        "$@"

    step "OTA upgrade complete"
    echo "[openquatt-ota] Controller reboots into the new firmware."
    echo "[openquatt-ota] Reopen ${device} in a moment to verify."
}

host_main() {
    local rebuild=0
    if [[ "${1:-}" == "--rebuild" || "${1:-}" == "-r" ]]; then
        rebuild=1
        shift
    fi

    case "${1:-}" in
        help|-h|--help)
            echo "Usage: $0 [--rebuild] [config] [extra esphome run args...]"
            echo ""
            echo "  --rebuild  Rebuild the image even if one already exists."
            echo "  config     Firmware entrypoint (default ${DEFAULT_CONFIG})."
            echo "  extra      Forwarded to \`esphome run\` (e.g. --verbose)."
            echo ""
            echo "Builds the web bundles and firmware in the openquatt-dev container and"
            echo "OTA-upgrades the controller at OQ_OTA_DEVICE (default ${DEFAULT_DEVICE})."
            echo ""
            echo "Environment: OQ_OTA_DEVICE (default ${DEFAULT_DEVICE})"
            echo "             OQ_DEV_IMAGE (default ${IMAGE_NAME})"
            echo "             OQ_DEV_HOME_VOLUME (default ${HOME_VOLUME})"
            exit 0
            ;;
    esac

    cd "${ROOT_DIR}"

    if [[ "${rebuild}" == "1" ]] || ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
        step "Building image ${IMAGE_NAME} ..."
        docker build \
            --build-arg "CLANG_FORMAT_VERSION=$(cat .clang-format-version)" \
            -t "${IMAGE_NAME}" \
            -f "docker/Dockerfile" \
            "${ROOT_DIR}"
    fi

    if ! docker volume inspect "${HOME_VOLUME}" >/dev/null 2>&1; then
        step "Creating volume ${HOME_VOLUME} ..."
        docker volume create "${HOME_VOLUME}"
    fi

    TTY_FLAGS=()
    if [[ -t 0 ]]; then
        TTY_FLAGS=(-it)
    fi

    step "Running OTA build in container (host networking for mDNS)"
    exec docker run --rm \
        "${TTY_FLAGS[@]}" \
        --name openquatt-ota-run \
        --network host \
        -u "$(id -u):$(id -g)" \
        -e "HOME=/home/dev" \
        -e "OQ_OTA_CONTAINER=1" \
        -e "OQ_OTA_DEVICE=${OQ_OTA_DEVICE:-${DEFAULT_DEVICE}}" \
        -v "${ROOT_DIR}:/workspace" \
        -v "${HOME_VOLUME}:/home/dev" \
        -w /workspace \
        "${IMAGE_NAME}" \
        bash /workspace/docker/ota.sh "$@"
}

if [[ "${OQ_OTA_CONTAINER:-0}" == "1" ]]; then
    container_main "$@"
else
    host_main "$@"
fi