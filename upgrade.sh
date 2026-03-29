#!/usr/bin/env bash
# ============================================================
#  Gogs → Forgejo Upgrade Script
#  Path: Gogs → Gitea 1.0.2 → 1.2.3 → 1.4.3 → 1.5.3 → 1.6.4 → 1.22.6 → Forgejo 10.0.x → latest
#
#  Usage:
#    sudo ./upgrade.sh [OPTIONS]
#
#  Options:
#    --gogs-dir DIR          Gogs installation directory      (default: /home/git/gogs)
#    --gitea-dir DIR         Gitea/Forgejo install directory  (default: /home/git/gitea)
#    --data-dir DIR          Data root directory              (default: /home/git)
#    --user USER             OS user running the service      (default: git)
#    --db-type TYPE          Gogs DB type: mysql|postgres|sqlite3 (default: sqlite3)
#    --db-name DB            Database name (mysql/postgres only)
#    --db-user USER          Database user (mysql/postgres only)
#    --db-pass PASS          Database password (mysql/postgres only)
#    --db-host HOST          Database host:port               (default: 127.0.0.1:3306)
#    --arch ARCH             linux-amd64|linux-arm64|...      (default: linux-amd64)
#    --forgejo-latest VER    Latest Forgejo version           (default: 10.0.3)
#    --dry-run               Print steps without executing
#    --skip-backup           Skip backup (NOT recommended)
#    --resume-from STAGE     Resume from a specific stage number
#    -h, --help              Show this help
#
#  Stages:
#    1   Backup Gogs
#    2   Translate app.ini (Gogs keys → Gitea/Forgejo keys)
#    3   Gitea 1.0.2  — initial Gogs DB migration (DB v22)
#    4   Gitea 1.2.3  — DB v42
#    5   Gitea 1.4.3  — DB v54
#    6   Gitea 1.5.3  — DB v62
#    7   Gitea 1.6.4  — DB v70
#    8   Gitea 1.22.6 — DB v262 (last Gitea before Forgejo)
#    9   Forgejo 10.0.x (Gitea→Forgejo bridge)
#   10   Forgejo latest
#   11  Post-migration cleanup (drop Gogs-leftover columns)
#
#  SKIP these broken Gitea versions: 1.10.0–1.10.4, 1.10.5, 1.11.0, 1.11.1, 1.11.2
# ============================================================

set -euo pipefail

# ---------- Defaults ----------
GOGS_DIR="/home/git/gogs"
GITEA_DIR="/home/git/gitea"
DATA_DIR="/home/git"
SVC_USER="git"
DB_TYPE="sqlite3"
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_HOST="127.0.0.1:3306"
ARCH="linux-amd64"
FORGEJO_LATEST="10.0.3"
DRY_RUN=false
SKIP_BACKUP=false
RESUME_FROM=1
LOG_FILE="$(pwd)/upgrade-$(date +%Y%m%d-%H%M%S).log"

FORGEJO_BRIDGE="10.0.3"

# ---------- Colours ----------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()   { echo -e "${CYAN}[$(date +%H:%M:%S)]${RESET} $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $*"    | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*" | tee -a "$LOG_FILE"; }
die()   { echo -e "${RED}[FATAL]${RESET} $*"   | tee -a "$LOG_FILE"; exit 1; }
stage() { echo -e "\n${BOLD}${CYAN}══════ Stage $1: $2 ══════${RESET}" | tee -a "$LOG_FILE"; }

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} $*" | tee -a "$LOG_FILE"
    else
        log "CMD: $*"
        eval "$@" 2>&1 | tee -a "$LOG_FILE" || true
    fi
}

# ---------- Argument parsing ----------
while [[ $# -gt 0 ]]; do
    case $1 in
        --gogs-dir)       GOGS_DIR="$2";        shift 2 ;;
        --gitea-dir)      GITEA_DIR="$2";       shift 2 ;;
        --data-dir)       DATA_DIR="$2";        shift 2 ;;
        --user)           SVC_USER="$2";        shift 2 ;;
        --db-type)        DB_TYPE="$2";         shift 2 ;;
        --db-name)        DB_NAME="$2";         shift 2 ;;
        --db-user)        DB_USER="$2";         shift 2 ;;
        --db-pass)        DB_PASS="$2";         shift 2 ;;
        --db-host)        DB_HOST="$2";         shift 2 ;;
        --arch)           ARCH="$2";            shift 2 ;;
        --forgejo-latest) FORGEJO_LATEST="$2";  shift 2 ;;
        --dry-run)        DRY_RUN=true;         shift ;;
        --skip-backup)    SKIP_BACKUP=true;     shift ;;
        --resume-from)    RESUME_FROM="$2";     shift 2 ;;
        -h|--help)
            grep '^#  ' "$0" | sed 's/^#  //'
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ---------- Derived paths ----------
GITEA_BIN="$GITEA_DIR/gitea"
GITEA_CONF="$GITEA_DIR/custom/conf/app.ini"
GOGS_CONF="$GOGS_DIR/custom/conf/app.ini"
GOGS_DATA="$DATA_DIR/gogs-data"
GITEA_DATA="$DATA_DIR/gitea-data"
BACKUP_DIR="$DATA_DIR/upgrade-backups"
DOWNLOADS="$DATA_DIR/upgrade-downloads"

