# TYPO3 Backup & Restore

Sichert eine TYPO3-Installation (MariaDB-Datenbank plus `fileadmin/`, `uploads/`, `typo3conf/`
bzw. `config/`) verschlüsselt auf einen S3-kompatiblen Speicher und stellt sie bei Bedarf wieder her.
Klassische Installationen und Composer-Installationen werden automatisch erkannt.

**EN:** Bash scripts that back up a TYPO3 site (MariaDB dump + `fileadmin/`, `uploads/`, `typo3conf/`)
into a GPG-encrypted (AES256) archive on S3-compatible storage. `typo3-backup.sh` runs from cron,
`typo3-restore.sh` is run manually and restores database and/or directories after confirmation.
Classic and Composer-based installations are detected automatically.

## Ablauf

**Backup** (`typo3-backup.sh`, per Cronjob):

1. Datenbank-Dump mit `mariadb-dump --single-transaction` (konsistent, ohne Tabellen-Locks bei InnoDB)
2. Dump, Verzeichnisse und eine Liste der gesicherten Pfade (`manifest.txt`) werden in **ein**
   `tar.gz`-Archiv gepackt
3. Das Archiv wird mit GPG verschlüsselt (symmetrisch, AES256)
4. Upload der Datei `typo3-backup_JJJJMMTT-HHMMSS.tar.gz.gpg` samt `.sha256`-Prüfsumme nach S3
5. Lokale Zwischendateien werden immer gelöscht, auch im Fehlerfall

**Restore** (`typo3-restore.sh`, manuell):

1. Backup auswählen, herunterladen, Prüfsumme kontrollieren, entschlüsseln, Archiv testen
2. Sicherheitsabfrage (Eingabe `ja`)
3. Datenbank (außer bei `--files-only`): Die aktuelle Datenbank wird nach
   `WORK_DIR/pre-restore-<Zeitstempel>/` gesichert. Danach werden alle Tabellen gelöscht und der
   Dump wird eingespielt.
4. Verzeichnisse (außer bei `--db-only`): Die in `manifest.txt` aufgeführten Verzeichnisse werden
   in `<verzeichnis>.pre-restore-<Zeitstempel>` umbenannt. Danach werden sie aus dem Backup
   entpackt, mit Besitzer und Rechten.

Backup und Restore sperren sich gegenseitig (`flock`). So kann der Cronjob nie eine halb
wiederhergestellte Seite sichern.

## Voraussetzungen

Linux-Server mit `bash` ≥ 4.4, GNU `tar`, `gzip`, `gpg` ≥ 2.2, `flock` (util-linux),
`mariadb-dump`/`mariadb` (oder `mysqldump`/`mysql`) und AWS CLI v2.

```bash
apt install gnupg mariadb-client awscli
```

AWS CLI v2 installieren: <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>

Das Arbeitsverzeichnis (`WORK_DIR`) braucht freien Platz für etwa die doppelte Backup-Größe.

## Installation

```bash
git clone <repo> /opt/typo3-backup
cd /opt/typo3-backup
cp .env.example .env && chmod 600 .env
```

`.env` anpassen, dann die Passphrase anlegen:

```bash
install -d -m 700 /etc/typo3-backup
openssl rand -base64 48 > /etc/typo3-backup/passphrase
chmod 600 /etc/typo3-backup/passphrase
```

> **Wichtig:** Die Passphrase zusätzlich außerhalb des Servers aufbewahren, z. B. im Passwort-Manager.
> Ist der Server verloren, lassen sich die Backups ohne sie nicht wiederherstellen.

Erster manueller Testlauf:

```bash
/opt/typo3-backup/typo3-backup.sh
```

### Konfiguration

Alle Einstellungen stehen in `.env`, siehe [.env.example](.env.example). Eine andere Datei lässt
sich über die Umgebungsvariable `TYPO3_BACKUP_CONFIG` angeben.

