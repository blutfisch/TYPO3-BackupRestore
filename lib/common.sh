#!/usr/bin/env bash
# Shared helpers for typo3-backup.sh and typo3-restore.sh. Meant to be sourced.
# Globals set here (DB_DUMP, DB_CLIENT, BACKUP_NAME_REGEX) are used by the calling scripts.
# shellcheck disable=SC2034

# Cron runs with a minimal PATH; make sure tools in /usr/local/bin (e.g. aws) are found.
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Backup object names: typo3-backup_YYYYMMDD-HHMMSS.tar.gz.gpg
BACKUP_NAME_REGEX='^typo3-backup_[0-9]{8}-[0-9]{6}\.tar\.gz\.gpg$'

log()  { printf '%s [INFO]   %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARNUNG] %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '%s [FEHLER] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

# Loads the .env file (default: next to the scripts, override via TYPO3_BACKUP_CONFIG),
# applies defaults and validates required settings.
load_config() {
  local file="${TYPO3_BACKUP_CONFIG:-$SCRIPT_DIR/.env}"
  [[ -r "$file" ]] || die "Konfigurationsdatei nicht lesbar: $file"
  if [[ -n "$(find "$file" -perm /077 2>/dev/null)" ]]; then
    warn "Konfigurationsdatei $file ist für Gruppe/Andere zugreifbar – empfohlen: chmod 600 $file"
  fi

  set -a
  # shellcheck source=/dev/null
  source "$file"
  set +a

  BACKUP_PATHS="${BACKUP_PATHS:-}"
  BACKUP_EXCLUDES="${BACKUP_EXCLUDES-fileadmin/_processed_ fileadmin/_temp_}"
  DB_HOST="${DB_HOST:-localhost}"
  DB_PORT="${DB_PORT:-3306}"
  WORK_DIR="${WORK_DIR:-/var/tmp/typo3-backup}"
  S3_PREFIX="${S3_PREFIX:-}"
  S3_PREFIX="${S3_PREFIX#/}"
  S3_PREFIX="${S3_PREFIX%/}"

  local var missing=()
  for var in TYPO3_ROOT DB_NAME DB_USER DB_PASSWORD GPG_PASSPHRASE_FILE S3_BUCKET; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  ((${#missing[@]} == 0)) || die "Fehlende Pflichtvariablen in $file: ${missing[*]}"

  [[ -d "$TYPO3_ROOT" ]] || die "TYPO3_ROOT ist kein Verzeichnis: $TYPO3_ROOT"
  [[ -s "$GPG_PASSPHRASE_FILE" && -r "$GPG_PASSPHRASE_FILE" ]] \
    || die "Passphrase-Datei fehlt, ist leer oder nicht lesbar: $GPG_PASSPHRASE_FILE"
}

require_cmds() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Benötigtes Programm nicht gefunden: $cmd"
  done
}

# Prefers the MariaDB binaries, falls back to the MySQL-compatible names.
detect_db_tools() {
  DB_DUMP="$(command -v mariadb-dump || command -v mysqldump)" \
    || die "Weder mariadb-dump noch mysqldump gefunden"
  DB_CLIENT="$(command -v mariadb || command -v mysql)" \
    || die "Weder mariadb noch mysql (Client) gefunden"
}

# Writes a client option file so the password never shows up in the process list.
write_db_defaults() {
  local file="$1" pw="$DB_PASSWORD"
  pw="${pw//\\/\\\\}"
  pw="${pw//\"/\\\"}"
  (
    umask 077
    cat >"$file" <<EOF
[client]
host=$DB_HOST
port=$DB_PORT
user=$DB_USER
password="$pw"
EOF
  )
}

# aws s3 wrapper; S3_ENDPOINT_URL is needed for non-AWS providers (Hetzner, Wasabi, MinIO …).
aws_s3() {
  aws ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"} s3 "$@"
}

s3_uri() {
  printf 's3://%s/%s' "$S3_BUCKET" "${S3_PREFIX:+$S3_PREFIX/}"
}

# Serializes backup and restore runs so cron never backs up a half-restored site.
acquire_lock() {
  mkdir -p "$WORK_DIR"
  chmod 700 "$WORK_DIR"
  exec 9>"$WORK_DIR/typo3-backup.lock"
  flock -n 9 || die "Ein anderer Backup-/Restore-Lauf ist aktiv (Lock: $WORK_DIR/typo3-backup.lock)"
}
