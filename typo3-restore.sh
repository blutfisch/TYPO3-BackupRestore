#!/usr/bin/env bash
# TYPO3 restore: downloads a backup from S3, verifies and decrypts it, replaces the
# database contents and/or the backed-up directories. Meant to be started manually.
#
# Before overwriting, the current state is kept:
#   - directories are renamed to <dir>.pre-restore-<timestamp> inside TYPO3_ROOT
#   - the current database is dumped to WORK_DIR/pre-restore-<timestamp>/
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Verwendung: $(basename "$0") [--db-only | --files-only] [latest | <backup-name>]
       $(basename "$0") --list

  --list          Verfügbare Backups im S3-Speicher auflisten
  --db-only       Nur die Datenbank wiederherstellen
  --files-only    Nur die Verzeichnisse wiederherstellen
  latest          Neuestes Backup wiederherstellen
  <backup-name>   Bestimmtes Backup wiederherstellen, z. B. typo3-backup_20260925-023000.tar.gz.gpg
  (ohne Backup)   Backup interaktiv aus einer Liste auswählen
EOF
}

list_backups() {
  local listing rc=0
  listing="$(aws_s3 ls "$(s3_uri)")" || rc=$?
  # Exit code 1 = nothing found under the prefix; >1 = credentials, network or service error.
  ((rc <= 1)) || die "S3-Speicher nicht erreichbar: $(s3_uri) (aws Exit-Code $rc)"
  awk '{print $4}' <<<"$listing" | { grep -E "$BACKUP_NAME_REGEX" || true; } | sort
}

# --- Arguments ------------------------------------------------------------------
LIST=0 RESTORE_DB=1 RESTORE_FILES=1 TARGET=""
while (($# > 0)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --list) LIST=1 ;;
    --db-only) RESTORE_FILES=0 ;;
    --files-only) RESTORE_DB=0 ;;
    -*) usage >&2; die "Unbekannte Option: $1" ;;
    *)
      [[ -z "$TARGET" ]] || die "Nur ein Backup angeben"
      TARGET="$1"
      ;;
  esac
  shift
done
((RESTORE_DB || RESTORE_FILES)) || die "--db-only und --files-only schließen sich aus"

trap 'warn "Befehl fehlgeschlagen (Zeile $LINENO): $BASH_COMMAND"' ERR

load_config
require_cmds tar gzip gpg aws sha256sum flock find awk paste
detect_db_tools

backup_list="$(list_backups)"
mapfile -t backups < <(printf '%s' "$backup_list" | sed '/^$/d')
((${#backups[@]} > 0)) || die "Keine Backups gefunden unter $(s3_uri)"

if ((LIST)); then
  printf '%s\n' "${backups[@]}"
  exit 0
fi

# --- Select backup --------------------------------------------------------------
case "$TARGET" in
  latest) NAME="${backups[-1]}" ;;
  "")
    echo "Verfügbare Backups:"
    for i in "${!backups[@]}"; do printf '  %3d) %s\n' "$((i + 1))" "${backups[$i]}"; done
    read -rp "Nummer des Backups: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#backups[@]})); then
      die "Ungültige Auswahl: $choice"
    fi
    NAME="${backups[$((choice - 1))]}"
    ;;
  *)
    NAME="$TARGET"
    [[ "$NAME" =~ $BACKUP_NAME_REGEX ]] || die "Ungültiger Backup-Name: $NAME"
    printf '%s\n' "${backups[@]}" | grep -qxF "$NAME" || die "Backup nicht gefunden: $NAME"
    ;;
esac

acquire_lock
TMP="$(mktemp -d "$WORK_DIR/restore.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
STAMP="$(date '+%Y%m%d-%H%M%S')"
SAFE_DIR="$WORK_DIR/pre-restore-$STAMP"

# --- Download, verify, decrypt ----------------------------------------------------
log "Lade $NAME herunter"
aws_s3 cp --only-show-errors "$(s3_uri)$NAME" "$TMP/$NAME"
aws_s3 cp --only-show-errors "$(s3_uri)$NAME.sha256" "$TMP/$NAME.sha256"
(cd "$TMP" && sha256sum --quiet -c "$NAME.sha256") || die "Prüfsumme stimmt nicht – Backup beschädigt"

log "Entschlüssele Backup"
gpg --batch --yes --quiet --no-symkey-cache --pinentry-mode loopback \
  --passphrase-file "$GPG_PASSPHRASE_FILE" \
  --decrypt --output "$TMP/archive.tar.gz" "$TMP/$NAME" \
  || die "Entschlüsselung fehlgeschlagen (falsche Passphrase?)"
rm -f "$TMP/$NAME"

tar -tzf "$TMP/archive.tar.gz" >"$TMP/contents" || die "Archiv ist beschädigt"
grep -qx 'database.sql' "$TMP/contents" || die "Archiv enthält keinen Datenbank-Dump (database.sql)"
grep -qx 'manifest.txt' "$TMP/contents" \
  || die "Archiv enthält keine manifest.txt (mit älterer Skriptversion erstellt) – bitte manuell wiederherstellen, siehe README"

