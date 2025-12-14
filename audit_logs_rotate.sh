#!/bin/bash
set -euo pipefail

# =========================
# CONFIG
# =========================
DB="gigtakafulcp_db"
TABLE="audit_logs"
DATE_COLUMN="created_at"

# Retention: keep last 1 day only
RETENTION_DAYS=1

DUMP_DIR="/data/mysql_dumps/audit_logs"
TMP_TABLE="${TABLE}_new"
OLD_TABLE="${TABLE}_old"

MYSQL="/usr/bin/mysql"
MYSQLDUMP="/usr/bin/mysqldump"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

# =========================
# PREP
# =========================
mkdir -p "$DUMP_DIR"

echo "[$(date)] Starting audit_logs maintenance"

# =========================
# STEP 1: DUMP TABLE
# =========================
echo "[$(date)] Dumping table"

$MYSQLDUMP \
  --single-transaction \
  --quick \
  --skip-lock-tables \
  "$DB" "$TABLE" \
  > "$DUMP_DIR/${TABLE}_${DATE}.sql"

gzip "$DUMP_DIR/${TABLE}_${DATE}.sql"

# =========================
# STEP 2: CREATE NEW TABLE
# =========================
echo "[$(date)] Creating new table"

$MYSQL "$DB" <<EOF
DROP TABLE IF EXISTS $TMP_TABLE;
CREATE TABLE $TMP_TABLE LIKE $TABLE;
EOF

# =========================
# STEP 3: COPY LAST 1 DAY DATA
# =========================
echo "[$(date)] Copying data from last ${RETENTION_DAYS} day(s)"

$MYSQL "$DB" <<EOF
INSERT INTO $TMP_TABLE
SELECT *
FROM $TABLE
WHERE $DATE_COLUMN >= NOW() - INTERVAL $RETENTION_DAYS DAY;
EOF

# =========================
# STEP 4: ATOMIC SWAP
# =========================
echo "[$(date)] Swapping tables"

$MYSQL "$DB" <<EOF
RENAME TABLE
  $TABLE TO $OLD_TABLE,
  $TMP_TABLE TO $TABLE;
EOF

# =========================
# STEP 5: DROP OLD TABLE
# =========================
echo "[$(date)] Dropping old table"

$MYSQL "$DB" <<EOF
DROP TABLE $OLD_TABLE;
EOF

# =========================
# STEP 6: DELETE DUMPS OLDER THAN 30 DAYS
# =========================
echo "[$(date)] Cleaning dumps older than 30 days"

find "$DUMP_DIR" -type f -name "*.sql.gz" -mtime +30 -delete

echo "[$(date)] Completed successfully"
