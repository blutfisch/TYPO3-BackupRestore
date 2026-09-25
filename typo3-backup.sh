#!/usr/bin/env bash
# TYPO3 backup: dumps the MariaDB database, archives the TYPO3 directories (fileadmin,
# uploads, configuration – auto-detected or from BACKUP_PATHS) together with the dump,
# encrypts the archive with GPG (AES256) and uploads it to S3.
# Runs unattended (cron); all output goes to stdout/stderr, exit code != 0 on failure.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

trap 'warn "Befehl fehlgeschlagen (Zeile $LINENO): $BASH_COMMAND"' ERR

load_config
require_cmds tar gzip gpg aws sha256sum flock find
detect_db_tools
acquire_lock

# Sets the global array "paths" (relative to TYPO3_ROOT). Without explicit BACKUP_PATHS the
# installation type is detected:
#   Composer mode, TYPO3 >= v12: config/ + public/fileadmin   (config/system/settings.php)
#   Composer mode, TYPO3 <= v11: public/typo3conf + public/fileadmin
#   Classic mode:                typo3conf/ + fileadmin/
# uploads/ only exists in older installations and is included when present.
resolve_backup_paths() {
  local p web=""
  if [[ -n "$BACKUP_PATHS" ]]; then
    read -ra paths <<<"$BACKUP_PATHS"
    for p in "${paths[@]}"; do
      [[ -e "$TYPO3_ROOT/$p" ]] || die "Zu sicherndes Verzeichnis fehlt: $TYPO3_ROOT/$p (BACKUP_PATHS prüfen)"
    done
    return
  fi

  if [[ -f "$TYPO3_ROOT/../config/system/settings.php" && -d "$TYPO3_ROOT/fileadmin" ]]; then
    die "TYPO3_ROOT zeigt auf das Web-Verzeichnis einer Composer-Installation – bitte das Projektverzeichnis $(cd "$TYPO3_ROOT/.." && pwd) eintragen"
  elif [[ -f "$TYPO3_ROOT/config/system/settings.php" ]]; then
    log "Erkannt: TYPO3 im Composer-Modus (ab v12)"
    web="public/"
    paths=(config)
  elif [[ -d "$TYPO3_ROOT/public/typo3conf" ]]; then
    log "Erkannt: TYPO3 im Composer-Modus (bis v11)"
    web="public/"
    paths=(public/typo3conf)
  elif [[ -d "$TYPO3_ROOT/typo3conf" ]]; then
    log "Erkannt: klassische TYPO3-Installation"
    paths=(typo3conf)
  else
    die "Keine TYPO3-Installation in $TYPO3_ROOT erkannt (weder typo3conf/ noch config/system/settings.php) – TYPO3_ROOT prüfen oder BACKUP_PATHS setzen"
  fi

  [[ -d "$TYPO3_ROOT/${web}fileadmin" ]] || die "Verzeichnis fehlt: $TYPO3_ROOT/${web}fileadmin"
  paths+=("${web}fileadmin")
  if [[ -d "$TYPO3_ROOT/${web}uploads" ]]; then
    paths+=("${web}uploads")
  fi
}

resolve_backup_paths

TMP="$(mktemp -d "$WORK_DIR/backup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

NAME="typo3-backup_$(date '+%Y%m%d-%H%M%S').tar.gz.gpg"
DEST="$(s3_uri)"
log "Starte TYPO3-Backup: $NAME"

# 1. Database dump
log "Erstelle Datenbank-Dump von '$DB_NAME'"
write_db_defaults "$TMP/client.cnf"
"$DB_DUMP" --defaults-extra-file="$TMP/client.cnf" \
  --single-transaction --quick --no-tablespaces --hex-blob \
  --default-character-set=utf8mb4 \
  "$DB_NAME" >"$TMP/database.sql"
rm -f "$TMP/client.cnf"

# 2. Archive dump + directories. manifest.txt lists the backed-up paths for the restore.
printf '%s\n' "${paths[@]}" >"$TMP/manifest.txt"
log "Erstelle Archiv aus: database.sql ${paths[*]}"
excludes=()
for e in $BACKUP_EXCLUDES; do excludes+=("--exclude=$e"); done
rc=0
tar -czf "$TMP/archive.tar.gz" "${excludes[@]}" \
  -C "$TMP" database.sql manifest.txt \
  -C "$TYPO3_ROOT" "${paths[@]}" || rc=$?
# GNU tar exit code 1 = files changed while being read (live system) – archive is still usable.
if ((rc == 1)); then
  warn "Einige Dateien haben sich während der Archivierung geändert (tar Exit-Code 1)"
elif ((rc > 1)); then
  die "Archivierung fehlgeschlagen (tar Exit-Code $rc)"
fi
rm -f "$TMP/database.sql" "$TMP/manifest.txt"

# 3. Encrypt
log "Verschlüssele Archiv (GPG, AES256)"
gpg --batch --yes --quiet --no-symkey-cache --pinentry-mode loopback \
  --passphrase-file "$GPG_PASSPHRASE_FILE" \
  --symmetric --cipher-algo AES256 --compress-algo none \
  --output "$TMP/$NAME" "$TMP/archive.tar.gz"
rm -f "$TMP/archive.tar.gz"
(cd "$TMP" && sha256sum "$NAME" >"$NAME.sha256")

# 4. Upload – checksum last, so its presence marks a complete upload
log "Übertrage $(du -h "$TMP/$NAME" | cut -f1) nach $DEST"
aws_s3 cp --only-show-errors "$TMP/$NAME" "$DEST$NAME"
aws_s3 cp --only-show-errors "$TMP/$NAME.sha256" "$DEST$NAME.sha256"

log "Backup erfolgreich abgeschlossen: $DEST$NAME"