# ---------- Prerequisites ----------
check_prereqs() {
    log "Checking prerequisites..."
    command -v curl    >/dev/null 2>&1 || die "curl is required"
    command -v python3 >/dev/null 2>&1 || die "python3 is required (for app.ini translation)"
    if ! $DRY_RUN; then
        [[ -d "$GOGS_DIR" ]]  || die "Gogs directory not found: $GOGS_DIR"
        [[ -f "$GOGS_CONF" ]] || die "Gogs app.ini not found: $GOGS_CONF"
        [[ $(id -u) -eq 0 ]]  || die "Must run as root (sudo)"
    fi
    if [[ "$DB_TYPE" != "sqlite3" ]]; then
        [[ -n "$DB_NAME" ]] || die "--db-name required for $DB_TYPE"
        [[ -n "$DB_USER" ]] || die "--db-user required for $DB_TYPE"
        [[ -n "$DB_PASS" ]] || die "--db-pass required for $DB_TYPE"
    fi
    ok "Prerequisites OK"
}

# ---------- Download binary ----------
download_binary() {
    local type="$1" ver="$2" dest="$3"
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would download $type $ver → $dest" | tee -a "$LOG_FILE"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        log "Already downloaded: $dest"; return 0
    fi
    local url
    if [[ "$type" == "gitea" ]]; then
        url="https://dl.gitea.com/gitea/${ver}/gitea-${ver}-${ARCH}"
    else
        url="https://codeberg.org/forgejo/forgejo/releases/download/v${ver}/forgejo-${ver}-${ARCH}"
    fi
    log "Downloading $type $ver from $url ..."
    curl -fsSL -o "$dest" "$url" 2>&1 | tee -a "$LOG_FILE"
    chmod +x "$dest"
    ok "Downloaded: $dest"
}

# ---------- Install binary ----------
install_binary() {
    local src="$1" dest="$2"
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would install $src → $dest" | tee -a "$LOG_FILE"
        return 0
    fi
    cp "$src" "$dest"
    chown "$SVC_USER:$SVC_USER" "$dest"
    chmod +x "$dest"
    ok "Installed: $dest"
}

# ---------- Stop service ----------
stop_service() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would stop service" | tee -a "$LOG_FILE"
        return 0
    fi
    for svc in forgejo gitea gogs; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "Stopping $svc..."; systemctl stop "$svc"; return 0
        fi
    done
    warn "No active service found — skipping stop"
}

# ---------- Run DB migration (blocking) ----------
# Gitea 1.7+ has `gitea migrate` — runs all pending schema migrations
# and exits cleanly with code 0. Use this whenever available.
#
# Gitea < 1.7 (e.g. 1.0.x, 1.1.x, 1.2.x) has no migrate subcommand.
# For those, we start `web`, wait for the DB migrations to complete
# (detected via log output), then kill the process.
#
# Minimum version with migrate subcommand: 1.7.0
MIGRATE_MIN_VERSION="1.7.0"

# Compare semver strings. Returns 0 if $1 >= $2.
_semver_gte() {
    local a="$1" b="$2"
    printf '%s\n%s\n' "$b" "$a" | sort -V -C
}

