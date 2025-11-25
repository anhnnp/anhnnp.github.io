#!/bin/bash

########################################
# WordPress Multi Store Backup Script
# - Backup files + MySQL for multiple domains
# - Read DB config from wp-config.php
# - Exclude cache/backup dirs from tar
# - Upload to S3 via aws-cli
# - Upload to Google Drive via rclone
# - Optional incremental backup via rclone sync
# - Cleanup old backups on local + S3 + GDrive
# - Optional Telegram notification (error-only / full)
########################################


# Đảm bảo PATH có ~/bin (aws, rclone, pigz ...) khi chạy từ cron
export PATH="$HOME/bin:$PATH"

# Load optional config file (same dir as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup_config.env"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

### ========== BASIC CONFIG ==========

: "${BASE_DIR:="$HOME"}"

DOMAINS_BASE="$BASE_DIR/domains"
BACKUP_BASE="$BASE_DIR/backups"
LOG_DIR="$BASE_DIR/logs"

# Số ngày giữ backup (local + remote)
: "${RETENTION_DAYS:=7}"

# Số ngày giữ log
: "${LOG_RETENTION_DAYS:=30}"

# Bật/tắt upload
: "${ENABLE_S3:=true}"
: "${ENABLE_GDRIVE:=true}"

### ========== S3 CONFIG (AWS CLI) ==========

# Tên bucket S3 (VD: sites-backups)
: "${AWS_S3_BUCKET:="your-s3-bucket-name"}"
# Prefix/path trong bucket (VD: wp-backups)
: "${AWS_S3_PREFIX:="your-backup-prefix"}"
# Storage class (STANDARD, STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING,
# GLACIER_IR, GLACIER, DEEP_ARCHIVE)
# -> Glacier Deep Archive = DEEP_ARCHIVE (rẻ nhất)
: "${AWS_S3_STORAGE_CLASS:=STANDARD}"

### ========== RCLONE GOOGLE DRIVE CONFIG ==========

# Tên remote trong rclone (VD: gdrive)
: "${RCLONE_REMOTE_GDRIVE:=gdrive}"
# Thư mục root gốc trong Google Drive (VD: wp-backups)
: "${RCLONE_GDRIVE_PATH:="your-backup-prefix"}"

### ========== OPTIONAL INCREMENTAL BACKUP (RCLONE SYNC) ==========

# Nếu muốn backup incremental (file-level) toàn bộ DOMAINS_BASE lên 1 remote rclone
# Ví dụ: INCREMENTAL_REMOTE="s3backup:wp-incremental" hoặc "gdrive:wp-incremental"
: "${ENABLE_INCREMENTAL:=false}"
: "${INCREMENTAL_REMOTE:=}"
: "${INCREMENTAL_SOURCE:="$DOMAINS_BASE"}"

### ========== TELEGRAM NOTIFY CONFIG ==========

: "${ENABLE_TELEGRAM:=true}"
: "${TELEGRAM_BOT_TOKEN:="YOUR-TELEGRAM-BOT-TOKEN"}"
: "${TELEGRAM_CHAT_ID:="YOUR-GROUP-CHAT-ID"}"

# Telegram notify mode:
#   error   – chỉ gửi khi có lỗi (backup/upload/retention/incremental)
#   full    – luôn gửi summary (kể cả OK)
#   off     – không gửi notify
: "${TELEGRAM_MODE:=error}"

### ========== STORE CONFIG (DANH SÁCH DOMAIN) ==========

