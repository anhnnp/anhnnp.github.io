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
URL_BACKUP_SH="https://anhnnp.pages.dev/data/script-batch/backup_all_stores.sh"
URL_RESTORE_SH="https://anhnnp.pages.dev/data/script-batch/restore_wp_from_backup.sh"
URL_COMPOSER_PHAR="https://getcomposer.org/download/latest-stable/composer.phar"

# ============================
# Tạo thư mục môi trường
# ============================
echo "[*] Tạo thư mục môi trường..."
mkdir -p "$TOOLS_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$SCRIPTS_PHP_DIR" "$LOGS_DIR" "$BACKUP_DIR"
mkdir -p ~/.config/rclone

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
"$BIN_DIR/aws" --version || echo "Cảnh báo: AWS CLI chưa chạy — vẫn tiếp tục."

# ============================
# Add PATH
# ============================
if ! grep -q 'export PATH=$HOME/bin:$PATH' ~/.bashrc; then
    echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
fi
export PATH="$HOME/bin:$PATH"

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
"$BIN_DIR/rclone" version || echo "Cảnh báo: rclone chưa chạy — vẫn tiếp tục."

# ============================
# Cài Composer
# ============================
echo "[*] Cài Composer..."
cd "$TOOLS_DIR"
curl -fsSLo composer.phar "$URL_COMPOSER_PHAR"
chmod +x composer.phar
mv composer.phar "$BIN_DIR/composer"

echo "[*] Composer version:"
"$BIN_DIR/composer" --version || true

# ============================
# Cài PHP Libraries (AWS SDK + Google Drive API)
# ============================
echo "[*] Cài library PHP..."
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
# Tạo file cấu hình .env mẫu
# ============================
echo "[*] Tạo file config mẫu..."

cat > "$SCRIPTS_DIR/backup_config.env" << 'EOF'
# Danh sách site dạng tên folder: domain.com
STORES=("domain1.com" "domain2.com")

# AWS Config
AWS_S3_KEY=""
AWS_S3_SECRET=""
AWS_S3_BUCKET="sites-backup"
AWS_S3_PREFIX="wp-backups"
AWS_S3_REGION="ap-southeast-1"

# Google Drive
GDRIVE_FOLDER_ID=""

# Telegram notify
TELEGRAM_BOT=""
TELEGRAM_CHAT=""
TELEGRAM_MODE="error"

# Retention
RETENTION_DAYS=7
LOG_RETENTION_DAYS=30
EOF

# ============================
# Hoàn tất
# ============================
echo ""
echo "=================================================="
echo "[✔] CÀI ĐẶT HOÀN TẤT"
echo "=================================================="
echo ""
echo "1) Copy AWS credentials vào:"
echo "   ~/.aws/credentials"
echo ""
echo "2) Thêm file rclone.conf vào:"
echo "   ~/.config/rclone/rclone.conf"
echo ""
echo "3) Mở file config để sửa:"
echo "   ${SCRIPTS_DIR}/backup_config.env"
echo ""
echo "4) Test bash backup:"
echo "   bash ~/scripts/backup_all_stores.sh"
echo ""
echo "5) Test PHP backup:"
echo "   php ~/scripts-php-backup/backup_all_stores.php"
echo ""
echo "=================================================="
echo "[*] Mọi thứ OK — Sẵn sàng chạy backup!"
echo "=================================================="

exit 0