run_db_migrate() {
    local bin="$1" label="$2" version="$3"

    if $DRY_RUN; then
        if _semver_gte "$version" "$MIGRATE_MIN_VERSION"; then
            echo -e "${YELLOW}[DRY-RUN]${RESET} Would run: sudo -u $SVC_USER $bin migrate --config $GITEA_CONF" | tee -a "$LOG_FILE"
        else
            echo -e "${YELLOW}[DRY-RUN]${RESET} $label < $MIGRATE_MIN_VERSION — would start web, wait for migration, then kill" | tee -a "$LOG_FILE"
        fi
        return 0
    fi

    if _semver_gte "$version" "$MIGRATE_MIN_VERSION"; then
        # --- Modern path: blocking migrate subcommand ---
        log "Running DB migration for $label (migrate subcommand)..."
        if sudo -u "$SVC_USER" "$bin" migrate --config "$GITEA_CONF" >> "$LOG_FILE" 2>&1; then
            ok "$label: DB migration OK"
        else
            die "$label: DB migration FAILED — check $LOG_FILE"
        fi
    else
        # --- Legacy path: start web, detect migration complete, kill ---
        log "Running DB migration for $label (legacy web start — version $version has no migrate subcommand)..."

        local legacy_log
        legacy_log="$(mktemp /tmp/gitea-legacy-migrate.XXXXXX.log)"

        sudo -u "$SVC_USER" "$bin" web --config "$GITEA_CONF" >> "$legacy_log" 2>&1 &
        local migration_pid=$!

        log "  Started $label web (PID $migration_pid), waiting for migration to complete..."

        # Poll the log for the marker that means migrations are done and the
        # HTTP listener is up — at that point all schema work is finished.
        local timeout=120 elapsed=0 done=false
        while (( elapsed < timeout )); do
            if grep -qE \
                'Listen|Listening|HTTPAddr|routers\.GlobalInit.*done|ORM engine|Successfully ran migration' \
                "$legacy_log" 2>/dev/null; then
                done=true
                break
            fi
            sleep 2
            (( elapsed += 2 ))
        done

        # Always kill regardless of outcome
        kill "$migration_pid" 2>/dev/null
        wait "$migration_pid" 2>/dev/null

        # Append legacy log to main log for audit trail
        cat "$legacy_log" >> "$LOG_FILE"
        rm -f "$legacy_log"

        if $done; then
            ok "$label: DB migration OK (legacy web method)"
        else
            ok "$label: DB migration timed out after ${timeout}s — check $LOG_FILE"
        fi
    fi
}