# Restore exactly the paths listed in the manifest, independent of the current configuration.
tar -xzf "$TMP/archive.tar.gz" -C "$TMP" manifest.txt
mapfile -t paths < <(sed '/^$/d' "$TMP/manifest.txt")
((${#paths[@]} > 0)) || die "manifest.txt ist leer"
for p in "${paths[@]}"; do
  [[ "$p" != /* && "/$p/" != */../* ]] || die "Unzulässiger Pfad im Manifest: $p"
  grep -qxF -e "$p" -e "$p/" "$TMP/contents" || die "Pfad aus dem Manifest fehlt im Archiv: $p"
  # mv onto an existing directory would move INTO it instead of renaming
  [[ ! -e "$TYPO3_ROOT/$p.pre-restore-$STAMP" ]] || die "Existiert bereits: $TYPO3_ROOT/$p.pre-restore-$STAMP"
done
[[ ! -e "$SAFE_DIR" ]] || die "Existiert bereits: $SAFE_DIR"

# --- Confirmation -----------------------------------------------------------------
echo
echo "ACHTUNG: Die folgenden Daten werden durch das Backup ersetzt:"
echo "  Backup:        $NAME"
if ((RESTORE_DB)); then
  echo "  Datenbank:     $DB_NAME auf $DB_HOST:$DB_PORT (alle Tabellen werden gelöscht)"
fi
if ((RESTORE_FILES)); then
  echo "  Verzeichnisse: ${paths[*]/#/$TYPO3_ROOT/}"
fi
echo
echo "Der aktuelle Stand wird vorher gesichert:"
if ((RESTORE_DB)); then echo "  Datenbank     → $SAFE_DIR/database.sql.gz"; fi
if ((RESTORE_FILES)); then echo "  Verzeichnisse → jeweils *.pre-restore-$STAMP"; fi
echo
read -rp "Zum Fortfahren 'ja' eingeben: " answer
[[ "$answer" == "ja" ]] || die "Wiederherstellung abgebrochen"

# --- Database -----------------------------------------------------------------------
if ((RESTORE_DB)); then
  mkdir -p "$SAFE_DIR"
  write_db_defaults "$TMP/client.cnf"
  log "Sichere aktuelle Datenbank nach $SAFE_DIR/database.sql.gz"
  "$DB_DUMP" --defaults-extra-file="$TMP/client.cnf" \
    --single-transaction --quick --no-tablespaces --hex-blob \
    --default-character-set=utf8mb4 \
    "$DB_NAME" | gzip >"$SAFE_DIR/database.sql.gz"

  # Drop all tables so tables created after the backup do not survive, then import
  log "Stelle Datenbank '$DB_NAME' wieder her"
  read -r -d '' list_tables_sql <<'SQL' || true
SELECT CONCAT('`', REPLACE(table_name, '`', '``'), '`')
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
SQL
  tables="$("$DB_CLIENT" --defaults-extra-file="$TMP/client.cnf" -N -B -e "$list_tables_sql" "$DB_NAME" | paste -sd, -)"
  if [[ -n "$tables" ]]; then
    "$DB_CLIENT" --defaults-extra-file="$TMP/client.cnf" \
      -e "SET FOREIGN_KEY_CHECKS=0; DROP TABLE $tables;" "$DB_NAME"
  fi
  tar -xzf "$TMP/archive.tar.gz" -C "$TMP" database.sql
  "$DB_CLIENT" --defaults-extra-file="$TMP/client.cnf" --default-character-set=utf8mb4 \
    "$DB_NAME" <"$TMP/database.sql"
  rm -f "$TMP/database.sql" "$TMP/client.cnf"
fi

# --- Files: move current directories aside, then extract -------------------------------
if ((RESTORE_FILES)); then
  for p in "${paths[@]}"; do
    if [[ -e "$TYPO3_ROOT/$p" ]]; then
      log "Verschiebe $TYPO3_ROOT/$p nach $TYPO3_ROOT/$p.pre-restore-$STAMP"
      mv "$TYPO3_ROOT/$p" "$TYPO3_ROOT/$p.pre-restore-$STAMP"
    fi
  done
  log "Entpacke Verzeichnisse nach $TYPO3_ROOT"
  tar -xzpf "$TMP/archive.tar.gz" -C "$TYPO3_ROOT" "${paths[@]}"
fi

echo
log "Wiederherstellung abgeschlossen: $NAME"
echo
echo "Nächste Schritte:"
echo "  1. TYPO3-Caches leeren (Admin Tools > Maintenance > Flush TYPO3 and PHP Cache"
echo "     oder CLI: typo3 cache:flush)."
echo "  2. Website prüfen."
echo "  3. Danach die Sicherung des vorherigen Stands entfernen:"
if ((RESTORE_FILES)); then
  for p in "${paths[@]}"; do
    if [[ -e "$TYPO3_ROOT/$p.pre-restore-$STAMP" ]]; then echo "       $TYPO3_ROOT/$p.pre-restore-$STAMP"; fi
  done
fi
if ((RESTORE_DB)); then echo "       $SAFE_DIR"; fi
