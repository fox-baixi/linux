#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${BACKUP_ENV_FILE:-${SCRIPT_DIR}/backup.env}"
[ -f "$ENV_FILE" ] || { echo "Missing env file: $ENV_FILE"; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

command -v rclone >/dev/null 2>&1 || { echo "rclone not found"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar not found"; exit 1; }

: "${WEBDAV_DOMAIN:?Missing WEBDAV_DOMAIN}"
: "${WEBDAV_USERNAME:?Missing WEBDAV_USERNAME}"
: "${WEBDAV_PASSWORD:?Missing WEBDAV_PASSWORD}"
: "${WEBDAV_PATH:?Missing WEBDAV_PATH}"
: "${SERVER_ID:?Missing SERVER_ID}"
: "${BACKUP_SOURCES:?Missing BACKUP_SOURCES}"

EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-}"
ARCHIVE_TMP_DIR="${ARCHIVE_TMP_DIR:-/tmp}"
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-openlist}"
WEBDAV_BASE="${WEBDAV_BASE:-${WEBDAV_DOMAIN}/dav}"
REMOTE_DIR="${REMOTE_DIR:-${WEBDAV_PATH}/${SERVER_ID}}"
RETENTION_DAYS="${RETENTION_DAYS:-3}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-backup}"
RCLONE_EXTRA_ARGS="${RCLONE_EXTRA_ARGS:-}"
TIMESTAMP="$(date +%F-%H-%M-%S)"
ARCHIVE_NAME="${ARCHIVE_PREFIX}-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${ARCHIVE_TMP_DIR%/}/${ARCHIVE_NAME}"
TMP_RCLONE_CONF="$(mktemp)"

cleanup() {
  rm -f "$TMP_RCLONE_CONF" "$ARCHIVE_PATH"
}
trap cleanup EXIT

mkdir -p "$ARCHIVE_TMP_DIR"

IFS=' ' read -r -a SOURCES <<< "$BACKUP_SOURCES"
[ "${#SOURCES[@]}" -gt 0 ] || { echo "No BACKUP_SOURCES defined"; exit 1; }

for src in "${SOURCES[@]}"; do
  [ -e "$src" ] || { echo "Source not found: $src"; exit 1; }
done

cat > "$TMP_RCLONE_CONF" <<EOC
[${RCLONE_REMOTE_NAME}]
type = webdav
url = ${WEBDAV_BASE}
vendor = other
user = ${WEBDAV_USERNAME}
pass = $(rclone obscure "${WEBDAV_PASSWORD}")
EOC

echo "[1/4] creating archive: $ARCHIVE_PATH"
TAR_ARGS=(--warning=no-file-changed)
if [ -n "$EXCLUDE_PATTERNS" ]; then
  while IFS= read -r pattern; do
    [ -n "$pattern" ] && TAR_ARGS+=("--exclude=$pattern")
  done < <(printf '%s\n' "$EXCLUDE_PATTERNS")
fi

TARGETS=()
for src in "${SOURCES[@]}"; do
  parent="$(dirname "$src")"
  base="$(basename "$src")"
  TARGETS+=("-C" "$parent" "$base")
done

tar "${TAR_ARGS[@]}" -czf "$ARCHIVE_PATH" "${TARGETS[@]}"

echo "[2/4] uploading archive to ${RCLONE_REMOTE_NAME}:${REMOTE_DIR}"
# shellcheck disable=SC2086
rclone copy "$ARCHIVE_PATH" "${RCLONE_REMOTE_NAME}:${REMOTE_DIR}" \
  --config "$TMP_RCLONE_CONF" \
  --fast-list \
  -P \
  $RCLONE_EXTRA_ARGS

echo "[3/4] cleaning old backups (>${RETENTION_DAYS}d)"
rclone delete "${RCLONE_REMOTE_NAME}:${REMOTE_DIR}" \
  --config "$TMP_RCLONE_CONF" \
  --min-age "${RETENTION_DAYS}d" \
  --include "${ARCHIVE_PREFIX}-*.tar.gz"

echo "[4/4] done: $ARCHIVE_NAME"