# ---------- HTTP smoke-test ----------
run_and_verify() {
    local bin="$1" label="$2"
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would verify $label HTTP response" | tee -a "$LOG_FILE"
        return 0
    fi
    log "Starting $label for HTTP smoke-test..."
    sudo -u "$SVC_USER" "$bin" web --config "$GITEA_CONF" >> "$LOG_FILE" 2>&1 &
    local server_pid=$!
    sleep 12

    local port
    port=$(grep -i '^HTTP_PORT' "$GITEA_CONF" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
    port="${port:-3000}"

    if curl -sf "http://127.0.0.1:${port}/" -o /dev/null 2>/dev/null; then
        ok "$label responding on port $port ✓"
    else
        warn "$label did not respond on :$port — check log, but continuing"
    fi

    if kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        sleep 3
        kill -9 "$server_pid" 2>/dev/null || true
    fi
}

# ============================================================
# translate_appini: convert Gogs app.ini keys to Gitea/Forgejo
# ============================================================
#
# Key mapping summary:
#
#   Gogs [database]           Gitea/Forgejo [database]
#   ─────────────────         ────────────────────────
#   type = mysql/postgres  →  DB_TYPE = mysql/postgres
#   type = sqlite3         →  DB_TYPE = sqlite3          (same value)
#   name = mydb            →  NAME    = mydb
#   user = myuser          →  USER    = myuser
#   password = mypass      →  PASSWD  = mypass
#   host = 127.0.0.1:3306  →  HOST    = 127.0.0.1:3306   (same)
#   path = /path/to/db     →  PATH    = /path/to/db      (same)
#   ssl_mode = disable     →  SSL_MODE = disable          (same)
#
#   Gogs [server]             Gitea/Forgejo [server]
#   ─────────────────         ──────────────────────
#   root_url               →  ROOT_URL
#   http_addr              →  HTTP_ADDR
#   http_port              →  HTTP_PORT
#   domain                 →  DOMAIN
#   (all others uppercased)
#
#   Gogs [repository]         Gitea/Forgejo [repository]
#   root                   →  ROOT
#   (all others uppercased)
#
#   [security], [session], [log], [cache], [mailer], etc.
#   → all keys uppercased
## ============================================================
translate_appini() {
    local src="$1" dst="$2"

    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would translate app.ini: $src → $dst" | tee -a "$LOG_FILE"
        return 0
    fi

    log "Translating app.ini: $src → $dst"
    cp "$src" "$dst"

    python3 - "$dst" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    lines = f.readlines()

KEY_MAP = {
    'database': {
        'type':      'DB_TYPE',
        'name':      'NAME',
        'user':      'USER',
        'password':  'PASSWD',
        'host':      'HOST',
        'path':      'PATH',
        'ssl_mode':  'SSL_MODE',
        'log_sql':   'LOG_SQL',
    },
    'server': {
        'root_url':            'ROOT_URL',
        'http_addr':           'HTTP_ADDR',
        'http_port':           'HTTP_PORT',
        'domain':              'DOMAIN',
        'protocol':            'PROTOCOL',
        'cert_file':           'CERT_FILE',
        'key_file':            'KEY_FILE',
        'static_root_path':    'STATIC_ROOT_PATH',
        'app_data_path':       'APP_DATA_PATH',
        'enable_gzip':         'ENABLE_GZIP',
        'landing_page':        'LANDING_PAGE',
        'ssh_domain':          'SSH_DOMAIN',
        'ssh_port':            'SSH_PORT',
        'disable_ssh':         'DISABLE_SSH',
        'start_ssh_server':    'START_SSH_SERVER',
        'offline_mode':        'OFFLINE_MODE',
        'disable_router_log':  'DISABLE_ROUTER_LOG',
        'enable_lfs_support':  'ENABLE_LFS_SUPPORT',
        'lfs_jwt_secret':      'LFS_JWT_SECRET',
        'local_root_url':      'LOCAL_ROOT_URL',
    },
    'repository': {
        'root':                'ROOT',
        'script_type':         'SCRIPT_TYPE',
        'ansi_charset':        'ANSI_CHARSET',
        'force_private':       'FORCE_PRIVATE',
        'max_creation_limit':  'MAX_CREATION_LIMIT',
        'preferred_licenses':  'PREFERRED_LICENSES',
        'disable_http_git':    'DISABLE_HTTP_GIT',
    },
}

UPPERCASE_SECTIONS = {
    'security', 'session', 'log', 'cache', 'mailer',
    'oauth2', 'webhook', 'cron', 'git', 'metrics',
    'i18n', 'markup', 'admin', 'openid', 'service',
    'picture', 'attachment', 'time', 'ui', 'api',
}

SECTION_RE = re.compile(r'^\[([^\]]+)\]')
# Match key = value, stripping any inline ; comment from the value
KV_RE      = re.compile(r'^(\s*)([a-zA-Z][a-zA-Z0-9_.]*)\s*=\s*(.*?)(?:\s*;.*)?$')

current_section = None
out = []

for line in lines:
    stripped = line.strip()

    # Skip full-line comments (both ; and # style) and blank lines
    if not stripped or stripped[0] in (';', '#'):
        continue

    sec_m = SECTION_RE.match(stripped)
    if sec_m:
        current_section = sec_m.group(1).lower().split('.')[0]
        out.append(line)
        continue

    kv_m = KV_RE.match(line)
    if kv_m and current_section:
        indent, key, value = kv_m.group(1), kv_m.group(2), kv_m.group(3)
        lkey = key.lower()

        section_map = KEY_MAP.get(current_section, {})
        if lkey in section_map:
            new_key = section_map[lkey]
        elif current_section in UPPERCASE_SECTIONS or current_section in KEY_MAP:
            new_key = key.upper()
        else:
            new_key = key  # unknown section — leave as-is

        out.append(f"{indent}{new_key} = {value}\n")
    else:
        out.append(line)

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(out)

print("Translation complete")
PYEOF

    ok "app.ini keys translated"

    # Path substitutions (gogs dirs → gitea dirs)
    log "Patching filesystem paths in app.ini..."
    sed -i 's|/gogs-repositories|/gitea-repositories|g' "$dst"
    sed -i 's|/gogs-data|/gitea-data|g'                 "$dst"
    sed -i 's|/gogs/data|/gitea/data|g'                 "$dst"
    sed -i 's|/gogs/log|/gitea/log|g'                   "$dst"
    sed -i 's|/gogs/custom|/gitea/custom|g'             "$dst"
    # Guard: bare "sqlite" is invalid in Gitea; must be "sqlite3"
    sed -i 's/^DB_TYPE = sqlite$/DB_TYPE = sqlite3/'    "$dst"

    log "Resulting [database] section:"
    awk '/^\[database\]/{ p=1 } p && /^\[/ && !/^\[database\]/{ p=0 } p' "$dst" | tee -a "$LOG_FILE"
}

# ---------- Drop Gogs leftover columns ----------
drop_gogs_columns() {
    log "Dropping Gogs-specific leftover columns..."
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would drop Gogs leftover DB columns" | tee -a "$LOG_FILE"
        return 0
    fi
    case "$DB_TYPE" in
        sqlite3)
            local db_path
            db_path=$(grep -i '^PATH' "$GITEA_CONF" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' ' || true)
            db_path="${db_path:-$GITEA_DIR/data/gitea.db}"
            if [[ ! -f "$db_path" ]]; then warn "SQLite DB not found: $db_path — skip"; return; fi
            sqlite3 "$db_path" "ALTER TABLE \`issue\` DROP \`created\`;" 2>/dev/null \
                && ok "Dropped issue.created (SQLite)" \
                || warn "issue.created already absent — OK"
            ;;
        mysql|mariadb)
            local db_host="${DB_HOST%%:*}" db_port="${DB_HOST##*:}"
            mysql -h "$db_host" -P "$db_port" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
                -e "ALTER TABLE \`issue\` DROP COLUMN \`created\`;" 2>/dev/null \
                && ok "Dropped issue.created (MySQL)" \
                || warn "issue.created already absent — OK"
            ;;
        postgres|postgresql)
            local db_host="${DB_HOST%%:*}" db_port="${DB_HOST##*:}"
            PGPASSWORD="$DB_PASS" psql -h "$db_host" -p "$db_port" \
                -U "$DB_USER" -d "$DB_NAME" \
                -c "ALTER TABLE issue DROP COLUMN IF EXISTS created;" 2>/dev/null \
                && ok "Dropped issue.created (PostgreSQL)" \
                || warn "Drop warning — check manually"
            ;;
        *)
            warn "Unknown DB type '$DB_TYPE' — skip column drop (do it manually)"
            ;;
    esac
}