| Variable | Bedeutung |
| --- | --- |
| `TYPO3_ROOT` | Klassisch: Document Root. Composer: Projektverzeichnis (enthält `public/`) |
| `BACKUP_PATHS` | Leer = automatische Erkennung (siehe unten), sonst eigene Pfadliste |
| `BACKUP_EXCLUDES` | Ausschlüsse (Standard: `fileadmin/_processed_ fileadmin/_temp_`) |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | MariaDB-Zugang |
| `GPG_PASSPHRASE_FILE` | Datei mit der Verschlüsselungs-Passphrase |
| `S3_BUCKET`, `S3_PREFIX`, `S3_ENDPOINT_URL` | Ziel im S3-Speicher; Endpoint nur für Anbieter außerhalb von AWS |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` | S3-Zugangsdaten |
| `WORK_DIR` | Lokales Arbeitsverzeichnis (Standard: `/var/tmp/typo3-backup`) |

### Automatische Erkennung der Installationsart

Ist `BACKUP_PATHS` leer, erkennt das Backup-Skript die Installationsart anhand von `TYPO3_ROOT`
(siehe [TYPO3-Dokumentation: Verzeichnisstruktur](https://docs.typo3.org/m/typo3/reference-coreapi/main/en-us/Administration/DirectoryStructure/Index.html)):

| Installationsart | Erkannt an | Gesicherte Verzeichnisse |
| --- | --- | --- |
| Composer, TYPO3 ab v12 | `config/system/settings.php` | `config/`, `public/fileadmin/` |
| Composer, TYPO3 bis v11 | `public/typo3conf/` | `public/typo3conf/`, `public/fileadmin/` |
| Klassisch | `typo3conf/` | `typo3conf/`, `fileadmin/` |

`uploads/` bzw. `public/uploads/` wird zusätzlich gesichert, wenn vorhanden. In neueren
TYPO3-Versionen gibt es das Verzeichnis meist nicht mehr.

Bei Composer-Installationen muss `TYPO3_ROOT` auf das **Projektverzeichnis** zeigen, nicht auf
`public/`. Andernfalls bricht das Skript mit einem Hinweis ab. Das Web-Verzeichnis muss `public`
heißen. Bei einem anderen Namen `BACKUP_PATHS` von Hand setzen. Code und Abhängigkeiten
(`composer.json`, `vendor/`, eigene Extensions im Projekt) werden nicht gesichert. Sie gehören
ins Git-Repository.

Mit gesetztem `BACKUP_PATHS` werden genau diese Pfade gesichert. Fehlt einer davon, bricht das
Backup ab.

### Weitere Hinweise

- `fileadmin/_processed_` wird bewusst nicht gesichert. Es enthält nur erzeugte Bildvarianten,
  und TYPO3 erzeugt fehlende Varianten beim nächsten Aufruf automatisch neu.
- Manche S3-kompatible Anbieter lehnen die CRC-Prüfsummen neuerer AWS-CLI-Versionen ab.
  Dann `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED` und
  `AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED` setzen
  ([AWS-Dokumentation](https://docs.aws.amazon.com/sdkref/latest/guide/feature-dataintegrity.html)).

## Cronjob

Beispiel: täglich um 02:30 Uhr, Ausgabe ins Logfile (`crontab -e` als root):

```cron
30 2 * * * /opt/typo3-backup/typo3-backup.sh >> /var/log/typo3-backup.log 2>&1
```

Das Skript meldet Fehler mit Exit-Code ≠ 0 und `[FEHLER]` im Log. Ist in der Crontab `MAILTO`
gesetzt und die Ausgabe nicht umgeleitet, verschickt cron die Ausgabe per E-Mail.

Log-Rotation, z. B. in `/etc/logrotate.d/typo3-backup`:

```
/var/log/typo3-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
```

### Aufbewahrung alter Backups

Die Skripte löschen keine alten Backups auf S3. Die Aufbewahrungsdauer am besten über eine
**Lifecycle-Regel** des Buckets festlegen, z. B. „Objekte unter `S3_PREFIX` nach 30 Tagen löschen“
([AWS-Dokumentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html),
bei anderen Anbietern in deren Oberfläche). Die S3-Zugangsdaten auf dem Server sollten nach
Möglichkeit keine Löschrechte haben. Dann kann ein Angreifer auf dem Server die Backups nicht entfernen.

## Wiederherstellung

Das Skript wird als root gestartet, damit Besitzer und Rechte der Dateien erhalten bleiben:

```bash
/opt/typo3-backup/typo3-restore.sh --list
```

```bash
/opt/typo3-backup/typo3-restore.sh
```

```bash
/opt/typo3-backup/typo3-restore.sh latest
```

```bash
/opt/typo3-backup/typo3-restore.sh typo3-backup_20260925-023000.tar.gz.gpg
```

Nur die Datenbank oder nur die Dateien wiederherstellen:

```bash
/opt/typo3-backup/typo3-restore.sh --db-only latest
```

```bash
/opt/typo3-backup/typo3-restore.sh --files-only latest
```

Ohne Backup-Angabe wird das Backup aus einer nummerierten Liste gewählt. Vor jeder Änderung fragt
das Skript nach einer Bestätigung. Wiederhergestellt werden genau die Verzeichnisse aus der
`manifest.txt` des Backups, unabhängig von der aktuellen Konfiguration. Bei Composer-Installationen
bleibt deshalb der Rest von `public/` (z. B. `index.php`, `_assets/`) unangetastet.

Nach der Wiederherstellung:

1. TYPO3-Caches leeren: *Admin Tools → Maintenance → Flush TYPO3 and PHP Cache* oder
   `typo3 cache:flush` ([TYPO3-Dokumentation](https://docs.typo3.org/m/typo3/reference-coreapi/main/en-us/ApiOverview/CachingFramework/Index.html))
2. Website prüfen
3. Danach die Sicherung des vorherigen Stands löschen (`*.pre-restore-<Zeitstempel>` in
   `TYPO3_ROOT` sowie `WORK_DIR/pre-restore-<Zeitstempel>/`). Das Skript zeigt die Pfade am Ende an.

**Wiederherstellung auf einem neuen Server:** Skripte installieren, `.env` und Passphrase-Datei
anlegen, leere Datenbank und Benutzer anlegen, dann `typo3-restore.sh` ausführen.

### Manuelle Wiederherstellung ohne Skript

```bash
gpg --decrypt typo3-backup_20260925-023000.tar.gz.gpg > backup.tar.gz
```

```bash
tar -xzpf backup.tar.gz
```

Das Archiv enthält `database.sql`, `manifest.txt` (Liste der gesicherten Pfade) sowie die
gesicherten Verzeichnisse.

## Tests

Ein Ende-zu-Ende-Test läuft in Docker mit MariaDB und SeaweedFS als S3-Ersatz. Er prüft:

- klassische und Composer-Installationen (bis v11 und ab v12), inklusive Fehlkonfigurationen
- Backup, Abbruch, vollständigen Restore sowie `--db-only` und `--files-only`
- Besitzer und Rechte der Dateien, Umlaute, das Entfernen neu angelegter Tabellen
- die Erkennung beschädigter Backups

```bash
./test/run.sh
```
