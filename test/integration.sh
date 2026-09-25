#!/usr/bin/env bash
# End-to-end test, executed inside the runner container (see compose.yaml).
set -euo pipefail

APP=/opt/typo3-backup
S3=http://s3:8333
export TYPO3_BACKUP_CONFIG=/etc/typo3-backup/test.env
export AWS_ACCESS_KEY_ID=testkey AWS_SECRET_ACCESS_KEY=testsecret123 AWS_DEFAULT_REGION=us-east-1

fail() { echo "TEST FEHLGESCHLAGEN: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
sql()  { mariadb -h db -u root -proot-secret --default-character-set=utf8mb4 -N -B typo3 -e "$1"; }

# write_conf <TYPO3_ROOT> <S3_PREFIX> [extra config lines]
write_conf() {
  cat >"$TYPO3_BACKUP_CONFIG" <<CONF
TYPO3_ROOT=$1
DB_HOST=db
DB_NAME=typo3
DB_USER=typo3
DB_PASSWORD='p@ss"w\\ord#1'
GPG_PASSPHRASE_FILE=/etc/typo3-backup/passphrase
S3_BUCKET=backups
S3_PREFIX=/$2/
S3_ENDPOINT_URL=$S3
AWS_ACCESS_KEY_ID=testkey
AWS_SECRET_ACCESS_KEY=testsecret123
AWS_DEFAULT_REGION=us-east-1
WORK_DIR=/var/tmp/typo3-backup
${3:-}
CONF
  chmod 600 "$TYPO3_BACKUP_CONFIG"
}

# Simulate cron: minimal environment
backup() { env -i HOME=/root PATH=/usr/bin:/bin TYPO3_BACKUP_CONFIG="$TYPO3_BACKUP_CONFIG" "$APP/typo3-backup.sh"; }
# Pre-restore copies are named by the second – keep restores apart
restore() { sleep 1; echo ja | "$APP/typo3-restore.sh" "$@"; }
body() { sql "SELECT bodytext FROM tt_content WHERE uid=1"; }

mkdir -p /etc/typo3-backup
echo 'test-passphrase' >/etc/typo3-backup/passphrase
chmod 600 /etc/typo3-backup/passphrase
sql "CREATE TABLE tt_content (uid INT PRIMARY KEY, bodytext TEXT) DEFAULT CHARSET=utf8mb4;
     INSERT INTO tt_content VALUES (1, 'Grüße aus Köln'), (2, 'zweiter');"
for _ in $(seq 30); do aws --endpoint-url "$S3" s3 mb s3://backups >/dev/null 2>&1 && break; sleep 1; done

# =============================================================================
echo "### Klassische Installation"
ROOT=/srv/classic
mkdir -p "$ROOT"/fileadmin/{user_upload,_processed_} "$ROOT"/uploads/pics "$ROOT"/typo3conf/ext/site
echo 'original' >"$ROOT/fileadmin/user_upload/a.txt"
echo 'derived' >"$ROOT/fileadmin/_processed_/thumb.jpg"
echo 'pic' >"$ROOT/uploads/pics/p.jpg"
echo '<?php return [];' >"$ROOT/typo3conf/LocalConfiguration.php"
chown 33:33 "$ROOT/fileadmin/user_upload/a.txt"
chmod 640 "$ROOT/fileadmin/user_upload/a.txt"
write_conf "$ROOT" typo3/classic

backup | tee /tmp/backup.log
grep -q 'Erkannt: klassische TYPO3-Installation' /tmp/backup.log || fail "Installationsart nicht erkannt"
grep -q 'database.sql typo3conf fileadmin uploads' /tmp/backup.log || fail "falsche Pfade"
[[ "$("$APP/typo3-restore.sh" --list | wc -l)" == 1 ]] || fail "genau ein Backup erwartet"
aws --endpoint-url "$S3" s3 ls s3://backups/typo3/classic/ | grep -q '\.sha256$' || fail "sha256 fehlt"
ok "Backup hochgeladen"

mutate() {
  rm -f "$ROOT/fileadmin/user_upload/a.txt"
  echo 'new' >"$ROOT/fileadmin/new.txt"
  sql "UPDATE tt_content SET bodytext='kaputt' WHERE uid=1; CREATE TABLE IF NOT EXISTS tx_new (id INT);"
}
mutate

echo nein | "$APP/typo3-restore.sh" latest && fail "Abbruch sollte Exit-Code != 0 liefern"
[[ -e "$ROOT/fileadmin/new.txt" && "$(body)" == kaputt ]] || fail "Abbruch hat trotzdem Daten verändert"
ok "Abbruch ohne Änderungen"

"$APP/typo3-restore.sh" --db-only --files-only latest && fail "--db-only mit --files-only sollte scheitern"
ok "--db-only und --files-only schließen sich aus"

restore --db-only latest
[[ "$(body)" == 'Grüße aus Köln' ]] || fail "--db-only: DB nicht wiederhergestellt"
[[ -z "$(sql "SHOW TABLES LIKE 'tx_new'")" ]] || fail "--db-only: tx_new sollte entfernt sein"
[[ -e "$ROOT/fileadmin/new.txt" ]] || fail "--db-only hat Dateien verändert"
compgen -G "$ROOT/*.pre-restore-*" >/dev/null && fail "--db-only hat Verzeichnisse verschoben"
ok "--db-only"

mutate
restore --files-only latest
[[ "$(cat "$ROOT/fileadmin/user_upload/a.txt")" == original ]] || fail "--files-only: a.txt fehlt"
[[ "$(body)" == kaputt ]] || fail "--files-only hat die DB verändert"
ok "--files-only"

mutate
restore latest
[[ "$(cat "$ROOT/fileadmin/user_upload/a.txt")" == original ]] || fail "a.txt nicht wiederhergestellt"
[[ "$(stat -c '%u:%g %a' "$ROOT/fileadmin/user_upload/a.txt")" == "33:33 640" ]] || fail "Besitzer/Rechte nicht erhalten"
[[ ! -e "$ROOT/fileadmin/new.txt" ]] || fail "new.txt sollte fehlen"
[[ ! -e "$ROOT/fileadmin/_processed_" ]] || fail "_processed_ hätte ausgeschlossen sein sollen"
[[ -f "$ROOT/uploads/pics/p.jpg" && -f "$ROOT/typo3conf/LocalConfiguration.php" ]] || fail "uploads/typo3conf fehlen"
[[ "$(body)" == 'Grüße aus Köln' ]] || fail "DB-Inhalt/Umlaute falsch"
[[ -z "$(sql "SHOW TABLES LIKE 'tx_new'")" ]] || fail "tx_new sollte entfernt sein"
compgen -G "/var/tmp/typo3-backup/pre-restore-*/database.sql.gz" >/dev/null || fail "Sicherheits-Dump fehlt"
ok "Vollständiger Restore"

name="$("$APP/typo3-restore.sh" --list | tail -1)"
printf '%064d  %s\n' 0 "$name" >/tmp/bad.sha256
aws --endpoint-url "$S3" s3 cp --quiet /tmp/bad.sha256 "s3://backups/typo3/classic/$name.sha256"
restore "$name" && fail "falsche Prüfsumme wurde akzeptiert"
ok "Beschädigtes Backup abgelehnt"

# =============================================================================
echo "### Composer-Installation (TYPO3 v12+)"
ROOT=/srv/composer
mkdir -p "$ROOT"/config/{system,sites/main} "$ROOT"/public/{_assets,fileadmin/user_upload,fileadmin/_processed_}
echo '<?php return [];' >"$ROOT/config/system/settings.php"
echo 'base: /' >"$ROOT/config/sites/main/config.yaml"
echo 'index' >"$ROOT/public/index.php"
echo 'asset' >"$ROOT/public/_assets/app.css"
echo 'original' >"$ROOT/public/fileadmin/user_upload/b.txt"
echo 'derived' >"$ROOT/public/fileadmin/_processed_/t.jpg"

write_conf "$ROOT/public" typo3/composer
backup && fail "TYPO3_ROOT auf public/ hätte abgelehnt werden müssen"
ok "Falsches TYPO3_ROOT (public/) abgelehnt"

write_conf "$ROOT" typo3/composer "BACKUP_PATHS='public/fileadmin public/uploads'"
backup && fail "fehlendes Verzeichnis in BACKUP_PATHS hätte abgelehnt werden müssen"
ok "Fehlendes Verzeichnis in BACKUP_PATHS abgelehnt"

write_conf "$ROOT" typo3/composer
backup | tee /tmp/backup.log
grep -q 'Composer-Modus (ab v12)' /tmp/backup.log || fail "Composer-Modus nicht erkannt"
grep -q 'database.sql config public/fileadmin$' /tmp/backup.log || fail "falsche Pfade"
ok "Composer-Backup"

rm "$ROOT/public/fileadmin/user_upload/b.txt"
echo 'base: /kaputt' >"$ROOT/config/sites/main/config.yaml"
echo 'index-neu' >"$ROOT/public/index.php"
restore --files-only latest
[[ "$(cat "$ROOT/public/fileadmin/user_upload/b.txt")" == original ]] || fail "b.txt nicht wiederhergestellt"
[[ "$(cat "$ROOT/config/sites/main/config.yaml")" == 'base: /' ]] || fail "config/ nicht wiederhergestellt"
[[ "$(cat "$ROOT/public/index.php")" == index-neu ]] || fail "public/ wurde komplett ersetzt"
[[ -f "$ROOT/public/_assets/app.css" ]] || fail "public/_assets verloren"
[[ ! -e "$ROOT/public/fileadmin/_processed_" ]] || fail "_processed_ hätte ausgeschlossen sein sollen"
for d in public/fileadmin config; do
  compgen -G "$ROOT/$d.pre-restore-*" >/dev/null || fail "vorheriger Stand von $d fehlt"
done
ok "Composer-Restore stellt nur config/ und public/fileadmin/ wieder her"

# =============================================================================
echo "### Composer-Installation (TYPO3 bis v11)"
ROOT=/srv/composer11
mkdir -p "$ROOT"/public/{typo3conf,fileadmin,uploads}
echo '<?php return [];' >"$ROOT/public/typo3conf/LocalConfiguration.php"
write_conf "$ROOT" typo3/composer11
backup | tee /tmp/backup.log
grep -q 'Composer-Modus (bis v11)' /tmp/backup.log || fail "Composer-Modus v11 nicht erkannt"
grep -q 'database.sql public/typo3conf public/fileadmin public/uploads$' /tmp/backup.log || fail "falsche Pfade"
ok "Composer-v11-Backup"

echo "ALLE TESTS BESTANDEN"
