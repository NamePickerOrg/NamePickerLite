#!/usr/bin/env bash
# 从项目根目录的 .all-contributorsrc 同步到 Flutter assets 中
# 在 flutter pub get 之前运行
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../../.all-contributorsrc"
DEST="$SCRIPT_DIR/../assets/all_contributors.json"

if [ ! -f "$SRC" ]; then
  echo "Error: $SRC not found"
  exit 1
fi

cp "$SRC" "$DEST"
echo "Synced .all-contributorsrc -> assets/all_contributors.json"
