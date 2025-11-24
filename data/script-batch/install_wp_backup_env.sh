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

# ========== THAY CÁC URL NÀY THÀNH URL CỦA BẠN ==========
URL_BACKUP_SH="https://anhnnp.pages.dev/data/script-batch/backup_all_stores.sh"
# URL_BACKUP_PHP="https://anhnnp.pages.dev/data/script-batch/backup_all_stores.php"
URL_RESTORE_SH="https://anhnnp.pages.dev/data/script-batch/restore_wp_from_backup.sh"
# URL_RESTORE_PHP="https://anhnnp.pages.dev/data/script-batch/restore_wp_from_backup.php"
URL_COMPOSER_PHAR="https://getcomposer.org/download/latest-stable/composer.phar"
# =========================================================

echo "[*] Tạo thư mục môi trường..."
mkdir -p "$TOOLS_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$SCRIPTS_PHP_DIR" "$LOGS_DIR" "$BACKUP_DIR"
mkdir -p ~/.config/rclone

echo "[*] Cài AWS CLI v2..."
cd "$TOOLS_DIR"
curl -sO "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
unzip -q awscliv2.zip

./aws/install --bin-dir "$BIN_DIR" --install-dir "$HOME_DIR/aws-cli" || true

echo "[*] Kiểm tra AWS CLI..."
"$BIN_DIR/aws" --version || echo "Cảnh báo: AWS chưa chạy, nhưng vẫn tiếp tục."

echo "[*] Thêm AWS CLI & rclone vào PATH..."
if ! grep -q 'export PATH=$HOME/bin:$PATH' ~/.bashrc; then
    echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
fi
source ~/.bashrc

echo "[*] Cài rclone..."
cd "$TOOLS_DIR"
curl -sO https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip -q rclone-current-linux-amd64.zip
cd rclone-*-linux-amd64
cp rclone "$BIN_DIR/"
chmod 755 "$BIN_DIR/rclone"

echo "[*] Kiểm tra rclone..."
"$BIN_DIR/rclone" version || echo "Cảnh báo: rclone chưa chạy, nhưng vẫn tiếp tục."

echo "[*] Cài Composer..."
cd "$TOOLS_DIR"
curl -s "$URL_COMPOSER_PHAR" -o composer.phar
chmod +x composer.phar
mv composer.phar "$BIN_DIR/composer"

echo "[*] Cài các thư viện PHP (AWS SDK + Google Drive API)..."
cd "$SCRIPTS_PHP_DIR"
"$BIN_DIR/composer" require aws/aws-sdk-php:^3.0 google/apiclient:^2.0 --no-interaction || true

echo "[*] Tải toàn bộ scripts backup & restore..."
curl -s "$URL_BACKUP_SH" -o "$SCRIPTS_DIR/backup_all_stores.sh"
# curl -s "$URL_BACKUP_PHP" -o "$SCRIPTS_PHP_DIR/backup_all_stores.php"
curl -s "$URL_RESTORE_SH" -o "$SCRIPTS_DIR/restore_wp_from_backup.sh"
# curl -s "$URL_RESTORE_PHP" -o "$SCRIPTS_PHP_DIR/restore_wp_from_backup.php"

chmod +x "$SCRIPTS_DIR/backup_all_stores.sh"
chmod +x "$SCRIPTS_DIR/restore_wp_from_backup.sh"

echo "[*] Tạo file config mẫu để bạn tự cập nhật..."
cat > "$SCRIPTS_DIR/backup_config.env" << 'EOF'
# Danh sách site dạng tên folder: domain.com
STORES=("domain1.com" "domain2.com")

# AWS Config
AWS_S3_KEY=""
AWS_S3_SECRET=""
AWS_S3_BUCKET="sites-backup"
AWS_S3_PREFIX="wp-backups"
AWS_S3_REGION="ap-southeast-1"

# Google Drive (đặt token vào scripts-php-backup/gdrive_token.json)
GDRIVE_FOLDER_ID=""

# Telegram notify
TELEGRAM_BOT=""
TELEGRAM_CHAT=""
TELEGRAM_MODE="error"

# Retention
RETENTION_DAYS=7
LOG_RETENTION_DAYS=30
EOF

echo ""
echo "=================================================="
echo "[✔] TẤT CẢ ĐÃ CÀI ĐẶT HOÀN TẤT!"
echo "=================================================="
echo ""
echo "Bạn cần làm 3 bước tiếp theo:"
echo ""
echo "1) Copy AWS credentials vào file:"
echo "   ~/.aws/credentials"
echo ""
echo "2) Copy file rclone.conf vào:"
echo "   ~/.config/rclone/rclone.conf"
echo ""
echo "3) Điền thông tin vào file config:"
echo "   $SCRIPTS_DIR/backup_config.env"
echo ""
echo "4) Test backup:"
echo "   bash ~/scripts/backup_all_stores.sh"
echo ""
echo "5) Test PHP backup:"
echo "   php ~/scripts-php-backup/backup_all_stores.php"
echo ""
echo "=================================================="
echo "[*] Xong. Sẵn sàng chạy backup!"
echo "=================================================="