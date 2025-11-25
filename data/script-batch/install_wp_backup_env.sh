#!/bin/bash
set -e

echo ""
echo "[*] === Install WordPress Backup Environment (AWS S3 + Google Drive) ==="
echo ""

HOME_DIR="$HOME"
TOOLS_DIR="$HOME_DIR/tools"
BIN_DIR="$HOME_DIR/bin"
SCRIPTS_DIR="$HOME_DIR/scripts"
SCRIPTS_PHP_DIR="$HOME_DIR/scripts-php-backup"
LOGS_DIR="$HOME_DIR/logs"
BACKUP_DIR="$HOME_DIR/backups"

# ============================
# URL TẢI FILE SCRIPT (cập nhật theo repo của bạn)
# ============================
URL_BACKUP_SH="https://raw.githubusercontent.com/anhnnp/anhnnp.github.io/main/data/script-batch/backup_all_stores.sh"
URL_RESTORE_SH="https://raw.githubusercontent.com/anhnnp/anhnnp.github.io/main/data/script-batch/restore_wp_from_backup.sh"
URL_COMPOSER_PHAR="https://getcomposer.org/download/latest-stable/composer.phar"

# ============================
# Hàm tiện ích
# ============================
check_cmd() {
    local name="$1"
    local cmd="${2:-$1}"

    if command -v "$cmd" >/dev/null 2>&1; then
        local ver
        ver="$($cmd --version 2>/dev/null | head -n 1 || echo "found")"
        echo "  [OK] $name: $ver"
    else
        echo "  [MISSING] $name: command '$cmd' not found (có thể cần cài / bật trong hosting)"
    fi
}

# ============================
# Tạo thư mục môi trường
# ============================
echo "[*] Tạo thư mục môi trường..."
mkdir -p "$TOOLS_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$SCRIPTS_PHP_DIR" "$LOGS_DIR" "$BACKUP_DIR"
mkdir -p "$HOME_DIR/.config/rclone"

# ============================
# Cài AWS CLI (non-interactive & idempotent)
# ============================
echo "[*] Cài AWS CLI v2..."
cd "$TOOLS_DIR"

rm -rf aws awscliv2.zip >/dev/null 2>&1 || true

curl -fsSLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
unzip -q -o awscliv2.zip

./aws/install --update --bin-dir "$BIN_DIR" --install-dir "$HOME_DIR/aws-cli" || true

echo "[*] Kiểm tra AWS CLI..."
"$BIN_DIR/aws" --version || echo "  [WARN] AWS CLI chưa chạy — vẫn tiếp tục."

# ============================
# Add PATH
# ============================
if ! grep -q 'export PATH=$HOME/bin:$PATH' "$HOME_DIR/.bashrc" 2>/dev/null; then
    echo 'export PATH=$HOME/bin:$PATH' >> "$HOME_DIR/.bashrc"
fi
export PATH="$HOME_DIR/bin:$PATH"

# ============================
# Cài rclone (non-interactive)
# ============================
echo "[*] Cài rclone..."
cd "$TOOLS_DIR"
rm -rf rclone-current-linux-amd64.zip rclone-*-linux-amd64 >/dev/null 2>&1 || true

curl -fsSLo rclone-current-linux-amd64.zip https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip -q -o rclone-current-linux-amd64.zip

cd rclone-*-linux-amd64
cp rclone "$BIN_DIR/"
chmod 755 "$BIN_DIR/rclone"

echo "[*] Kiểm tra rclone..."
"$BIN_DIR/rclone" version || echo "  [WARN] rclone chưa chạy — vẫn tiếp tục."

# ============================
# Cài Composer
# ============================
echo "[*] Cài Composer..."
cd "$TOOLS_DIR"
curl -fsSLo composer.phar "$URL_COMPOSER_PHAR"
chmod +x composer.phar
mv composer.phar "$BIN_DIR/composer"

echo "[*] Composer version:"
"$BIN_DIR/composer" --version || echo "  [WARN] Composer chưa chạy — vẫn tiếp tục."

# ============================
# Cài PHP Libraries (AWS SDK + Google Drive API)
# ============================
echo "[*] Cài library PHP (AWS SDK + Google API)..."
cd "$SCRIPTS_PHP_DIR"
"$BIN_DIR/composer" require aws/aws-sdk-php:^3.0 google/apiclient:^2.0 --no-interaction || true

# ============================
# Tải script backup & restore
# ============================
echo "[*] Tải script backup & restore..."
curl -fsSLo "$SCRIPTS_DIR/backup_all_stores.sh"  "$URL_BACKUP_SH"
curl -fsSLo "$SCRIPTS_DIR/restore_wp_from_backup.sh" "$URL_RESTORE_SH"

chmod +x "$SCRIPTS_DIR/backup_all_stores.sh"
chmod +x "$SCRIPTS_DIR/restore_wp_from_backup.sh"

# ============================
# Kiểm tra / tạo template backup_config.env
# ============================
CONFIG_FILE="$SCRIPTS_DIR/backup_config.env"

