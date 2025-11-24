#!/usr/bin/env bash
#
# restore_wp_from_backup.sh
# Khôi phục 1 WordPress site từ bộ backup: db_*.sql(.gz) + files_*.tar.gz/.zip
# Hỗ trợ:
#   - Local folder (/home/USER/backups/...)
#   - S3 (s3://bucket/path/...)
#   - Google Drive (URL) thông qua rclone
#

set -euo pipefail

# ---------- Helpers ----------
log() {
  # log ra stderr để không bị dính vào command substitution
  echo -e "[*] $*" >&2
}

err() {
  echo -e "[ERROR] $*" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Command '$1' is required but not found. Please install it."
    exit 1
  fi
}

pause() {
  read -rp "Nhấn Enter để tiếp tục..."
}

# Biến thư mục tạm & cleanup tự động
TMP_ROOT=""

cleanup() {
  # Chỉ xoá nếu TMP_ROOT đã được set và tồn tại
  if [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]]; then
    log "Xoá thư mục tạm: $TMP_ROOT"
    rm -rf "$TMP_ROOT"
  fi
}

# Luôn gọi cleanup khi script kết thúc (thành công hoặc lỗi)
trap cleanup EXIT

# Tìm file DB trong một thư mục
find_db_file_in_dir() {
  local dir="$1"
  local f
  shopt -s nullglob
  for f in "$dir"/db_*.sql.gz "$dir"/db_*.sql "$dir"/*.sql.gz "$dir"/*.sql; do
    echo "$f"
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

# Tìm file source archive trong một thư mục
find_source_file_in_dir() {
  local dir="$1"
  local f
  shopt -s nullglob
  for f in "$dir"/files_*.tar.gz "$dir"/files_*.zip "$dir"/*.tar.gz "$dir"/*.zip; do
    echo "$f"
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

# Tải 1 file hoặc folder về local_tmp (nếu cần), và trả về đường dẫn local
# Input: 1) source (local path | s3:// | GDrive URL | http(s) khác)
# Output: echo local path (chỉ 1 dòng)
fetch_to_local() {
  local src="$1"
  local target_dir="$2"

  mkdir -p "$target_dir"

  if [[ "$src" == s3://* ]]; then
    require_cmd aws
    log "S3 path detected. Sync/copy từ S3 về: $target_dir"

    # Nếu là folder: dùng sync, nếu là file: dùng cp
    if [[ "$src" == */ || "$src" != *.* ]]; then
      aws s3 sync "$src" "$target_dir" >&2
      echo "$target_dir"
    else
      aws s3 cp "$src" "$target_dir/" >&2
      echo "$target_dir/$(basename "$src")"
    fi

  elif [[ "$src" == http://* || "$src" == https://* ]]; then
    # Kiểm tra Google Drive URL
    if [[ "$src" == *"drive.google.com"* ]]; then
      require_cmd rclone
      log "Google Drive URL detected."

      log "Các rclone remote hiện có (đã cấu hình trong rclone):"
      rclone listremotes >&2 || true
      echo >&2

      read -rp "Nhập tên remote bạn muốn dùng (ví dụ: gdrive): " RCLONE_REMOTE
      if [[ -z "$RCLONE_REMOTE" ]]; then
        err "Bạn chưa nhập tên remote."
        exit 1
      fi

      log "Liệt kê các thư mục cấp cao trong ${RCLONE_REMOTE}:"
      rclone lsd "${RCLONE_REMOTE}:" >&2 || true
      echo >&2

      echo "Ví dụ path: ${RCLONE_REMOTE}:wp-backups/2025-11-11/domain_com" >&2
      read -rp "Nhập rclone remote:path tương ứng với folder backup này: " RCLONE_PATH

      if [[ -z "$RCLONE_PATH" ]]; then
        err "Bạn chưa nhập rclone remote:path."
        exit 1
      fi

      log "Đang sync từ rclone ($RCLONE_PATH) về $target_dir ..."
      rclone sync "$RCLONE_PATH" "$target_dir" >&2
      echo "$target_dir"
    else
      err "HTTP URL không được hỗ trợ trực tiếp (chỉ hỗ trợ Google Drive + rclone)."
      err "Hãy dùng rclone sync/copy về local hoặc cung cấp GDrive URL."
      exit 1
    fi

  else
    # local path
    if [[ -d "$src" || -f "$src" ]]; then
      echo "$src"
    else
      err "Không tìm thấy đường dẫn local: $src"
      exit 1
    fi
  fi
}

# Tìm file db_*.sql(.gz) và files_*.tar.gz/.zip trong 1 folder
find_backup_files() {
  local backup_dir="$1"
  DB_FILE=""
  FILES_ARCHIVE=""

  if DB_FILE="$(find_db_file_in_dir "$backup_dir")"; then
    :
  else
    DB_FILE=""
  fi

  if FILES_ARCHIVE="$(find_source_file_in_dir "$backup_dir")"; then
    :
  else
    FILES_ARCHIVE=""
  fi
}

# Cập nhật wp-config.php với DB_NAME/USER/PASS/HOST mới (không cần perl)
update_wp_config() {
  local wp_config="$1"
  local db_name="$2"
  local db_user="$3"
  local db_pass="$4"
  local db_host="$5"

  if [[ ! -f "$wp_config" ]]; then
    err "Không tìm thấy wp-config.php tại: $wp_config"
    return 1
  fi

  log "Cập nhật thông tin DB trong wp-config.php (dùng sed)"

  sed -i "s/define( *'DB_NAME'.*/define('DB_NAME', '$db_name');/" "$wp_config"
  sed -i "s/define( *\"DB_NAME\".*/define(\"DB_NAME\", \"$db_name\");/" "$wp_config"

  sed -i "s/define( *'DB_USER'.*/define('DB_USER', '$db_user');/" "$wp_config"
  sed -i "s/define( *\"DB_USER\".*/define(\"DB_USER\", \"$db_user\");/" "$wp_config"

  sed -i "s/define( *'DB_PASSWORD'.*/define('DB_PASSWORD', '$db_pass');/" "$wp_config"
  sed -i "s/define( *\"DB_PASSWORD\".*/define(\"DB_PASSWORD\", \"$db_pass\");/" "$wp_config"

  sed -i "s/define( *'DB_HOST'.*/define('DB_HOST', '$db_host');/" "$wp_config"
  sed -i "s/define( *\"DB_HOST\".*/define(\"DB_HOST\", \"$db_host\");/" "$wp_config"
}

# ---------- Start ----------
require_cmd mysql
require_cmd tar
require_cmd unzip

log "=== WordPress Restore Script ==="

# 1. Hỏi đường dẫn folder backup
read -rp "Nhập đường dẫn FOLDER backup (local, s3://..., hoặc GDrive URL): " BACKUP_SOURCE

if [[ -z "$BACKUP_SOURCE" ]]; then
  err "Bạn chưa nhập đường dẫn backup."
  exit 1
fi

TMP_ROOT="$(mktemp -d /tmp/wp-restore.XXXXXX)"
log "Tạo thư mục tạm: $TMP_ROOT"

LOCAL_BACKUP_PATH="$(fetch_to_local "$BACKUP_SOURCE" "$TMP_ROOT/backup")"
log "Backup đã được chuẩn bị tại: $LOCAL_BACKUP_PATH"

# Nếu là file đơn lẻ thì dùng thư mục cha, nếu là folder thì dùng chính nó
if [[ -f "$LOCAL_BACKUP_PATH" ]]; then
  BACKUP_DIR="$(dirname "$LOCAL_BACKUP_PATH")"
else
  BACKUP_DIR="$LOCAL_BACKUP_PATH"
fi

# 2. Tự tìm file db và files trong BACKUP_DIR
find_backup_files "$BACKUP_DIR"

# Nếu không thấy DB, hỏi thêm
if [[ -z "${DB_FILE:-}" ]]; then
  log "Không tìm thấy file backup database (db_*.sql / *.sql / *.sql.gz) trong $BACKUP_DIR."
  read -rp "Nhập PATH cụ thể tới file DB backup (local hoặc s3://... hoặc GDrive URL): " DB_SRC
  if [[ -z "$DB_SRC" ]]; then
    err "Chưa cung cấp đường dẫn DB backup."
    exit 1
  fi
  DB_LOCAL_PATH="$(fetch_to_local "$DB_SRC" "$TMP_ROOT/db")"
  if [[ -d "$DB_LOCAL_PATH" ]]; then
    if ! DB_FILE="$(find_db_file_in_dir "$DB_LOCAL_PATH")"; then
      err "Không tìm thấy file .sql/.sql.gz trong $DB_LOCAL_PATH"
      exit 1
    fi
  else
    DB_FILE="$DB_LOCAL_PATH"
  fi
fi

if [[ ! -f "$DB_FILE" ]]; then
  err "File DB backup không tồn tại: $DB_FILE"
  exit 1
fi

log "DB backup file: $DB_FILE"

# Nếu không thấy SOURCE, hỏi thêm
if [[ -z "${FILES_ARCHIVE:-}" ]]; then
  log "Không tìm thấy file backup source code (files_*.tar.gz / *.tar.gz / *.zip) trong $BACKUP_DIR."
  read -rp "Nhập PATH cụ thể tới file SOURCE backup (local hoặc s3://... hoặc GDrive URL): " FILE_SRC
  if [[ -z "$FILE_SRC" ]]; then
    err "Chưa cung cấp đường dẫn SOURCE backup."
    exit 1
  fi
  FILE_LOCAL_PATH="$(fetch_to_local "$FILE_SRC" "$TMP_ROOT/files")"
  if [[ -d "$FILE_LOCAL_PATH" ]]; then
    if ! FILES_ARCHIVE="$(find_source_file_in_dir "$FILE_LOCAL_PATH")"; then
      err "Không tìm thấy file .tar.gz/.zip trong $FILE_LOCAL_PATH"
      exit 1
    fi
  else
    FILES_ARCHIVE="$FILE_LOCAL_PATH"
  fi
fi

if [[ ! -f "$FILES_ARCHIVE" ]]; then
  err "File SOURCE backup không tồn tại: $FILES_ARCHIVE"
  exit 1
fi

log "Source backup file: $FILES_ARCHIVE"

echo
log "=== Thông tin restore site ==="
read -rp "Nhập đường dẫn thư mục site (ví dụ /home/USER/domains/domain1.com/public_html): " DEST_DIR
if [[ -z "$DEST_DIR" ]]; then
  err "Bạn chưa nhập DEST_DIR"
  exit 1
fi

read -rp "Nhập DB_NAME: " DB_NAME
read -rp "Nhập DB_USER: " DB_USER
read -rsp "Nhập DB_PASSWORD: " DB_PASS
echo
read -rp "Nhập DB_HOST [localhost]: " DB_HOST
DB_HOST=${DB_HOST:-localhost}

if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
  err "DB_NAME và DB_USER không được để trống."
  exit 1
fi

echo
log "=== Xác nhận cấu hình ==="
echo "Backup folder local: $BACKUP_DIR"
echo "DB file:           $DB_FILE"
echo "Source archive:    $FILES_ARCHIVE"
echo "Site path:         $DEST_DIR"
echo "DB_NAME:           $DB_NAME"
echo "DB_USER:           $DB_USER"
echo "DB_HOST:           $DB_HOST"
echo
read -rp "Tiếp tục restore? (y/N): " CONT
if [[ "$CONT" != "y" && "$CONT" != "Y" ]]; then
  err "Hủy restore."
  exit 1
fi

# 3. Chuẩn bị thư mục site
if [[ -d "$DEST_DIR" ]]; then
  if [[ -n "$(ls -A "$DEST_DIR" 2>/dev/null || true)" ]]; then
    log "Thư mục $DEST_DIR không rỗng."
    read -rp "Bạn muốn xoá toàn bộ nội dung cũ trước khi restore? (y/N): " CLEAR_OLD
    if [[ "$CLEAR_OLD" == "y" || "$CLEAR_OLD" == "Y" ]]; then
      log "Xoá toàn bộ nội dung cũ trong $DEST_DIR"
      rm -rf "${DEST_DIR:?}/"*
    else
      log "Giữ nguyên nội dung cũ và extract đè (cẩn thận duplicate file)."
    fi
  fi
else
  log "Tạo thư mục site: $DEST_DIR"
  mkdir -p "$DEST_DIR"
fi

# 4. Extract source code
log "Giải nén source code vào $DEST_DIR"

if [[ "$FILES_ARCHIVE" == *.tar.gz ]]; then
  tar -xzf "$FILES_ARCHIVE" -C "$DEST_DIR"
elif [[ "$FILES_ARCHIVE" == *.zip ]]; then
  unzip -o "$FILES_ARCHIVE" -d "$DEST_DIR"
else
  err "Định dạng file SOURCE không hỗ trợ: $FILES_ARCHIVE"
  exit 1
fi

log "Giải nén source code hoàn tất."

# 5. Import database
log "Import database vào MySQL..."

SQL_TMP="$TMP_ROOT/db.sql"
if [[ "$DB_FILE" == *.gz ]]; then
  log "Giải nén DB .gz tạm thời..."
  gunzip -c "$DB_FILE" > "$SQL_TMP"
else
  SQL_TMP="$DB_FILE"
fi

export MYSQL_PWD="$DB_PASS"
mysql -h"$DB_HOST" -u"$DB_USER" "$DB_NAME" < "$SQL_TMP"
unset MYSQL_PWD

log "Import database hoàn tất."

# 6. Cập nhật wp-config.php
WP_CONFIG_PATH="$DEST_DIR/wp-config.php"
if [[ -f "$WP_CONFIG_PATH" ]]; then
  update_wp_config "$WP_CONFIG_PATH" "$DB_NAME" "$DB_USER" "$DB_PASS" "$DB_HOST" || {
    err "Lỗi khi cập nhật wp-config.php – hãy kiểm tra lại file."
  }
else
  err "Không tìm thấy wp-config.php tại $WP_CONFIG_PATH, bỏ qua bước update DB config."
fi

echo
log "=== HOÀN TẤT RESTORE ==="
echo "Site path:   $DEST_DIR"
echo "DB name:     $DB_NAME"
echo "DB user:     $DB_USER"
echo "DB host:     $DB_HOST"
echo
log "Hãy trỏ domain / vhost tới $DEST_DIR và kiểm tra website."