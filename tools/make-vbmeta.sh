#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 bravia-x8000h-downgrade contributors
#
# Build the metadata configuration used in the recorded downgrade.
# The caller must establish the index independently; this tool cannot read RPMB.
# Usage: bash tools/make-vbmeta.sh <rollback-index> [output.img] [key.pem]

set -euo pipefail

if (( $# < 1 || $# > 3 )) || [[ ! "$1" =~ ^[0-9]+$ ]]; then
    echo "Usage: make-vbmeta.sh <decimal-rollback-index> [output.img] [key.pem]" >&2
    echo "Read the firmware and boot-state discussion before choosing an index." >&2
    exit 2
fi

RBI=$1
OUT=${2:-vbmeta_patched.img}
KEY=${3:-vbmeta_patch_key.pem}
[[ ! -e "$OUT" ]] || { echo "error: refusing to overwrite: $OUT" >&2; exit 1; }
[[ "$OUT" != "$KEY" ]] || { echo "error: output and key paths must differ" >&2; exit 2; }

# Validate the full uint64 domain before creating a key or an output image.
# Keep decimal input out of shell arithmetic, where leading zeroes mean octal.
python3 - "$RBI" <<'PY'
import sys
value = int(sys.argv[1], 10)
if not 0 <= value <= (1 << 64) - 1:
    sys.exit("error: rollback index is outside uint64 range")
PY

candidate="${AVBTOOL:-}"
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

# Normalize to decimal before passing to avbtool's integer parser.
RBI=$(python3 -c 'import sys; print(int(sys.argv[1], 10))' "$RBI")
if [[ ! -e "$KEY" ]]; then
    (umask 077; openssl genrsa -out "$KEY" 2048)
elif [[ ! -f "$KEY" ]]; then
    echo "error: key is not a regular file: $KEY" >&2
    exit 1
fi

"${AVB[@]}" make_vbmeta_image \
    --output "$OUT" \
    --key "$KEY" \
    --algorithm SHA256_RSA2048 \
    --rollback_index "$RBI" \
    --flags 2 \
    --padding_size 8192

"${AVB[@]}" info_image --image "$OUT"
printf '\n%s\n' \
    "Created: $OUT" \
    "Expected: index $RBI, flags 2, location 0, no descriptors, 8192 bytes." \
    "This tool does not establish whether the index is suitable for your device." \
    "Nothing has been flashed. Read docs/procedure.md before continuing."