if [ -f "$CONFIG_FILE" ]; then
    echo "[*] Đã tồn tại file config: $CONFIG_FILE (không ghi đè)."
else
    echo "[*] Tạo file config mẫu: $CONFIG_FILE"
    cat > "$CONFIG_FILE" << 'EOF'
# backup_config.env
# Danh sách site dạng tên folder: domain.com
STORES=(
  "domain-a.com"
  "domain-b.com"
)

# AWS S3
AWS_S3_BUCKET="sites-backup"
AWS_S3_PREFIX="wp-backups"

# Google Drive (rclone remote)
RCLONE_REMOTE_GDRIVE="gdrive"
RCLONE_GDRIVE_PATH="wp-backups"

# Telegram
ENABLE_TELEGRAM=true
TELEGRAM_BOT_TOKEN="123456:ABCDEF..."
TELEGRAM_CHAT_ID="-1001..."
TELEGRAM_MODE="full"   # full | error | off

# Bật/tắt upload
ENABLE_S3=true
ENABLE_GDRIVE=true

# Exclude folder riêng (nếu muốn)
EXCLUDED_DIR_PATTERNS=(
  "aiowps_backups"
  "wp-cloudflare-super-page-cache"
  "litespeed"
  "cache"
)

# Ghi đè BASE_DIR nếu home khác (nếu bỏ comment)
# BASE_DIR="/home/USER"

EOF
fi

# ============================
# Kiểm tra / tạo template AWS credentials
# ============================
AWS_DIR="$HOME_DIR/.aws"
AWS_CRED="$AWS_DIR/credentials"

mkdir -p "$AWS_DIR"

if [ -f "$AWS_CRED" ]; then
    echo "[*] Đã tìm thấy AWS credentials: $AWS_CRED"
else
    AWS_CRED_TEMPLATE="$AWS_DIR/credentials.example"
    echo "[*] Chưa có AWS credentials. Tạo template: $AWS_CRED_TEMPLATE"
    cat > "$AWS_CRED_TEMPLATE" << 'EOF'
[default]
aws_access_key_id = YOUR_ACCESS_KEY_ID
aws_secret_access_key = YOUR_SECRET_ACCESS_KEY
region = ap-southeast-1
output = json
EOF
    echo "    → Hãy copy file này thành 'credentials' và sửa lại thông tin thật."
fi

# ============================
# Kiểm tra / tạo template rclone.conf
# ============================
RCLONE_DIR="$HOME_DIR/.config/rclone"
RCLONE_CONF="$RCLONE_DIR/rclone.conf"

mkdir -p "$RCLONE_DIR"

if [ -f "$RCLONE_CONF" ]; then
    echo "[*] Đã tìm thấy rclone config: $RCLONE_CONF"
else
    RCLONE_CONF_TEMPLATE="$RCLONE_DIR/rclone.conf.example"
    echo "[*] Chưa có rclone.conf. Tạo template: $RCLONE_CONF_TEMPLATE"
    cat > "$RCLONE_CONF_TEMPLATE" << 'EOF'
[gdrive]
type = drive
client_id = YOUR_CLIENT_ID
client_secret = YOUR_CLIENT_SECRET
scope = drive
token = {"access_token":"...","refresh_token":"...","expiry":"..."}
EOF
    echo "    → Hãy copy file này thành 'rclone.conf' và sửa lại thông tin remote thật."
fi

# ============================
# CHECK CUỐI CÙNG: môi trường CLI dùng cho backup_all_stores.sh
# ============================
echo ""
echo "=================================================="
echo "[*] KIỂM TRA MÔI TRƯỜNG CLI (sẽ dùng trong backup_all_stores.sh)"
echo "=================================================="

check_cmd "PHP CLI" "php"
check_cmd "mysqldump" "mysqldump"
check_cmd "tar" "tar"
check_cmd "gzip" "gzip"
check_cmd "zip" "zip"
check_cmd "unzip" "unzip"
check_cmd "curl" "curl"
check_cmd "AWS CLI" "aws"
check_cmd "rclone" "rclone"

echo ""
echo "=================================================="
echo "[✔] CÀI ĐẶT HOÀN TẤT"
echo "=================================================="
echo ""
echo "1) Nếu cần, sửa file config:"
echo "   $CONFIG_FILE"
echo ""
echo "2) Điền AWS credentials thật trong:"
echo "   $AWS_DIR/credentials   (có sẵn template: credentials.example)"
echo ""
echo "3) Điền cấu hình rclone thật trong:"
echo "   $RCLONE_CONF           (có sẵn template: rclone.conf.example)"
echo ""
echo "4) Test bash backup:"
echo "   bash ~/scripts/backup_all_stores.sh"
echo ""
echo "5) Test PHP backup (khi bạn đã có script PHP):"
echo "   php ~/scripts-php-backup/backup_all_stores.php"
echo ""
echo "=================================================="
echo "[*] Mọi thứ OK — Sẵn sàng chạy backup!"
echo "=================================================="

exit 0