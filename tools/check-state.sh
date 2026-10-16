#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 bravia-x8000h-downgrade contributors
#
# Read the properties needed to check the recorded downgrade result.
# No package, settings, reboot or partition-write commands are issued.
# Usage: bash tools/check-state.sh [adb-serial]

set -euo pipefail

if (( $# > 1 )); then
    echo "Usage: check-state.sh [adb-serial]" >&2
    exit 2
fi
command -v adb >/dev/null 2>&1 || { echo "error: adb not found" >&2; exit 1; }

ADB=(adb)
if (( $# == 1 )); then
    ADB+=(-s "$1")
fi
if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
    echo "error: select one authorized ADB device; connect it before running this tool" >&2
    exit 1
fi

# These reads deliberately avoid model checks: the Android model property on the
# tested TV is a platform name, not the retail model printed on its label.
properties=(
    ro.product.model
    ro.build.display.id
    ro.build.version.release
    ro.build.version.incremental
    ro.boot.slot_suffix
    ro.boot.verifiedbootstate
    ro.boot.vbmeta.device_state
    sys.boot_completed
)
for property in "${properties[@]}"; do
    value=$("${ADB[@]}" shell getprop "$property") || {
        echo "error: could not read $property" >&2
        exit 1
    }
    value=${value//$'\r'/}
    printf '%-32s %s\n' "$property" "${value:-<unset>}"
done