# ============================================================
#                        MAIN
# ============================================================

echo -e "\n${BOLD}${CYAN}"
echo "  Gogs → Gitea → Forgejo Upgrade Script"
echo "  ══════════════════════════════════════"
echo -e "${RESET}"

log "Log:      $LOG_FILE"
log "DRY_RUN:  $DRY_RUN"
log "ARCH:     $ARCH"
log "DB_TYPE:  $DB_TYPE"
log "Resume:   stage $RESUME_FROM"
echo "──────────────────────────────────────────" | tee -a "$LOG_FILE"

check_prereqs

if ! $DRY_RUN; then
    mkdir -p "$BACKUP_DIR" "$DOWNLOADS" "$GITEA_DIR/custom/conf"
    stop_service
fi

# ── Stage 1: Backup ──────────────────────────────────────────
if [[ $RESUME_FROM -le 1 ]]; then
    stage 1 "Backup Gogs"
    if $SKIP_BACKUP; then
        warn "--skip-backup set — proceeding without backup (risky!)"
    elif $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would backup Gogs" | tee -a "$LOG_FILE"
    else
        BACKUP_TS=$(date +%Y%m%d-%H%M%S)
        sudo -u "$SVC_USER" "$GOGS_DIR/gogs" backup \
            --target "$BACKUP_DIR" \
            --archive-name "gogs-backup-${BACKUP_TS}.zip" 2>&1 | tee -a "$LOG_FILE" || {
            warn "gogs backup cmd failed; falling back to tar..."
            tar -czf "$BACKUP_DIR/gogs-fallback-${BACKUP_TS}.tar.gz" \
                "$GOGS_DIR" "${GOGS_DATA:-/nonexistent}" 2>/dev/null || true
        }
        ok "Backup done → $BACKUP_DIR"
    fi
fi