# Mỗi phần tử là 1 domain store (thư mục code nằm trong /domains/<domain>/public_html)
if [ ${#STORES[@]} -eq 0 ]; then
  STORES=(
    # "domain-1.com"
    # "domain-2.com"
    # thêm các domain-store khác ở đây...
  )
fi

### ========== EXCLUDED FOLDERS IN FILE BACKUP ==========

# Tar sẽ exclude mọi path có chứa các chuỗi này (--exclude=*pattern*)
if [ ${#EXCLUDED_DIR_PATTERNS[@]} -eq 0 ]; then
  EXCLUDED_DIR_PATTERNS=(
    "aiowps_backups"
    "wp-cloudflare-super-page-cache"
    "litespeed"
    # "wp-admin"
  )
fi

########################################
# INTERNALS - DO NOT TOUCH IF UNSURE
########################################

set -o pipefail

mkdir -p "$BACKUP_BASE" "$LOG_DIR"

DATE_STR=$(date +%F)
TIME_STR=$(date +%F_%H-%M-%S)
TODAY_BACKUP_DIR="$BACKUP_BASE/$DATE_STR"
mkdir -p "$TODAY_BACKUP_DIR"

LOG_FILE="$LOG_DIR/backup_${TIME_STR}.log"

log() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | tee -a "$LOG_FILE"
}

### ========== LOCK FILE: CHỐNG CHẠY TRÙNG ==========

LOCK_FILE="/tmp/wp_backup_all_stores.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another backup_all_stores.sh is already running. Exit."
  exit 1
fi

log "========== START BACKUP (DATE: $DATE_STR) =========="
log "Backup directory: $TODAY_BACKUP_DIR"
log "Log file: $LOG_FILE"

# Disk usage before backup
DISK_USED=$(df -h "$BASE_DIR" | awk 'NR==2{print $5" used ("$3" / "$2")"}')
log "Disk usage for $BASE_DIR: $DISK_USED"

### ========== CHECK BINARIES ==========

# PHP CLI để đọc wp-config.php
if ! command -v php >/dev/null 2>&1; then
  log "ERROR: php CLI not found. Cannot read DB config from wp-config.php. Abort."
  exit 1
fi

if [ "$ENABLE_S3" = true ]; then
  if ! command -v aws >/dev/null 2>&1; then
    log "WARNING: aws CLI not found in PATH, disabling S3 upload."
    ENABLE_S3=false
  else
    log "aws CLI OK, S3 upload enabled."
  fi
fi

if [ "$ENABLE_GDRIVE" = true ] || [ "$ENABLE_INCREMENTAL" = true ]; then
  if ! command -v rclone >/dev/null 2>&1; then
    log "WARNING: rclone not found in PATH, disabling Google Drive & incremental upload."
    ENABLE_GDRIVE=false
    ENABLE_INCREMENTAL=false
  else
    log "rclone OK."
  fi
fi

if [ "$ENABLE_TELEGRAM" = true ]; then
  if ! command -v curl >/dev/null 2>&1; then
    log "WARNING: curl not found, disabling Telegram notifications."
    ENABLE_TELEGRAM=false
  fi
fi

# Chọn compressor: pigz (nếu có) hoặc gzip
COMPRESS_CMD="gzip"
TAR_COMPRESS_OPT=("-z")  # mặc định gzip

if command -v pigz >/dev/null 2>&1; then
  COMPRESS_CMD="pigz"
  TAR_COMPRESS_OPT=("--use-compress-program=pigz")
  log "pigz found – using multi-core compression."
else
  log "pigz not found – using gzip."
fi

### ========== TELEGRAM HELPER ==========

send_telegram() {
  local text="$1"
  if [ "$ENABLE_TELEGRAM" != true ]; then
    return 0
  fi
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "WARNING: Telegram bot token or chat id not set. Skip Telegram."
    return 1
  fi
  local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
  curl -s -X POST "$api_url" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$text" >/dev/null 2>&1
}

### ========== HELPER: GET CONSTANT FROM wp-config.php ==========

get_wp_config_value() {
  local config_file="$1"
  local const_name="$2"
  php -r "include '$config_file'; echo defined('$const_name') ? constant('$const_name') : '';" 2>/dev/null
}

### ========== BUILD TAR EXCLUDE ARGS ==========

TAR_EXCLUDES=()
if [ ${#EXCLUDED_DIR_PATTERNS[@]} -gt 0 ]; then
  for pattern in "${EXCLUDED_DIR_PATTERNS[@]}"; do
    TAR_EXCLUDES+=( "--exclude=*${pattern}*" )
  done
fi

### ========== STATUS FLAGS ==========

S3_UPLOAD_STATUS="disabled"
GDRIVE_UPLOAD_STATUS="disabled"
S3_RETENTION_STATUS="disabled"
GDRIVE_RETENTION_STATUS="disabled"
INCREMENTAL_STATUS="disabled"
BACKUP_STATUS="OK"

S3_TOTAL_SIZE="N/A"
GDRIVE_TOTAL_SIZE="N/A"

### ========== BACKUP LOOP FOR EACH DOMAIN ==========

for DOMAIN_NAME in "${STORES[@]}"; do
  STORE_KEY="${DOMAIN_NAME//./_}"

  SRC_PATH="$DOMAINS_BASE/$DOMAIN_NAME/public_html"
  STORE_BACKUP_DIR="$TODAY_BACKUP_DIR/$STORE_KEY"
  mkdir -p "$STORE_BACKUP_DIR"

  log "--- Store: $STORE_KEY (domain: $DOMAIN_NAME) ---"
  log "Source path: $SRC_PATH"

  if [ ! -d "$SRC_PATH" ]; then
    log "WARNING: Source path $SRC_PATH does not exist. Skipping store."
    BACKUP_STATUS="WARN"
    continue
  fi

  WP_CONFIG="$SRC_PATH/wp-config.php"
  if [ ! -f "$WP_CONFIG" ]; then
    log "ERROR: wp-config.php not found at $WP_CONFIG. Skipping DB backup for $STORE_KEY."
    DB_NAME=""
    BACKUP_STATUS="WARN"
  else
    DB_NAME=$(get_wp_config_value "$WP_CONFIG" "DB_NAME")
    DB_USER=$(get_wp_config_value "$WP_CONFIG" "DB_USER")
    DB_PASS=$(get_wp_config_value "$WP_CONFIG" "DB_PASSWORD")
    DB_HOST=$(get_wp_config_value "$WP_CONFIG" "DB_HOST")
    [ -z "$DB_HOST" ] && DB_HOST="localhost"

    log "DB config from wp-config.php:"
    log "  DB_NAME=$DB_NAME"
    log "  DB_USER=$DB_USER"
    log "  DB_HOST=$DB_HOST"
  fi

  ### ----- DB BACKUP -----
  if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
    DB_BACKUP_FILE="$STORE_BACKUP_DIR/db_${STORE_KEY}_${DATE_STR}.sql.gz"
    log "Backing up DB to: $DB_BACKUP_FILE"

    if mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>>"$LOG_FILE" | $COMPRESS_CMD > "$DB_BACKUP_FILE"; then
      log "DB backup OK for $STORE_KEY"
    else
      log "ERROR: DB backup FAILED for $STORE_KEY, removing partial file."
      rm -f "$DB_BACKUP_FILE"
      BACKUP_STATUS="ERROR"
    fi
  else
    log "WARNING: Missing DB config for $STORE_KEY. Skipping DB backup."
    BACKUP_STATUS="WARN"
  fi

  ### ----- FILES BACKUP -----
  FILES_BACKUP_FILE="$STORE_BACKUP_DIR/files_${STORE_KEY}_${DATE_STR}.tar.gz"
  log "Backing up files to: $FILES_BACKUP_FILE"
  log "Excluded patterns: ${EXCLUDED_DIR_PATTERNS[*]}"

  tar "${TAR_EXCLUDES[@]}" "${TAR_COMPRESS_OPT[@]}" -cf "$FILES_BACKUP_FILE" -C "$SRC_PATH" . 2>>"$LOG_FILE"
  TAR_EXIT=$?

  if [ $TAR_EXIT -eq 0 ] || [ $TAR_EXIT -eq 1 ]; then
    if [ $TAR_EXIT -eq 1 ]; then
      log "Files backup OK for $STORE_KEY (with tar warnings, see log)."
    else
      log "Files backup OK for $STORE_KEY"
    fi
  else
    log "ERROR: Files backup FAILED for $STORE_KEY (tar exit code: $TAR_EXIT). Removing partial file."
    rm -f "$FILES_BACKUP_FILE"
    BACKUP_STATUS="ERROR"
  fi

done

### ========== UPLOAD TO S3 ==========

if [ "$ENABLE_S3" = true ]; then
  S3_TARGET="s3://$AWS_S3_BUCKET/$AWS_S3_PREFIX/$DATE_STR/"
  log "Uploading backups to S3: $S3_TARGET"

  if aws s3 sync "$TODAY_BACKUP_DIR" "$S3_TARGET" --storage-class "$AWS_S3_STORAGE_CLASS" >>"$LOG_FILE" 2>&1; then
    log "Upload S3 OK."
    S3_UPLOAD_STATUS="OK"
  else
    log "ERROR: Upload S3 FAILED. Check log: $LOG_FILE"
    S3_UPLOAD_STATUS="ERROR"
    BACKUP_STATUS="ERROR"
  fi
else
  log "S3 upload disabled (ENABLE_S3=false)."
fi

### ========== UPLOAD TO GOOGLE DRIVE ==========

if [ "$ENABLE_GDRIVE" = true ]; then
  GDRIVE_TARGET="${RCLONE_REMOTE_GDRIVE}:${RCLONE_GDRIVE_PATH}/${DATE_STR}"
  log "Uploading backups to Google Drive: $GDRIVE_TARGET"

  if rclone copy "$TODAY_BACKUP_DIR" "$GDRIVE_TARGET" -v >>"$LOG_FILE" 2>&1; then
    log "Upload Google Drive OK."
    GDRIVE_UPLOAD_STATUS="OK"
  else
    log "ERROR: Upload Google Drive FAILED. Check log: $LOG_FILE"
    GDRIVE_UPLOAD_STATUS="ERROR"
    BACKUP_STATUS="ERROR"
  fi
else
  log "Google Drive upload disabled (ENABLE_GDRIVE=false)."
fi

### ========== INCREMENTAL BACKUP VIA RCLONE SYNC (OPTIONAL) ==========

if [ "$ENABLE_INCREMENTAL" = true ]; then
  INCREMENTAL_STATUS="ERROR"
  if [ -z "$INCREMENTAL_REMOTE" ]; then
    log "ERROR: Incremental enabled but INCREMENTAL_REMOTE is empty."
  else
    log "Running incremental backup: $INCREMENTAL_SOURCE -> $INCREMENTAL_REMOTE"
    if rclone sync "$INCREMENTAL_SOURCE" "$INCREMENTAL_REMOTE" \
        --fast-list --track-renames --metadata >>"$LOG_FILE" 2>&1; then
      log "Incremental backup OK."
      INCREMENTAL_STATUS="OK"
    else
      log "ERROR: Incremental backup FAILED."
      BACKUP_STATUS="ERROR"
    fi
  fi
fi

### ========== DELETE TODAY LOCAL BACKUP IF REMOTE OK ==========

DELETE_TODAY_LOCAL=false

# Chỉ xoá local nếu TẤT CẢ remote đang bật đều OK
if [ "$ENABLE_S3" = true ] && [ "$S3_UPLOAD_STATUS" != "OK" ]; then
  DELETE_TODAY_LOCAL=false
elif [ "$ENABLE_GDRIVE" = true ] && [ "$GDRIVE_UPLOAD_STATUS" != "OK" ]; then
  DELETE_TODAY_LOCAL=false
else
  if [ "$ENABLE_S3" = true ] || [ "$ENABLE_GDRIVE" = true ]; then
    DELETE_TODAY_LOCAL=true
  fi
fi

if [ "$DELETE_TODAY_LOCAL" = true ]; then
  log "All enabled remote uploads OK. Deleting today's local backup: $TODAY_BACKUP_DIR"
  rm -rf "$TODAY_BACKUP_DIR"
else
  log "Keep today's local backup (some remote upload failed or all remote disabled)."
fi

### ========== REMOTE RETENTION: DELETE OLD BACKUPS ON S3 & GDRIVE ==========

CUTOFF_DATE=$(date -d "$RETENTION_DAYS days ago" +%F)
log "Remote retention: delete backups older than $CUTOFF_DATE (>$RETENTION_DAYS days)"

# ---- S3 retention ----
if [ "$ENABLE_S3" = true ]; then
  S3_RETENTION_STATUS="OK"
  S3_BASE_PATH="s3://$AWS_S3_BUCKET/$AWS_S3_PREFIX/"

  aws s3 ls "$S3_BASE_PATH" >>"$LOG_FILE" 2>&1 | awk '{print $2}' | while read prefix; do
    prefix=${prefix%/}
    if [[ "$prefix" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
      if [[ "$prefix" < "$CUTOFF_DATE" ]]; then
        log "Deleting old S3 backup folder: $prefix"
        if ! aws s3 rm "${S3_BASE_PATH}${prefix}/" --recursive >>"$LOG_FILE" 2>&1; then
          log "ERROR: Failed to delete S3 folder $prefix"
          S3_RETENTION_STATUS="ERROR"
          BACKUP_STATUS="ERROR"
        fi
      fi
    fi
  done
else
  log "Skip S3 retention (S3 disabled)."
fi

# ---- Google Drive retention ----
if [ "$ENABLE_GDRIVE" = true ]; then
  GDRIVE_RETENTION_STATUS="OK"
  GDRIVE_BASE="${RCLONE_REMOTE_GDRIVE}:${RCLONE_GDRIVE_PATH}"

  while read -r line; do
    dir_name=$(echo "$line" | awk '{print $5}')
    [[ -z "$dir_name" ]] && continue
    if [[ "$dir_name" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
      if [[ "$dir_name" < "$CUTOFF_DATE" ]]; then
        log "Deleting old GDrive backup folder: $dir_name"
        if ! rclone purge "${GDRIVE_BASE}/${dir_name}" >>"$LOG_FILE" 2>&1; then
          log "ERROR: Failed to delete GDrive folder $dir_name"
          GDRIVE_RETENTION_STATUS="ERROR"
          BACKUP_STATUS="ERROR"
        fi
      fi
    fi
  done < <(rclone lsd "$GDRIVE_BASE" 2>>"$LOG_FILE")
else
  log "Skip GDrive retention (GDrive disabled)."
fi

### ========== CLEANUP OLD LOCAL BACKUPS (FALLBACK) ==========

log "Cleaning up local backups older than $RETENTION_DAYS days..."
find "$BACKUP_BASE" -maxdepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -print -exec rm -rf {} \; | tee -a "$LOG_FILE"

### ========== LOG ROTATION ==========

log "Cleaning up backup logs older than $LOG_RETENTION_DAYS days..."
find "$LOG_DIR" -type f -name "backup_*.log" -mtime +$LOG_RETENTION_DAYS -print -delete | tee -a "$LOG_FILE"

### ========== CALCULATE TOTAL SIZE ON S3 & GDRIVE ==========

if [ "$ENABLE_S3" = true ]; then
  S3_BASE_PATH="s3://$AWS_S3_BUCKET/$AWS_S3_PREFIX/"
  S3_TOTAL_SIZE=$(aws s3 ls "$S3_BASE_PATH" --recursive 2>>"$LOG_FILE" | \
    awk '{sum+=$4} END {if (sum>0) printf "%.2f GB", sum/1024/1024/1024; else print "0 GB"}')
fi

if [ "$ENABLE_GDRIVE" = true ]; then
  GDRIVE_BASE="${RCLONE_REMOTE_GDRIVE}:${RCLONE_GDRIVE_PATH}"
  # Output kiểu: "Total size: 1.234 GiB (....)"
  GDRIVE_TOTAL_SIZE=$(rclone size "$GDRIVE_BASE" 2>>"$LOG_FILE" | awk '/Total size:/ {print $3,$4}')
fi

### ========== TELEGRAM SUMMARY ==========

SUMMARY="WP Backup Report
Date: $DATE_STR
Disk usage: $DISK_USED

Backup status: $BACKUP_STATUS
S3 upload: $S3_UPLOAD_STATUS
GDrive upload: $GDRIVE_UPLOAD_STATUS
Incremental: $INCREMENTAL_STATUS
S3 retention: $S3_RETENTION_STATUS
GDrive retention: $GDRIVE_RETENTION_STATUS

S3 total size: $S3_TOTAL_SIZE
GDrive total size: $GDRIVE_TOTAL_SIZE

Log file: $LOG_FILE
"

if [ "$ENABLE_TELEGRAM" = true ]; then
  if [ "$TELEGRAM_MODE" = "full" ]; then
    log "Sending FULL Telegram summary..."
    send_telegram "$SUMMARY"
  elif [ "$TELEGRAM_MODE" = "error" ]; then
    if [ "$BACKUP_STATUS" = "ERROR" ] || \
       [ "$S3_UPLOAD_STATUS" = "ERROR" ] || \
       [ "$GDRIVE_UPLOAD_STATUS" = "ERROR" ] || \
       [ "$S3_RETENTION_STATUS" = "ERROR" ] || \
       [ "$GDRIVE_RETENTION_STATUS" = "ERROR" ] || \
       [ "$INCREMENTAL_STATUS" = "ERROR" ]; then
      log "Sending ERROR Telegram summary..."
      send_telegram "$SUMMARY"
    else
      log "No errors – Telegram notify skipped (mode=error)."
    fi
  else
    log "Telegram disabled (TELEGRAM_MODE=off)."
  fi
fi

log "========== BACKUP DONE =========="
exit 0