#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 bravia-x8000h-downgrade contributors
#
# Display metadata from a local image. This does not read device/RPMB state.
# Usage: bash tools/inspect-vbmeta.sh <image> [path-to-avbtool.py]

set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    echo "Usage: inspect-vbmeta.sh <image> [path-to-avbtool.py]" >&2
    exit 2
fi
[[ -f "$1" ]] || { echo "error: image not found: $1" >&2; exit 1; }

# A Python source file need not be executable. A command installed on PATH
# should run through its own interpreter, rather than being opened by filename.
candidate="${2:-${AVBTOOL:-}}"
if [[ -n "$candidate" ]]; then
    [[ -f "$candidate" ]] || { echo "error: avbtool file not found: $candidate" >&2; exit 1; }
    AVB=(python3 "$candidate")
elif command -v avbtool >/dev/null 2>&1; then
    AVB=("$(command -v avbtool)")
elif command -v avbtool.py >/dev/null 2>&1; then
    AVB=("$(command -v avbtool.py)")
else
    echo "error: install avbtool or set AVBTOOL to its Python source file" >&2
    exit 1
fi

"${AVB[@]}" info_image --image "$1"
printf '\n%s\n' "This index belongs to the image. It is not a readout of RPMB."
