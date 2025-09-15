#!/bin/bash
set -euo pipefail

# カラー出力用の定数
readonly COLOR_RED='\033[31m'
readonly COLOR_GREEN='\033[32m'
readonly COLOR_BLUE='\033[34m'
readonly COLOR_RESET='\033[0m'

# ログ出力用関数
log() {
  echo "[INFO] $*"
}

log_success() {
  echo -e "${COLOR_GREEN}✓${COLOR_RESET} $*"
}

log_error() {
  echo -e "${COLOR_RED}✗${COLOR_RESET} $*" >&2
}

log_info() {
  echo -e "${COLOR_BLUE}ℹ${COLOR_RESET} $*"
}

# エラー時のクリーンアップ
cleanup_on_error() {
  log_error "Error occurred. Cleaning up..."
  # 一時ファイルの削除
  [ -f "tmp/dump.sql" ] && rm -f "tmp/dump.sql"
}
trap cleanup_on_error ERR

# WP-CLI コマンドを実行するためのヘルパー関数
run_wp_cli() {
  npx wp-env run cli wp "$@"
}

# 環境変数の読み込み（存在する場合）
if [ -f .env ]; then
  log_info "Loading configuration from .env"
  source .env
fi

# 必須環境変数のチェック
check_required_env_vars() {
  local required_vars=("PRODUCTION_USER" "PRODUCTION_HOST" "PRODUCTION_SSH_PORT" "PRODUCTION_SSH_KEY" "PRODUCTION_DIR" "PRODUCTION_URL")
  local missing_vars=()
  for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
      missing_vars+=("$var")
    fi
  done
  if [ ${#missing_vars[@]} -ne 0 ]; then
    log_error "Missing required environment variables: ${missing_vars[*]}"
    log_error "Please create .env file with the following variables:"
    for var in "${missing_vars[@]}"; do
      echo "  $var=<value>"
    done
    exit 1
  fi
}

# デフォルト値の設定
LOCAL_URL="${LOCAL_URL:-http://localhost:8888}"

# SSH接続をテスト
check_ssh_connection() {
  log "Checking SSH connection..."
  if ! ssh -q -o ConnectTimeout=5 $SSH_OPTIONS "$PRODUCTION_USER@$PRODUCTION_HOST" exit; then
    log_error "Cannot connect to server. Please check your SSH configuration."
    log_error "SSH Key: $PRODUCTION_SSH_KEY"
    log_error "SSH Port: $PRODUCTION_SSH_PORT"
    log_info "If this is your first connection, please run: ssh -i $PRODUCTION_SSH_KEY -p $PRODUCTION_SSH_PORT $PRODUCTION_USER@$PRODUCTION_HOST"
    exit 1
  fi
  log_success "SSH connection successful"
}

# ディレクトリが存在しない場合は作成する
create_directory_if_not_exists() {
  local dir=$1
  if [ ! -d "$dir" ]; then
    log "Directory '$dir' does not exist. Creating..."
    mkdir -p "$dir"
  fi
}

# ローカルディレクトリの作成
setup_local_directories() {
  create_directory_if_not_exists "./wp-content"
  create_directory_if_not_exists "./tmp"
}

# ローカル環境の起動
start_local_environment() {
  log "Starting local environment..."
  npx wp-env stop 2>/dev/null || true
  npx wp-env start
  log_success "Local environment started"
}

# 本番サーバーからデータベースをエクスポートする
dump_production_database() {
  log "Connecting to the production server and exporting database..."
  ssh $SSH_OPTIONS "$PRODUCTION_USER@$PRODUCTION_HOST" "cd $PRODUCTION_DIR && wp db export --exclude_tables=wp_users dump.sql"
  log_success "Database exported on production server"
}

# 本番サーバーからSQLダンプファイルをローカルにコピーする
copy_database_to_local() {
  log "Copying SQL dump file from production server to local..."
  scp -P $PRODUCTION_SSH_PORT -i $PRODUCTION_SSH_KEY "$PRODUCTION_USER@$PRODUCTION_HOST:$PRODUCTION_DIR/dump.sql" "tmp/dump.sql"
  log_success "SQL dump file copied to local"

  # リモートの一時ファイルを削除
  ssh $SSH_OPTIONS "$PRODUCTION_USER@$PRODUCTION_HOST" "rm -f $PRODUCTION_DIR/dump.sql"
}

# 本番サーバーからwp-contentをrsyncで同期する
sync_wp_content() {
  log "Syncing wp-content from production server..."

  # rsync除外パターン
  local excludes=(
    "uploads/backwpup"
  )

  # 除外オプションを構築
  local exclude_opts=()
  for pattern in "${excludes[@]}"; do
    exclude_opts+=("--exclude=$pattern")
  done

  rsync -av --delete -e "ssh $SSH_OPTIONS" "${exclude_opts[@]}" \
    "$PRODUCTION_USER@$PRODUCTION_HOST:$PRODUCTION_DIR/wp-content/" \
    "./wp-content"
  log_success "wp-content sync completed"
}

# ローカル環境にデータベースをインポートする
import_database() {
  log "Importing database into wp-env..."
  run_wp_cli db import /var/www/html/tmp/dump.sql
  log_success "Database import completed"
}

# データベース内のURLを置換する
replace_urls() {
  log "Replacing URLs in the database..."
  run_wp_cli search-replace "$PRODUCTION_URL" "$LOCAL_URL" --precise --recurse-objects --all-tables-with-prefix
  log_success "URL replacement completed"
}

# インポートした投稿や固定ページの著者をadminに設定する
reassign_post_authors() {
  log "Reassigning authors for posts and pages to admin..."
  run_wp_cli db query "UPDATE wp_posts SET post_author = (SELECT ID FROM wp_users WHERE user_login = 'admin' LIMIT 1) WHERE post_type IN ('post', 'page');"
  log_success "Author reassignment completed"
}

# パーマリンクの設定を更新する（リライトルールをフラッシュする）
flush_rewrite_rules() {
  log "Flushing rewrite rules (saving permalink structure)..."
  run_wp_cli rewrite flush --hard
  log_success "Rewrite rules flushed"
}

# キャッシュのクリア
clear_caches() {
  log "Clearing caches and refreshing nonces..."
  run_wp_cli cache flush || true
  run_wp_cli transient delete --all
  run_wp_cli eval "wp_cache_flush(); delete_transient('doing_cron');"
  log_success "Caches and nonces cleared"
}

# 本番環境専用プラグインを無効化する
disable_production_plugins() {
  log "Disabling production-only plugins for local environment..."

  # 無効化するプラグインのリスト
  local plugins_to_disable=(
    "cloudsecure-wp-security"
  )

  for plugin in "${plugins_to_disable[@]}"; do
    if run_wp_cli plugin is-active "$plugin" 2>/dev/null; then
      run_wp_cli plugin deactivate "$plugin"
      log_success "$plugin plugin deactivated"
    fi
  done
}

# SQLファイルのクリーンアップ
cleanup_sql_file() {
  if [ -f "tmp/dump.sql" ]; then
    log "Cleaning up SQL file..."
    rm -f "tmp/dump.sql"
    log_success "SQL file cleaned up"
  fi
}

# メインの処理の流れ
main() {
  log_info "Starting sync from production server..."

  # 環境変数チェック
  check_required_env_vars

  # SSH接続設定
  SSH_OPTIONS="-i $PRODUCTION_SSH_KEY -p $PRODUCTION_SSH_PORT"

  # 同期処理
  check_ssh_connection
  setup_local_directories
  start_local_environment
  dump_production_database
  copy_database_to_local
  sync_wp_content
  import_database
  replace_urls
  reassign_post_authors
  flush_rewrite_rules
  clear_caches
  disable_production_plugins

  # クリーンアップ
  cleanup_sql_file

  log_success "Setup complete!"
  echo ""
  log_info "Local site URL: $LOCAL_URL"
  log_info "Login URL: $LOCAL_URL/wp-login.php"
  log_info "Default credentials: admin / password"
}

main