# ── Stage 2: Translate app.ini ────────────────────────────────
if [[ $RESUME_FROM -le 2 ]]; then
    stage 2 "Translate app.ini (Gogs keys → Gitea/Forgejo keys)"

    if ! $DRY_RUN; then
        mkdir -p "$GITEA_DIR/custom/conf"
    fi

    translate_appini "$GOGS_CONF" "$GITEA_CONF"

    # Copy data directories
    if [[ -d "$GOGS_DATA" ]] || $DRY_RUN; then
        run "cp -r '$GOGS_DATA/' '$GITEA_DATA/'"
    fi
    if [[ -d "$DATA_DIR/gogs-repositories" ]] || $DRY_RUN; then
        run "mv '$DATA_DIR/gogs-repositories' '$DATA_DIR/gitea-repositories'"
    fi

    # Copy custom templates/public/options
    for d in templates public; do
        [[ -d "$GOGS_DIR/custom/$d" ]] || continue
        run "cp -r '$GOGS_DIR/custom/$d' '$GITEA_DIR/custom/'"
    done
    for d in gitignore label license locale readme; do
        [[ -d "$GOGS_DIR/custom/conf/$d" ]] || continue
        run "mkdir -p '$GITEA_DIR/custom/options'"
        run "cp -r '$GOGS_DIR/custom/conf/$d' '$GITEA_DIR/custom/options/'"
    done

    if ! $DRY_RUN; then
        chown -R "$SVC_USER:$SVC_USER" "$GITEA_DIR"
    fi
    ok "Stage 2 complete"
fi

# ── Stepping stone helper ─────────────────────────────────────
# Each call: downloads binary, installs it, runs `migrate` (blocking, exit 0)
# then optionally does an HTTP smoke-test.
step() {
    local type="$1" ver="$2" stage_num="$3"
    [[ $RESUME_FROM -gt $stage_num ]] && return 0

    local label
    local bin_path
    if [[ "$type" == "forgejo" ]]; then
        label="Forgejo-${ver}"
        bin_path="$GITEA_DIR/forgejo"
    else
        label="Gitea-${ver}"
        bin_path="$GITEA_BIN"
    fi

    stage "$stage_num" "Upgrade to $label"

    local dl_path="$DOWNLOADS/${type}-${ver}-${ARCH}"
    download_binary "$type" "$ver" "$dl_path"
    install_binary  "$dl_path" "$bin_path"
    run_db_migrate  "$bin_path" "$label" "$ver"

    # Smoke-test at key milestones
    if [[ "$ver" == "1.6.4" || "$ver" == "1.22.6" || "$type" == "forgejo" ]]; then
        run_and_verify "$bin_path" "$label"
    fi

    ok "Stage $stage_num ($label) complete"
}

# ── Stepping stones ───────────────────────────────────────────
# Why these exact stops — Gitea DB version checkpoints:
#   1.0.2  → DB v22  (migrates from Gogs; MUST be first)
#   1.2.3  → DB v42  (jump from 1.0 skips 1.1, OK per docs)
#   1.4.3  → DB v54
#   1.5.3  → DB v62
#   1.6.4  → DB v70  (if you skip any of the above you'll hit the v70 <=70 error)
#   1.22.6 → DB v262 (safe to jump from 1.6.4 per Forgejo docs)
#   Forgejo 10.0.x → accepts any Gitea ≤ 1.22 data

step gitea   "1.0.2"           3
step gitea   "1.2.3"           4
step gitea   "1.4.3"           5
step gitea   "1.5.3"           6
step gitea   "1.6.4"           7
step gitea   "1.22.6"          8
step forgejo "$FORGEJO_BRIDGE" 9

if [[ "$FORGEJO_LATEST" != "$FORGEJO_BRIDGE" ]]; then
    step forgejo "$FORGEJO_LATEST" 10
fi

# ── Stage 11: Cleanup ─────────────────────────────────────────
if [[ $RESUME_FROM -le 11 ]]; then
    stage 11 "Post-migration cleanup"

    drop_gogs_columns

    FORGEJO_BIN="$GITEA_DIR/forgejo"

    if ! $DRY_RUN && [[ -f /etc/systemd/system/gitea.service ]]; then
        sed -i "s|ExecStart=.*|ExecStart=$FORGEJO_BIN|g" /etc/systemd/system/gitea.service
        systemctl daemon-reload
        ok "Updated gitea.service ExecStart → $FORGEJO_BIN"
    elif $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would update gitea.service → $FORGEJO_BIN" | tee -a "$LOG_FILE"
    fi

    log ""
    log "══════════════════════════════════════════════════"
    ok  " Migration complete! Post-flight checklist:"
    log "══════════════════════════════════════════════════"
    log " 1. Start:    systemctl start gitea"
    log " 2. Health:   sudo -u $SVC_USER $FORGEJO_BIN doctor check --all --log-file /tmp/doctor.log"
    log " 3. Admin UI: /-/admin/self-check → regenerate authorized_keys"
    log " 4. Re-create API tokens (scopes changed in Forgejo)"
    log " 5. Disable:  systemctl disable --now gogs"
    log " 6. Log:      $LOG_FILE"
    log "══════════════════════════════════════════════════"
fi

exit 0
