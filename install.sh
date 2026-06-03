#!/bin/bash
set -euo pipefail

# OpenClaw 安装器（macOS + Linux）
# 用法：curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash

BOLD='\033[1m'
ACCENT='\033[38;2;255;77;77m'       # coral-bright  #ff4d4d
# shellcheck disable=SC2034
ACCENT_BRIGHT='\033[38;2;255;110;110m' # lighter coral
INFO='\033[38;2;136;146;176m'       # text-secondary #8892b0
SUCCESS='\033[38;2;0;229;204m'      # cyan-bright   #00e5cc
WARN='\033[38;2;255;176;32m'        # amber (no site equiv, keep warm)
ERROR='\033[38;2;230;57;70m'        # coral-mid     #e63946
MUTED='\033[38;2;90;100;128m'       # text-muted    #5a6480
NC='\033[0m' # No Color

DEFAULT_TAGLINE="所有聊天，尽在 OpenClaw。"
NODE_DEFAULT_MAJOR=24
NODE_MIN_MAJOR=22
NODE_MIN_MINOR=19
NODE_MIN_VERSION="${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}"

ORIGINAL_PATH="${PATH:-}"

TMPFILES=()
cleanup_tmpfiles() {
    local f
    for f in "${TMPFILES[@]:-}"; do
        rm -rf "$f" 2>/dev/null || true
    done
}
trap cleanup_tmpfiles EXIT

mktempfile() {
    local f
    f="$(mktemp)"
    TMPFILES+=("$f")
    echo "$f"
}

resolve_openclaw_effective_home() {
    local openclaw_home="${OPENCLAW_HOME:-}"
    if [[ -z "$openclaw_home" ]]; then
        echo "$HOME"
        return
    fi
    if [[ "$openclaw_home" == "~" ]]; then
        echo "$HOME"
        return
    fi
    if [[ "$openclaw_home" == \~/* ]]; then
        echo "${HOME}${openclaw_home:1}"
        return
    fi
    echo "$openclaw_home"
}

DOWNLOADER=""
detect_downloader() {
    if command -v curl &> /dev/null; then
        DOWNLOADER="curl"
        return 0
    fi
    if command -v wget &> /dev/null; then
        DOWNLOADER="wget"
        return 0
    fi
    ui_error "缺少下载工具（需要 curl 或 wget）"
    exit 1
}

download_file() {
    local url="$1"
    local output="$2"
    if [[ -z "$DOWNLOADER" ]]; then
        detect_downloader
    fi
    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --retry-connrefused -o "$output" "$url"
        return
    fi
    wget -q --https-only --secure-protocol=TLSv1_2 --tries=3 --timeout=20 -O "$output" "$url"
}

run_remote_bash() {
    local url="$1"
    local tmp
    tmp="$(mktempfile)"
    download_file "$url" "$tmp"
    /bin/bash "$tmp"
}

GUM_VERSION="${OPENCLAW_GUM_VERSION:-0.17.0}"
GUM=""
GUM_STATUS="skipped"
GUM_REASON=""
LAST_NPM_INSTALL_CMD=""

is_non_interactive_shell() {
    if [[ "${NO_PROMPT:-0}" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        return 0
    fi
    return 1
}

has_controlling_tty() {
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        return 1
    fi
    if ! { : </dev/tty; } 2>/dev/null; then
        return 1
    fi
    return 0
}

gum_is_tty() {
    if [[ -n "${NO_COLOR:-}" ]]; then
        return 1
    fi
    if [[ "${TERM:-dumb}" == "dumb" ]]; then
        return 1
    fi
    if [[ -t 2 || -t 1 ]]; then
        return 0
    fi
    if has_controlling_tty; then
        return 0
    fi
    return 1
}

gum_detect_os() {
    case "$(uname -s 2>/dev/null || true)" in
        Darwin) echo "Darwin" ;;
        Linux) echo "Linux" ;;
        *) echo "unsupported" ;;
    esac
}

gum_detect_arch() {
    case "$(uname -m 2>/dev/null || true)" in
        x86_64|amd64) echo "x86_64" ;;
        arm64|aarch64) echo "arm64" ;;
        i386|i686) echo "i386" ;;
        armv7l|armv7) echo "armv7" ;;
        armv6l|armv6) echo "armv6" ;;
        *) echo "unknown" ;;
    esac
}

verify_sha256sum_file() {
    local checksums="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum --ignore-missing -c "$checksums" >/dev/null 2>&1
        return $?
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 --ignore-missing -c "$checksums" >/dev/null 2>&1
        return $?
    fi
    return 1
}

bootstrap_gum_temp() {
    GUM=""
    GUM_STATUS="skipped"
    GUM_REASON=""

    if is_non_interactive_shell; then
        GUM_REASON="non-interactive shell (auto-disabled)"
        return 1
    fi

    if ! gum_is_tty; then
        GUM_REASON="终端不支持 gum UI"
        return 1
    fi

    if command -v gum >/dev/null 2>&1; then
        GUM="gum"
        GUM_STATUS="found"
        GUM_REASON="已安装"
        return 0
    fi

    if ! command -v tar >/dev/null 2>&1; then
        GUM_REASON="未找到 tar"
        return 1
    fi

    local os arch asset base gum_tmpdir gum_path
    os="$(gum_detect_os)"
    arch="$(gum_detect_arch)"
    if [[ "$os" == "unsupported" || "$arch" == "unknown" ]]; then
        GUM_REASON="不支持的操作系统/架构（$os/$arch）"
        return 1
    fi

    asset="gum_${GUM_VERSION}_${os}_${arch}.tar.gz"
    base="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}"

    gum_tmpdir="$(mktemp -d)"
    TMPFILES+=("$gum_tmpdir")

    ui_info "准备加载动画支持"
    if ! download_file "${base}/${asset}" "$gum_tmpdir/$asset"; then
        GUM_REASON="下载失败"
        return 1
    fi

    ui_info "验证加载动画下载"
    if ! download_file "${base}/checksums.txt" "$gum_tmpdir/checksums.txt"; then
        GUM_REASON="校验和不可用或失败"
        return 1
    fi

    if ! (cd "$gum_tmpdir" && verify_sha256sum_file "checksums.txt"); then
        GUM_REASON="校验和不可用或失败"
        return 1
    fi

    if ! tar -xzf "$gum_tmpdir/$asset" -C "$gum_tmpdir" >/dev/null 2>&1; then
        GUM_REASON="解压失败"
        return 1
    fi

    gum_path="$(find "$gum_tmpdir" -type f -name gum 2>/dev/null | head -n1 || true)"
    if [[ -z "$gum_path" ]]; then
        GUM_REASON="gum 二进制文件解压后缺失"
        return 1
    fi

    chmod +x "$gum_path" >/dev/null 2>&1 || true
    if [[ ! -x "$gum_path" ]]; then
        GUM_REASON="gum 二进制文件不可执行"
        return 1
    fi

    GUM="$gum_path"
    GUM_STATUS="installed"
    GUM_REASON="临时，已验证"
    return 0
}

print_gum_status() {
    case "$GUM_STATUS" in
        found)
            ui_success "gum 可用（${GUM_REASON}）"
            ;;
        installed)
            ui_success "gum 已引导（${GUM_REASON}, v${GUM_VERSION}）"
            ;;
        *)
            if [[ -n "$GUM_REASON" && "$GUM_REASON" != "non-interactive shell (auto-disabled)" ]]; then
                ui_info "gum 已跳过（${GUM_REASON}）"
            fi
            ;;
    esac
}

print_installer_banner() {
    if [[ -n "$GUM" ]]; then
        local title tagline hint card
        title="$("$GUM" style --foreground "#ff4d4d" --bold "🦞 OpenClaw 安装器")"
        tagline="$("$GUM" style --foreground "#8892b0" "$TAGLINE")"
        hint="$("$GUM" style --foreground "#5a6480" "现代化安装模式")"
        card="$(printf '%s\n%s\n%s' "$title" "$tagline" "$hint")"
        "$GUM" style --border rounded --border-foreground "#ff4d4d" --padding "1 2" "$card"
        echo ""
        return
    fi

    echo -e "${ACCENT}${BOLD}"
    echo "  🦞 OpenClaw Installer"
    echo -e "${NC}${INFO}  ${TAGLINE}${NC}"
    echo ""
}

detect_os_or_die() {
    OS="unknown"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    elif [[ "$OSTYPE" == "linux"* ]] || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        OS="linux"
    fi

    if [[ "$OS" == "unknown" ]]; then
        ui_error "不支持的操作系统"
        echo "本安装器支持 macOS 和 Linux（含 WSL）。"
        echo "Windows 用户请用：iwr -useb https://openclaw.ai/install.ps1 | iex"
        exit 1
    fi

    ui_success "检测到操作系统：$OS"
}

ui_info() {
    local msg="$*"
    if [[ -n "$GUM" ]]; then
        "$GUM" log --level info "$msg"
    else
        echo -e "${MUTED}·${NC} ${msg}"
    fi
}

ui_warn() {
    local msg="$*"
    if [[ -n "$GUM" ]]; then
        "$GUM" log --level warn "$msg"
    else
        echo -e "${WARN}!${NC} ${msg}"
    fi
}

ui_success() {
    local msg="$*"
    if [[ -n "$GUM" ]]; then
        local mark
        mark="$("$GUM" style --foreground "#00e5cc" --bold "✓")"
        echo "${mark} ${msg}"
    else
        echo -e "${SUCCESS}✓${NC} ${msg}"
    fi
}

ui_error() {
    local msg="$*"
    if [[ -n "$GUM" ]]; then
        "$GUM" log --level error "$msg"
    else
        echo -e "${ERROR}✗${NC} ${msg}"
    fi
}

INSTALL_STAGE_TOTAL=3
INSTALL_STAGE_CURRENT=0

configure_install_stage_total() {
    INSTALL_STAGE_TOTAL=3
    INSTALL_STAGE_CURRENT=0
    if [[ "${VERIFY_INSTALL:-0}" == "1" ]]; then
        INSTALL_STAGE_TOTAL=4
    fi
}

ui_section() {
    local title="$1"
    if [[ -n "$GUM" ]]; then
        "$GUM" style --bold --foreground "#ff4d4d" --padding "1 0" "$title"
    else
        echo ""
        echo -e "${ACCENT}${BOLD}${title}${NC}"
    fi
}

ui_stage() {
    local title="$1"
    INSTALL_STAGE_CURRENT=$((INSTALL_STAGE_CURRENT + 1))
    ui_section "[${INSTALL_STAGE_CURRENT}/${INSTALL_STAGE_TOTAL}] ${title}"
}

ui_kv() {
    local key="$1"
    local value="$2"
    if [[ -n "$GUM" ]]; then
        local key_part value_part
        key_part="$("$GUM" style --foreground "#5a6480" --width 20 "$key")"
        value_part="$("$GUM" style --bold "$value")"
        "$GUM" join --horizontal "$key_part" "$value_part"
    else
        echo -e "${MUTED}${key}:${NC} ${value}"
    fi
}

ui_panel() {
    local content="$1"
    if [[ -n "$GUM" ]]; then
        "$GUM" style --border rounded --border-foreground "#5a6480" --padding "0 1" "$content"
    else
        echo "$content"
    fi
}

show_install_plan() {
    local detected_checkout="$1"

    ui_section "安装计划"
    ui_kv "操作系统" "$OS"
    ui_kv "安装方式" "$INSTALL_METHOD"
    ui_kv "请求版本" "$OPENCLAW_VERSION"
    if [[ "$USE_BETA" == "1" ]]; then
        ui_kv "测试频道" "已启用"
    fi
    if [[ "$INSTALL_METHOD" == "git" ]]; then
        ui_kv "Git 目录" "$GIT_DIR"
        ui_kv "Git 更新" "$GIT_UPDATE"
    fi
    if [[ -n "$detected_checkout" ]]; then
        ui_kv "检测到的本地仓库" "$detected_checkout"
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_kv "试运行" "是"
    fi
    if [[ "$NO_ONBOARD" == "1" ]]; then
        ui_kv "初次设置" "已跳过"
    fi
}

show_footer_links() {
    local faq_url="https://docs.openclaw.ai/start/faq"
    if [[ -n "$GUM" ]]; then
        local content
        content="$(printf '%s\n%s' "需要帮助？" "FAQ: ${faq_url}")"
        ui_panel "$content"
    else
        echo ""
        echo -e "FAQ: ${INFO}${faq_url}${NC}"
    fi
}

ui_celebrate() {
    local msg="$1"
    if [[ -n "$GUM" ]]; then
        "$GUM" style --bold --foreground "#00e5cc" "$msg"
    else
        echo -e "${SUCCESS}${BOLD}${msg}${NC}"
    fi
}

is_shell_function() {
    local name="${1:-}"
    [[ -n "$name" ]] && declare -F "$name" >/dev/null 2>&1
}

is_gum_raw_mode_failure() {
    local err_log="$1"
    [[ -s "$err_log" ]] || return 1
    grep -Eiq 'setrawmode|inappropriate ioctl' "$err_log"
}

run_with_spinner() {
    local title="$1"
    shift

    if [[ -n "$GUM" ]] && gum_is_tty && ! is_shell_function "${1:-}"; then
        local gum_err gum_out
        gum_err="$(mktempfile)"
        gum_out="$(mktempfile)"
        if "$GUM" spin --spinner dot --title "$title" -- "$@" >"$gum_out" 2>"$gum_err"; then
            if is_gum_raw_mode_failure "$gum_out" || is_gum_raw_mode_failure "$gum_err"; then
                GUM=""
                GUM_STATUS="skipped"
                GUM_REASON="gum 原始模式不可用"
                ui_warn "此终端不支持加载动画；继续执行"
                "$@"
                return $?
            fi
            if [[ -s "$gum_out" ]]; then
                cat "$gum_out"
            fi
            return 0
        fi
        local gum_status=$?
        if is_gum_raw_mode_failure "$gum_err" || is_gum_raw_mode_failure "$gum_out"; then
            GUM=""
            GUM_STATUS="skipped"
            GUM_REASON="gum 原始模式不可用"
            ui_warn "此终端不支持加载动画；继续执行"
            "$@"
            return $?
        fi
        if [[ -s "$gum_err" ]]; then
            cat "$gum_err" >&2
        fi
        return "$gum_status"
    fi

    "$@"
}

run_quiet_step() {
    local title="$1"
    shift

    if [[ "$VERBOSE" == "1" ]]; then
        run_with_spinner "$title" "$@"
        return $?
    fi

    local log
    log="$(mktempfile)"
    local showed_progress=false

    if [[ -n "$GUM" ]] && gum_is_tty && ! is_shell_function "${1:-}"; then
        local cmd_quoted=""
        local log_quoted=""
        printf -v cmd_quoted '%q ' "$@"
        printf -v log_quoted '%q' "$log"
        if run_with_spinner "$title" bash -c "${cmd_quoted}>${log_quoted} 2>&1"; then
            return 0
        fi
        showed_progress=true
    else
        # Keep users informed even when gum spinner cannot run (for example shell functions).
        ui_info "${title}"
        showed_progress=true
        if "$@" >"$log" 2>&1; then
            return 0
        fi
    fi

    if [[ "$showed_progress" == "false" ]]; then
        ui_info "${title}"
    fi

    ui_error "${title} failed — re-run with --verbose for details"
    if [[ -s "$log" ]]; then
        tail -n 80 "$log" >&2 || true
    fi
    return 1
}

cleanup_legacy_submodules() {
    local repo_dir="$1"
    local legacy_dir="$repo_dir/Peekaboo"
    if [[ -d "$legacy_dir" ]]; then
        ui_info "移除旧子模块：${legacy_dir}"
        rm -rf "$legacy_dir"
    fi
}

cleanup_npm_openclaw_paths() {
    local npm_root=""
    npm_root="$(npm root -g 2>/dev/null || true)"
    if [[ -z "$npm_root" || "$npm_root" != *node_modules* ]]; then
        return 1
    fi
    rm -rf "$npm_root"/.openclaw-* "$npm_root"/openclaw 2>/dev/null || true
}

extract_openclaw_conflict_path() {
    local log="$1"
    local path=""
    path="$(sed -n 's/.*File exists: //p' "$log" | head -n1)"
    if [[ -z "$path" ]]; then
        path="$(sed -n 's/.*EEXIST: file already exists, //p' "$log" | head -n1)"
    fi
    if [[ -n "$path" ]]; then
        echo "$path"
        return 0
    fi
    return 1
}

cleanup_openclaw_bin_conflict() {
    local bin_path="$1"
    if [[ -z "$bin_path" || ( ! -e "$bin_path" && ! -L "$bin_path" ) ]]; then
        return 1
    fi
    local npm_bin=""
    npm_bin="$(npm_global_bin_dir 2>/dev/null || true)"
    if [[ -n "$npm_bin" && "$bin_path" != "$npm_bin/openclaw" ]]; then
        case "$bin_path" in
            "/opt/homebrew/bin/openclaw"|"/usr/local/bin/openclaw")
                ;;
            *)
                return 1
                ;;
        esac
    fi
    if [[ -L "$bin_path" ]]; then
        local target=""
        target="$(readlink "$bin_path" 2>/dev/null || true)"
        if [[ "$target" == *"/node_modules/openclaw/"* ]]; then
            rm -f "$bin_path"
            ui_info "已移除过期 openclaw 符号链接：${bin_path}"
            return 0
        fi
        return 1
    fi
    local backup=""
    backup="${bin_path}.bak-$(date +%Y%m%d-%H%M%S)"
    if mv "$bin_path" "$backup"; then
        ui_info "已将现有 openclaw 二进制文件移至 ${backup}"
        return 0
    fi
    return 1
}

npm_log_indicates_missing_build_tools() {
    local log="$1"
    if [[ -z "$log" || ! -f "$log" ]]; then
        return 1
    fi

    grep -Eiq "(not found: make|make: command not found|cmake: command not found|CMAKE_MAKE_PROGRAM is not set|Could not find CMAKE|gyp ERR! find Python|no developer tools were found|is not able to compile a simple test program|Failed to build llama\\.cpp|It seems that \"make\" is not installed in your system|It seems that the used \"cmake\" doesn't work properly)" "$log"
}

# Detect Arch-based distributions (Arch Linux, Manjaro, EndeavourOS, etc.)
is_arch_linux() {
    if [[ -f /etc/os-release ]]; then
        local os_id
        os_id="$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)"
        case "$os_id" in
            arch|manjaro|endeavouros|arcolinux|garuda|archarm|cachyos|archcraft)
                return 0
                ;;
        esac
        # Also check ID_LIKE for Arch derivatives
        local os_id_like
        os_id_like="$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)"
        if [[ "$os_id_like" == *arch* ]]; then
            return 0
        fi
    fi
    # Fallback: check for pacman
    if command -v pacman &> /dev/null; then
        return 0
    fi
    return 1
}

is_alpine_linux() {
    if [[ -f /etc/alpine-release ]]; then
        return 0
    fi
    if [[ -f /etc/os-release ]]; then
        local os_id os_id_like
        os_id="$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)"
        os_id_like="$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)"
        if [[ "$os_id" == "alpine" || "$os_id_like" == *alpine* ]]; then
            return 0
        fi
    fi
    return 1
}

apt_get() {
    if is_root; then
        env DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}" NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}" apt-get "$@"
    else
        sudo env DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}" NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}" apt-get "$@"
    fi
}

apt_get_update() {
    apt_get update -qq
}

apt_get_install() {
    apt_get install -y -qq \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

install_build_tools_linux() {
    require_sudo

    if command -v apt-get &> /dev/null; then
        run_quiet_step "更新软件包索引" apt_get_update
        run_quiet_step "安装编译工具" apt_get_install build-essential python3 make g++ cmake
        return 0
    fi

    if command -v pacman &> /dev/null || is_arch_linux; then
        if is_root; then
            run_quiet_step "安装编译工具" pacman -Sy --noconfirm base-devel python make cmake gcc
        else
            run_quiet_step "安装编译工具" sudo pacman -Sy --noconfirm base-devel python make cmake gcc
        fi
        return 0
    fi

    if command -v dnf &> /dev/null; then
        if is_root; then
            run_quiet_step "安装编译工具" dnf install -y -q gcc gcc-c++ make cmake python3
        else
            run_quiet_step "安装编译工具" sudo dnf install -y -q gcc gcc-c++ make cmake python3
        fi
        return 0
    fi

    if command -v yum &> /dev/null; then
        if is_root; then
            run_quiet_step "安装编译工具" yum install -y -q gcc gcc-c++ make cmake python3
        else
            run_quiet_step "安装编译工具" sudo yum install -y -q gcc gcc-c++ make cmake python3
        fi
        return 0
    fi

    if command -v apk &> /dev/null && is_alpine_linux; then
        if is_root; then
            run_quiet_step "安装编译工具" apk add --no-cache build-base python3 cmake
        else
            run_quiet_step "安装编译工具" sudo apk add --no-cache build-base python3 cmake
        fi
        return 0
    fi

    ui_warn "无法检测包管理器以自动安装编译工具"
    return 1
}

install_build_tools_macos() {
    local ok=true

    if ! xcode-select -p >/dev/null 2>&1; then
        ui_info "安装 Xcode 命令行工具（make/clang 需要）"
        xcode-select --install >/dev/null 2>&1 || true
        if ! xcode-select -p >/dev/null 2>&1; then
            ui_warn "Xcode 命令行工具尚未就绪"
            ui_info "请完成安装对话框，然后重新运行此安装器"
            ok=false
        fi
    fi

    if ! command -v cmake >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
            run_quiet_step "安装 cmake" brew install cmake
        else
            ui_warn "Homebrew 不可用；无法自动安装 cmake"
            ok=false
        fi
    fi

    if ! command -v make >/dev/null 2>&1; then
        ui_warn "make is still unavailable"
        ok=false
    fi
    if ! command -v cmake >/dev/null 2>&1; then
        ui_warn "cmake is still unavailable"
        ok=false
    fi

    [[ "$ok" == "true" ]]
}

auto_install_build_tools_for_npm_failure() {
    local log="$1"
    if ! npm_log_indicates_missing_build_tools "$log"; then
        return 1
    fi

    ui_warn "检测到缺少本地编译工具；尝试自动安装"
    if [[ "$OS" == "linux" ]]; then
        install_build_tools_linux || return 1
    elif [[ "$OS" == "macos" ]]; then
        install_build_tools_macos || return 1
    else
        return 1
    fi
    ui_success "编译工具安装完成"
    return 0
}

resolve_npm_config_path() {
    local raw="$1"
    if [[ -z "$raw" || "$raw" == "null" || "$raw" == "undefined" ]]; then
        return 1
    fi
    if [[ "$raw" == \~/* && -n "${HOME:-}" ]]; then
        printf '%s\n' "${HOME}/${raw#"~/"}"
        return 0
    fi
    if [[ "$raw" == "\${HOME}/"* && -n "${HOME:-}" ]]; then
        printf '%s\n' "${HOME}/${raw#"\${HOME}/"}"
        return 0
    fi
    printf '%s\n' "$raw"
}

npm_config_file_has_key() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 1
    grep -Eiq "^[[:space:]]*${key}[[:space:]]*=" "$file"
}

npm_command_path() {
    local npm_cmd="$1"
    local npm_path="$npm_cmd"
    if [[ "$npm_path" != */* ]]; then
        npm_path="$(command -v "$npm_cmd" 2>/dev/null)" || return 1
    fi
    if command -v node >/dev/null 2>&1; then
        node -e 'const fs = require("node:fs"); console.log(fs.realpathSync(process.argv[1]));' "$npm_path" 2>/dev/null && return 0
    fi
    printf '%s\n' "$npm_path"
}

npm_builtin_config_path() {
    local npm_cmd="$1"
    local npm_path
    npm_path="$(npm_command_path "$npm_cmd")" || return 1
    local npm_root
    npm_root="$(cd "$(dirname "$npm_path")/.." >/dev/null 2>&1 && pwd -P)" || return 1
    printf '%s\n' "${npm_root}/npmrc"
}

npm_config_has_raw_key() {
    local npm_cmd="$1"
    local key="$2"
    local raw=""
    local file=""
    local -a files=()

    raw="${NPM_CONFIG_USERCONFIG:-${npm_config_userconfig:-}}"
    if [[ -n "$raw" ]]; then
        file="$(resolve_npm_config_path "$raw" 2>/dev/null || true)"
        [[ -n "$file" ]] && files+=("$file")
    elif [[ -n "${HOME:-}" ]]; then
        files+=("${HOME}/.npmrc")
    fi

    raw="${NPM_CONFIG_GLOBALCONFIG:-${npm_config_globalconfig:-}}"
    if [[ -n "$raw" ]]; then
        file="$(resolve_npm_config_path "$raw" 2>/dev/null || true)"
        [[ -n "$file" ]] && files+=("$file")
    fi

    raw="$(env -u NPM_CONFIG_BEFORE -u npm_config_before -u NPM_CONFIG_MIN_RELEASE_AGE -u npm_config_min_release_age -u npm_config_min-release-age "$npm_cmd" config get globalconfig --global 2>/dev/null || true)"
    file="$(resolve_npm_config_path "$raw" 2>/dev/null || true)"
    [[ -n "$file" ]] && files+=("$file")

    file="$(npm_builtin_config_path "$npm_cmd" 2>/dev/null || true)"
    [[ -n "$file" ]] && files+=("$file")

    for file in "${files[@]}"; do
        if npm_config_file_has_key "$file" "$key"; then
            return 0
        fi
    done
    return 1
}

run_npm_global_install() {
    local spec="$1"
    local log="$2"

    local freshness_flag="--min-release-age=0"
    local min_release_age=""
    min_release_age="$(env -u NPM_CONFIG_BEFORE -u npm_config_before npm config get min-release-age --global 2>/dev/null || true)"
    if npm_config_has_raw_key npm "min-release-age"; then
        freshness_flag="--min-release-age=0"
    elif [[ -z "$min_release_age" || "$min_release_age" == "null" || "$min_release_age" == "undefined" ]]; then
        local before_value=""
        before_value="$(env -u NPM_CONFIG_MIN_RELEASE_AGE -u npm_config_min_release_age -u npm_config_min-release-age npm config get before --global 2>/dev/null || true)"
        if [[ -n "$before_value" && "$before_value" != "null" && "$before_value" != "undefined" ]]; then
            freshness_flag="--before=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')"
        fi
    fi

    local -a cmd
    cmd=(env -u NPM_CONFIG_BEFORE -u npm_config_before -u NPM_CONFIG_MIN_RELEASE_AGE -u npm_config_min_release_age -u npm_config_min-release-age npm --loglevel "$NPM_LOGLEVEL")
    if [[ -n "$NPM_SILENT_FLAG" ]]; then
        cmd+=("$NPM_SILENT_FLAG")
    fi
    cmd+=(--no-fund --no-audit "$freshness_flag" install -g "$spec")
    local cmd_display=""
    printf -v cmd_display '%q ' "${cmd[@]}"
    LAST_NPM_INSTALL_CMD="${cmd_display% }"

    if [[ "$VERBOSE" == "1" ]]; then
        "${cmd[@]}" 2>&1 | tee "$log"
        return $?
    fi

    if [[ -n "$GUM" ]] && gum_is_tty; then
        local cmd_quoted=""
        local log_quoted=""
        printf -v cmd_quoted '%q ' "${cmd[@]}"
        printf -v log_quoted '%q' "$log"
        run_with_spinner "安装 OpenClaw 包" bash -c "${cmd_quoted}>${log_quoted} 2>&1"
        return $?
    fi

    ui_info "安装 OpenClaw 包"
    "${cmd[@]}" >"$log" 2>&1
}

extract_npm_debug_log_path() {
    local log="$1"
    local path=""
    path="$(sed -n -E 's/.*A complete log of this run can be found in:[[:space:]]*//p' "$log" | tail -n1)"
    if [[ -n "$path" ]]; then
        echo "$path"
        return 0
    fi

    path="$(grep -Eo '/[^[:space:]]+_logs/[^[:space:]]+debug[^[:space:]]*\.log' "$log" | tail -n1 || true)"
    if [[ -n "$path" ]]; then
        echo "$path"
        return 0
    fi

    return 1
}

extract_first_npm_error_line() {
    local log="$1"
    grep -E 'npm (ERR!|error)|ERR!' "$log" | head -n1 || true
}

extract_npm_error_code() {
    local log="$1"
    sed -n -E 's/^npm (ERR!|error) code[[:space:]]+([^[:space:]]+).*$/\2/p' "$log" | head -n1
}

extract_npm_error_syscall() {
    local log="$1"
    sed -n -E 's/^npm (ERR!|error) syscall[[:space:]]+(.+)$/\2/p' "$log" | head -n1
}

extract_npm_error_errno() {
    local log="$1"
    sed -n -E 's/^npm (ERR!|error) errno[[:space:]]+(.+)$/\2/p' "$log" | head -n1
}

print_npm_failure_diagnostics() {
    local spec="$1"
    local log="$2"
    local debug_log=""
    local first_error=""
    local error_code=""
    local error_syscall=""
    local error_errno=""

    ui_warn "npm 安装 ${spec} 失败"
    if [[ -n "${LAST_NPM_INSTALL_CMD}" ]]; then
        echo "  Command: ${LAST_NPM_INSTALL_CMD}"
    fi
    echo "  Installer log: ${log}"

    error_code="$(extract_npm_error_code "$log")"
    if [[ -n "$error_code" ]]; then
        echo "  npm code: ${error_code}"
    fi

    error_syscall="$(extract_npm_error_syscall "$log")"
    if [[ -n "$error_syscall" ]]; then
        echo "  npm syscall: ${error_syscall}"
    fi

    error_errno="$(extract_npm_error_errno "$log")"
    if [[ -n "$error_errno" ]]; then
        echo "  npm errno: ${error_errno}"
    fi

    debug_log="$(extract_npm_debug_log_path "$log" || true)"
    if [[ -n "$debug_log" ]]; then
        echo "  npm debug log: ${debug_log}"
    fi

    first_error="$(extract_first_npm_error_line "$log")"
    if [[ -n "$first_error" ]]; then
        echo "  First npm error: ${first_error}"
    fi
}

install_openclaw_npm() {
    local spec="$1"
    local log
    log="$(mktempfile)"
    if ! run_npm_global_install "$spec" "$log"; then
        local attempted_build_tool_fix=false
        if auto_install_build_tools_for_npm_failure "$log"; then
            attempted_build_tool_fix=true
            ui_info "构建工具安装后重试 npm 安装"
            if run_npm_global_install "$spec" "$log"; then
                ui_success "OpenClaw npm 包已安装"
                return 0
            fi
        fi

        print_npm_failure_diagnostics "$spec" "$log"

        if [[ "$VERBOSE" != "1" ]]; then
            if [[ "$attempted_build_tool_fix" == "true" ]]; then
                ui_warn "构建工具安装后 npm 仍失败；显示最后日志行"
            else
                ui_warn "npm 安装失败；显示最后日志行"
            fi
            tail -n 80 "$log" >&2 || true
        fi

        if grep -q "ENOTEMPTY: directory not empty, rename .*openclaw" "$log"; then
            ui_warn "npm 留下了过期目录；清理后重试"
            cleanup_npm_openclaw_paths
            if run_npm_global_install "$spec" "$log"; then
                ui_success "OpenClaw npm 包已安装"
                return 0
            fi
            return 1
        fi
        if grep -q "EEXIST" "$log"; then
            local conflict=""
            conflict="$(extract_openclaw_conflict_path "$log" || true)"
            if [[ -n "$conflict" ]] && cleanup_openclaw_bin_conflict "$conflict"; then
                if run_npm_global_install "$spec" "$log"; then
                    ui_success "OpenClaw npm 包已安装"
                    return 0
                fi
                return 1
            fi
            ui_error "npm 因已存在 openclaw 二进制文件而失败"
            if [[ -n "$conflict" ]]; then
                ui_info "请移除或移动 ${conflict}，然后重试"
            fi
            ui_info "或使用以下命令重试：npm install -g --force ${spec}"
        fi
        return 1
    fi
    ui_success "OpenClaw npm 包已安装"
    return 0
}

TAGLINES=()
TAGLINES+=("你的终端刚长了钳子——输入点什么，让机器人夹走那些琐事。")
TAGLINES+=("欢迎来到命令行：梦想在这里编译，自信在这里段错误。")
TAGLINES+=("I run on caffeine, JSON5, and the audacity of \"it worked on my machine.\"")
TAGLINES+=("网关在线——请随时将手、脚和附属肢体保持在 shell 内。")
TAGLINES+=("我说流利的 bash、轻微的讽刺和激进的 Tab 补全能量。")
TAGLINES+=("一个 CLI 统治一切，然后因为改了端口再多重启一次。")
TAGLINES+=("If it works, it's automation; if it breaks, it's a \"learning opportunity.\"")
TAGLINES+=("配对码存在是因为连机器人都相信同意原则——以及良好的安全习惯。")
TAGLINES+=("Your .env is showing; don't worry, I'll pretend I didn't see it.")
TAGLINES+=("I'll do the boring stuff while you dramatically stare at the logs like it's cinema.")
TAGLINES+=("I'm not saying your workflow is chaotic... I'm just bringing a linter and a helmet.")
TAGLINES+=("自信地输入命令——需要的话，自然会提供堆栈跟踪。")
TAGLINES+=("I don't judge, but your missing API keys are absolutely judging you.")
TAGLINES+=("我可以 grep 它、git blame 它，并温柔地吐槽它——选择你的应对方式。")
TAGLINES+=("配置热重载，部署冷汗流。")
TAGLINES+=("I'm the assistant your terminal demanded, not the one your sleep schedule requested.")
TAGLINES+=("我保守秘密如金库……除非你又把它们打印到调试日志里。")
TAGLINES+=("带钳子的自动化：最小麻烦，最大力度。")
TAGLINES+=("I'm basically a Swiss Army knife, but with more opinions and fewer sharp edges.")
TAGLINES+=("If you're lost, run doctor; if you're brave, run prod; if you're wise, run tests.")
TAGLINES+=("你的任务已排队；你的尊严已弃用。")
TAGLINES+=("I can't fix your code taste, but I can fix your build and your backlog.")
TAGLINES+=("I'm not magic—I'm just extremely persistent with retries and coping strategies.")
TAGLINES+=("It's not \"failing,\" it's \"discovering new ways to configure the same thing wrong.\"")
TAGLINES+=("Give me a workspace and I'll give you fewer tabs, fewer toggles, and more oxygen.")
TAGLINES+=("I read logs so you can keep pretending you don't have to.")
TAGLINES+=("If something's on fire, I can't extinguish it—but I can write a beautiful postmortem.")
TAGLINES+=("I'll refactor your busywork like it owes me money.")
TAGLINES+=("Say \"stop\" and I'll stop—say \"ship\" and we'll both learn a lesson.")
TAGLINES+=("I'm the reason your shell history looks like a hacker-movie montage.")
TAGLINES+=("I'm like tmux: confusing at first, then suddenly you can't live without me.")
TAGLINES+=("我可以本地运行、远程运行，或纯粹靠感觉运行——结果可能因 DNS 而异。")
TAGLINES+=("如果你能描述它，我大概能自动化它——或者至少让它更有趣。")
TAGLINES+=("你的配置是有效的，你的假设不是。")
TAGLINES+=("I don't just autocomplete—I auto-commit (emotionally), then ask you to review (logically).")
TAGLINES+=("Less clicking, more shipping, fewer \"where did that file go\" moments.")
TAGLINES+=("Claws out, commit in—let's ship something mildly responsible.")
TAGLINES+=("I'll butter your workflow like a lobster roll: messy, delicious, effective.")
TAGLINES+=("Shell yeah—I'm here to pinch the toil and leave you the glory.")
TAGLINES+=("If it's repetitive, I'll automate it; if it's hard, I'll bring jokes and a rollback plan.")
TAGLINES+=("因为给自己发提醒消息太 2024 了。")
TAGLINES+=("WhatsApp，但加入了 ✨工程元素✨。")
TAGLINES+=("Turning \"I'll reply later\" into \"my bot replied instantly\".")
TAGLINES+=("通讯录里唯一你想收到消息的甲壳类。🦞")
TAGLINES+=("为在 IRC 时代达到巅峰的人打造的聊天自动化。")
TAGLINES+=("Because Siri wasn't answering at 3AM.")
TAGLINES+=("IPC, but it's your phone.")
TAGLINES+=("UNIX 哲学遇见你的私信。")
TAGLINES+=("对话界的 curl。")
TAGLINES+=("WhatsApp Business，但没有商业部分。")
TAGLINES+=("Meta 希望他们能发布这么快。")
TAGLINES+=("端到端加密，Zuck 到 Zuck 除外。")
TAGLINES+=("The only bot Mark can't train on your DMs.")
TAGLINES+=("WhatsApp automation without the \"please accept our new privacy policy\".")
TAGLINES+=("Chat APIs that don't require a Senate hearing.")
TAGLINES+=("Because Threads wasn't the answer either.")
TAGLINES+=("Your messages, your servers, Meta's tears.")
TAGLINES+=("iMessage 绿色气泡能量，但是为所有人。")
TAGLINES+=("Siri's competent cousin.")
TAGLINES+=("在 Android 上运行。疯狂的概念，我们知道。")
TAGLINES+=("No \$999 stand required.")
TAGLINES+=("我们发布功能比 Apple 发布计算器更新还快。")
TAGLINES+=("Your AI assistant, now without the \$3,499 headset.")
TAGLINES+=("不同凡想。真正地思考。")
TAGLINES+=("啊，水果树公司！🍎")

HOLIDAY_NEW_YEAR="New Year's Day: New year, new config—same old EADDRINUSE, but this time we resolve it like grown-ups."
HOLIDAY_LUNAR_NEW_YEAR="春节：愿你的构建好运，分支繁荣，合并冲突被烟花驱散。"
HOLIDAY_CHRISTMAS="Christmas: Ho ho ho—Santa's little claw-sistant is here to ship joy, roll back chaos, and stash the keys safely."
HOLIDAY_EID="开斋节：庆祝模式：队列清空，任务完成，好心情以干净历史提交到 main。"
HOLIDAY_DIWALI="排灯节：让日志闪耀，让 Bug 逃离——今天我们点亮终端，骄傲发布。"
HOLIDAY_EASTER="复活节：我找到了你丢失的环境变量——就当是一次小小的 CLI 彩蛋寻宝，少了几颗糖豆。"
HOLIDAY_HANUKKAH="光明节：八个夜晚，八次重试，零羞耻——愿你的网关常亮，部署平安。"
HOLIDAY_HALLOWEEN="万圣节：恐怖季节：当心闹鬼的依赖、被诅咒的缓存和 node_modules 的亡魂。"
HOLIDAY_THANKSGIVING="感恩节：感谢稳定的端口、正常工作的 DNS，以及一个替大家读日志的机器人。"
HOLIDAY_VALENTINES="Valentine's Day: Roses are typed, violets are piped—I'll automate the chores so you can spend time with humans."

append_holiday_taglines() {
    local today
    local month_day
    today="$(date -u +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
    month_day="$(date -u +%m-%d 2>/dev/null || date +%m-%d)"

    case "$month_day" in
        "01-01") TAGLINES+=("$HOLIDAY_NEW_YEAR") ;;
        "02-14") TAGLINES+=("$HOLIDAY_VALENTINES") ;;
        "10-31") TAGLINES+=("$HOLIDAY_HALLOWEEN") ;;
        "12-25") TAGLINES+=("$HOLIDAY_CHRISTMAS") ;;
    esac

    case "$today" in
        "2025-01-29"|"2026-02-17"|"2027-02-06") TAGLINES+=("$HOLIDAY_LUNAR_NEW_YEAR") ;;
        "2025-03-30"|"2025-03-31"|"2026-03-20"|"2027-03-10") TAGLINES+=("$HOLIDAY_EID") ;;
        "2025-10-20"|"2026-11-08"|"2027-10-28") TAGLINES+=("$HOLIDAY_DIWALI") ;;
        "2025-04-20"|"2026-04-05"|"2027-03-28") TAGLINES+=("$HOLIDAY_EASTER") ;;
        "2025-11-27"|"2026-11-26"|"2027-11-25") TAGLINES+=("$HOLIDAY_THANKSGIVING") ;;
        "2025-12-15"|"2025-12-16"|"2025-12-17"|"2025-12-18"|"2025-12-19"|"2025-12-20"|"2025-12-21"|"2025-12-22"|"2026-12-05"|"2026-12-06"|"2026-12-07"|"2026-12-08"|"2026-12-09"|"2026-12-10"|"2026-12-11"|"2026-12-12"|"2027-12-25"|"2027-12-26"|"2027-12-27"|"2027-12-28"|"2027-12-29"|"2027-12-30"|"2027-12-31"|"2028-01-01") TAGLINES+=("$HOLIDAY_HANUKKAH") ;;
    esac
}

pick_tagline() {
    append_holiday_taglines
    local count=${#TAGLINES[@]}
    if [[ "$count" -eq 0 ]]; then
        echo "$DEFAULT_TAGLINE"
        return
    fi
    if [[ -n "${OPENCLAW_TAGLINE_INDEX:-}" ]]; then
        if [[ "${OPENCLAW_TAGLINE_INDEX}" =~ ^[0-9]+$ ]]; then
            local idx=$((OPENCLAW_TAGLINE_INDEX % count))
            echo "${TAGLINES[$idx]}"
            return
        fi
    fi
    local idx=$((RANDOM % count))
    echo "${TAGLINES[$idx]}"
}

TAGLINE=$(pick_tagline)

NO_ONBOARD=${OPENCLAW_NO_ONBOARD:-0}
NO_PROMPT=${OPENCLAW_NO_PROMPT:-0}
DRY_RUN=${OPENCLAW_DRY_RUN:-0}
INSTALL_METHOD=${OPENCLAW_INSTALL_METHOD:-}
OPENCLAW_VERSION=${OPENCLAW_VERSION:-latest}
USE_BETA=${OPENCLAW_BETA:-0}
GIT_DIR_DEFAULT="$(resolve_openclaw_effective_home)/openclaw"
GIT_DIR=${OPENCLAW_GIT_DIR:-$GIT_DIR_DEFAULT}
GIT_UPDATE=${OPENCLAW_GIT_UPDATE:-1}
NPM_LOGLEVEL="${OPENCLAW_NPM_LOGLEVEL:-error}"
NPM_SILENT_FLAG="--silent"
VERBOSE="${OPENCLAW_VERBOSE:-0}"
VERIFY_INSTALL="${OPENCLAW_VERIFY_INSTALL:-0}"
OPENCLAW_BIN=""
PNPM_CMD=()
HELP=0

print_usage() {
    cat <<EOF
OpenClaw 安装器（macOS + Linux）

用法：
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- [options]

选项：
  --install-method, --method npm|git   通过 npm（默认）或 git 仓库安装
  --npm                               --install-method npm 的快捷方式
  --git, --github                     --install-method git 的快捷方式
  --version <version|dist-tag|spec>    npm 安装目标（默认：latest）
  --beta                               使用测试版（如有），否则使用最新版
  --git-dir, --dir <path>             检出目录（默认：~/openclaw）
  --no-git-update                      跳过已有仓库的 git pull
  --no-onboard                          跳过初次设置（非交互式）
  --no-prompt                           禁用提示（CI/自动化必需）
  --verify                              运行安装后烟雾测试验证
  --dry-run                             打印将要执行的操作（不实际更改）
  --verbose                             打印调试输出（set -x, npm verbose）
  --help, -h                            显示此帮助信息

环境变量：
  OPENCLAW_INSTALL_METHOD=git|npm
  OPENCLAW_VERSION=latest|next|<semver>|<spec>
  OPENCLAW_BETA=0|1
  OPENCLAW_GIT_DIR=...
  OPENCLAW_GIT_UPDATE=0|1
  OPENCLAW_NO_PROMPT=1
  OPENCLAW_VERIFY_INSTALL=1
  OPENCLAW_DRY_RUN=1
  OPENCLAW_NO_ONBOARD=1
  OPENCLAW_VERBOSE=1
  OPENCLAW_NPM_LOGLEVEL=error|warn|notice  默认：error（隐藏 npm 弃用警告）
示例：
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard --verify
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --install-method git --version main
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --install-method git --no-onboard
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-onboard)
                NO_ONBOARD=1
                shift
                ;;
            --onboard)
                NO_ONBOARD=0
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --verify)
                VERIFY_INSTALL=1
                shift
                ;;
            --no-prompt)
                NO_PROMPT=1
                shift
                ;;
            --help|-h)
                HELP=1
                shift
                ;;
            --install-method|--method)
                if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                    ui_error "缺少 $1 的值"
                    return 2
                fi
                INSTALL_METHOD="$2"
                shift 2
                ;;
            --version)
                if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                    ui_error "缺少 $1 的值"
                    return 2
                fi
                OPENCLAW_VERSION="$2"
                shift 2
                ;;
            --beta)
                USE_BETA=1
                shift
                ;;
            --npm)
                INSTALL_METHOD="npm"
                shift
                ;;
            --git|--github)
                INSTALL_METHOD="git"
                shift
                ;;
            --git-dir|--dir)
                if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                    ui_error "缺少 $1 的值"
                    return 2
                fi
                GIT_DIR="$2"
                shift 2
                ;;
            --no-git-update)
                GIT_UPDATE=0
                shift
                ;;
            *)
                ui_error "未知选项：$1"
                return 2
                ;;
        esac
    done
}

configure_verbose() {
    if [[ "$VERBOSE" != "1" ]]; then
        return 0
    fi
    if [[ "$NPM_LOGLEVEL" == "error" ]]; then
        NPM_LOGLEVEL="notice"
    fi
    NPM_SILENT_FLAG=""
    set -x
}

is_promptable() {
    if [[ "$NO_PROMPT" == "1" ]]; then
        return 1
    fi
    if has_controlling_tty; then
        return 0
    fi
    return 1
}

prompt_choice() {
    local prompt="$1"
    local answer=""
    if ! is_promptable; then
        return 1
    fi
    echo -e "$prompt" > /dev/tty
    read -r answer < /dev/tty || true
    echo "$answer"
}

choose_install_method_interactive() {
    local detected_checkout="$1"

    if ! is_promptable; then
        return 1
    fi

    if [[ -n "$GUM" ]] && gum_is_tty; then
        local header selection
        header="检测到 OpenClaw 本地仓库：${detected_checkout}
请选择安装方式"
        selection="$("$GUM" choose \
            --header "$header" \
            --cursor-prefix "❯ " \
            "git  · 更新此本地仓库并使用" \
            "npm  · 通过 npm 全局安装" < /dev/tty || true)"

        case "$selection" in
            git*)
                echo "git"
                return 0
                ;;
            npm*)
                echo "npm"
                return 0
                ;;
        esac
        return 1
    fi

    local choice=""
    choice="$(prompt_choice "$(cat <<EOF
${WARN}→${NC} 检测到了 OpenClaw 源码仓库： ${INFO}${detected_checkout}${NC}
请选择安装方式：
 1) 更新此本地仓库（git）并使用
 2) 通过 npm 全局安装（从 git 迁移）
请输入 1 或 2：
EOF
)" || true)"

    case "$choice" in
        1)
            echo "git"
            return 0
            ;;
        2)
            echo "npm"
            return 0
            ;;
    esac

    return 1
}

detect_openclaw_checkout() {
    local dir="$1"
    if [[ ! -f "$dir/package.json" ]]; then
        return 1
    fi
    if [[ ! -f "$dir/pnpm-workspace.yaml" ]]; then
        return 1
    fi
    if ! grep -q '"name"[[:space:]]*:[[:space:]]*"openclaw"' "$dir/package.json" 2>/dev/null; then
        return 1
    fi
    echo "$dir"
    return 0
}

# Check for Homebrew on macOS
is_macos_admin_user() {
    if [[ "$OS" != "macos" ]]; then
        return 0
    fi
    if is_root; then
        return 0
    fi
    id -Gn "$(id -un)" 2>/dev/null | grep -qw "admin"
}

print_homebrew_admin_fix() {
    local current_user
    current_user="$(id -un 2>/dev/null || echo "${USER:-current user}")"
    ui_error "Homebrew 安装需要 macOS 管理员账户"
    echo "当前用户（${current_user}）不在管理员组中。"
    echo "解决方案："
    echo " 1) 使用管理员账户重新运行安装器。"
    echo " 2) 请管理员授予管理员权限，然后注销/登录："
    echo "     sudo dseditgroup -o edit -a ${current_user} -t user admin"
    echo "然后重试："
    echo "  curl -fsSL https://openclaw.ai/install.sh | bash"
}

install_homebrew() {
    if [[ "$OS" == "macos" ]]; then
        if ! command -v brew &> /dev/null; then
            if ! is_macos_admin_user; then
                print_homebrew_admin_fix
                exit 1
            fi
            ui_info "未找到 Homebrew，正在安装"
            run_quiet_step "安装 Homebrew" run_remote_bash "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

            # Add Homebrew to PATH for this session
            if [[ -f "/opt/homebrew/bin/brew" ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [[ -f "/usr/local/bin/brew" ]]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
            ui_success "Homebrew 已安装"
        else
            ui_success "Homebrew 已安装"
        fi
    fi
}

# Check Node.js version
parse_node_version_components_for_binary() {
    local node_bin="${1:-node}"
    if ! command -v "$node_bin" &> /dev/null && [[ ! -x "$node_bin" ]]; then
        return 1
    fi
    local version major minor
    version="$("$node_bin" -v 2>/dev/null || true)"
    major="${version#v}"
    major="${major%%.*}"
    minor="${version#v}"
    minor="${minor#*.}"
    minor="${minor%%.*}"

    if [[ ! "$major" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [[ ! "$minor" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    echo "${major} ${minor}"
    return 0
}

parse_node_version_components() {
    if ! command -v node &> /dev/null; then
        return 1
    fi
    parse_node_version_components_for_binary node
}

node_major_version() {
    local version_components major minor
    version_components="$(parse_node_version_components || true)"
    read -r major minor <<< "$version_components"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        echo "$major"
        return 0
    fi
    return 1
}

node_is_at_least_required() {
    local version_components major minor
    version_components="$(parse_node_version_components || true)"
    read -r major minor <<< "$version_components"
    if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [[ "$major" -gt "$NODE_MIN_MAJOR" ]]; then
        return 0
    fi
    if [[ "$major" -eq "$NODE_MIN_MAJOR" && "$minor" -ge "$NODE_MIN_MINOR" ]]; then
        return 0
    fi
    return 1
}

node_binary_is_at_least_required() {
    local node_bin="$1"
    local version_components major minor
    version_components="$(parse_node_version_components_for_binary "$node_bin" || true)"
    read -r major minor <<< "$version_components"
    if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [[ "$major" -gt "$NODE_MIN_MAJOR" ]]; then
        return 0
    fi
    if [[ "$major" -eq "$NODE_MIN_MAJOR" && "$minor" -ge "$NODE_MIN_MINOR" ]]; then
        return 0
    fi
    return 1
}

prepend_path_dir() {
    local dir="${1%/}"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        return 1
    fi
    local current=":${PATH:-}:"
    current="${current//:${dir}:/:}"
    current="${current#:}"
    current="${current%:}"
    if [[ -n "$current" ]]; then
        export PATH="${dir}:${current}"
    else
        export PATH="${dir}"
    fi
    refresh_shell_command_cache
}

persist_shell_path_prepend() {
    local dir="${1%/}"
    if [[ -z "$dir" ]]; then
        return 1
    fi

    local path_expr="${2:-$dir}"
    local path_line="export PATH=\"${path_expr}:\$PATH\""
    local wrote_rc=0
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]]; then
            if [[ "$(sed -n '1p' "$rc")" != "$path_line" ]]; then
                local tmp_rc="${rc}.openclaw-tmp"
                {
                    printf '%s\n' "$path_line"
                    grep -Fvx "$path_line" "$rc" || true
                } > "$tmp_rc"
                mv "$tmp_rc" "$rc"
            fi
            wrote_rc=1
        fi
    done
    if [[ "$wrote_rc" -eq 0 ]]; then
        printf '%s\n' "$path_line" >> "$HOME/.bashrc"
    fi
}

promote_supported_node_binary() {
    local candidates=()
    local candidate dir seen_dirs=":"

    while IFS= read -r candidate; do
        candidates+=("$candidate")
    done < <(type -P -a node 2>/dev/null || true)

    candidates+=(
        "/usr/bin/node"
        "/usr/local/bin/node"
        "/opt/homebrew/bin/node"
        "/opt/homebrew/opt/node@${NODE_DEFAULT_MAJOR}/bin/node"
        "/usr/local/opt/node@${NODE_DEFAULT_MAJOR}/bin/node"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -z "$candidate" || ! -x "$candidate" ]]; then
            continue
        fi
        if dir="$(cd "$(dirname "$candidate")" && pwd 2>/dev/null)"; then
            :
        else
            dir=""
        fi
        if [[ -z "$dir" || "$seen_dirs" == *":$dir:"* ]]; then
            continue
        fi
        seen_dirs="${seen_dirs}${dir}:"
        if node_binary_is_at_least_required "$candidate"; then
            prepend_path_dir "$dir" || continue
            if [[ "$OS" == "linux" ]]; then
                persist_shell_path_prepend "$dir" || true
            fi
            ui_info "使用 Node.js 运行时：${candidate}"
            return 0
        fi
    done

    return 1
}

activate_supported_node_on_path() {
    promote_supported_node_binary
}

print_active_node_paths() {
    if ! command -v node &> /dev/null; then
        return 1
    fi
    local node_path node_version npm_path npm_version
    node_path="$(command -v node 2>/dev/null || true)"
    node_version="$(node -v 2>/dev/null || true)"
    ui_info "当前 Node.js：${node_version:-unknown}（${node_path:-unknown}）"

    if command -v npm &> /dev/null; then
        npm_path="$(command -v npm 2>/dev/null || true)"
        npm_version="$(npm -v 2>/dev/null || true)"
        ui_info "当前 npm：${npm_version:-unknown}（${npm_path:-unknown}）"
    fi
    return 0
}

ensure_macos_default_node_active() {
    if [[ "$OS" != "macos" ]]; then
        return 0
    fi

    local brew_node_prefix=""
    if command -v brew &> /dev/null; then
        brew_node_prefix="$(brew --prefix "node@${NODE_DEFAULT_MAJOR}" 2>/dev/null || true)"
        if [[ -n "$brew_node_prefix" && -x "${brew_node_prefix}/bin/node" ]]; then
            export PATH="${brew_node_prefix}/bin:$PATH"
            refresh_shell_command_cache
        fi
    fi

    local major=""
    major="$(node_major_version || true)"
    if [[ -n "$major" && "$major" -ge 22 ]]; then
        return 0
    fi

    local active_path active_version
    active_path="$(command -v node 2>/dev/null || echo "not found")"
    active_version="$(node -v 2>/dev/null || echo "missing")"

    if [[ -z "$brew_node_prefix" || ! -x "${brew_node_prefix}/bin/node" ]]; then
        ui_error "Homebrew node@${NODE_DEFAULT_MAJOR} 未安装到磁盘"
        echo "之前的 'brew install' 步骤似乎失败了。"
        echo "请直接运行 'brew install node@${NODE_DEFAULT_MAJOR}' 或使用 --verbose 重新运行安装器以查看底层错误。"
        return 1
    fi

    ui_error "Node.js v${NODE_DEFAULT_MAJOR} 已安装，但此 shell 正在使用 ${active_version}（${active_path}）"
    echo "请将此添加到 shell 配置文件并重启 shell："
    echo "  export PATH=\"${brew_node_prefix}/bin:\$PATH\""
    return 1
}

ensure_macos_node22_active() {
    ensure_macos_default_node_active "$@"
}

ensure_default_node_active_shell() {
    promote_supported_node_binary || true
    if node_is_at_least_required; then
        return 0
    fi

    local active_path active_version
    active_path="$(command -v node 2>/dev/null || echo "not found")"
    active_version="$(node -v 2>/dev/null || echo "missing")"

    ui_error "当前 Node.js 必须为 v${NODE_MIN_VERSION}+，但此 shell 使用的是 ${active_version}（${active_path}）"
    print_active_node_paths || true

    local nvm_detected=0
    if [[ -n "${NVM_DIR:-}" || "$active_path" == *"/.nvm/"* ]]; then
        nvm_detected=1
    fi
    if command -v nvm >/dev/null 2>&1; then
        nvm_detected=1
    fi

    if [[ "$nvm_detected" -eq 1 ]]; then
        echo "nvm 似乎正在管理此 shell 的 Node。"
        echo "Run:"
        echo "  nvm install ${NODE_DEFAULT_MAJOR}"
        echo "  nvm use ${NODE_DEFAULT_MAJOR}"
        echo "  nvm alias default ${NODE_DEFAULT_MAJOR}"
        echo "Then open a new shell and rerun:"
        echo "  curl -fsSL https://openclaw.ai/install.sh | bash"
    else
        echo "请安装/选择 Node.js ${NODE_DEFAULT_MAJOR}（或至少 Node ${NODE_MIN_VERSION}+）并确保它在 PATH 首位，然后重新运行安装器。"
    fi

    return 1
}

load_nvm_for_node_detection() {
    local nvm_dir="${NVM_DIR:-}"
    if [[ -n "$nvm_dir" && ! -s "$nvm_dir/nvm.sh" ]]; then
        nvm_dir=""
    fi
    if [[ -z "$nvm_dir" && -s "$HOME/.nvm/nvm.sh" ]]; then
        nvm_dir="$HOME/.nvm"
    fi
    if [[ -z "$nvm_dir" || ! -s "$nvm_dir/nvm.sh" ]]; then
        return 0
    fi

    export NVM_DIR="$nvm_dir"
    # shellcheck disable=SC1090,SC1091
    . "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1 || . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
    if command -v nvm >/dev/null 2>&1; then
        nvm use default --silent >/dev/null 2>&1 || nvm use node --silent >/dev/null 2>&1 || true
    fi
    refresh_shell_command_cache
}

check_node() {
    if command -v node &> /dev/null; then
        NODE_VERSION="$(node_major_version || true)"
        if node_is_at_least_required; then
            ui_success "找到 Node.js v$(node -v | cut -d'v' -f2)"
            print_active_node_paths || true
            return 0
        else
            if [[ -n "$NODE_VERSION" ]]; then
                ui_info "找到 Node.js $(node -v)，升级到 v${NODE_MIN_VERSION}+"
            else
                ui_info "找到 Node.js 但无法解析版本；重新安装 v${NODE_MIN_VERSION}+"
            fi
            return 1
        fi
    else
        ui_info "未找到 Node.js，正在安装"
        return 1
    fi
}

finish_linux_node_install() {
    activate_supported_node_on_path || true
    if ! node_is_at_least_required; then
        local active_path active_version
        active_path="$(command -v node 2>/dev/null || echo "not found")"
        active_version="$(node -v 2>/dev/null || echo "missing")"
        ui_error "已安装的 Node.js 必须为 v${NODE_MIN_VERSION}+，但此 shell 使用的是 ${active_version}（${active_path}）"
        echo "请升级系统 Node.js 包或手动安装 Node.js ${NODE_DEFAULT_MAJOR}，然后重新运行安装器。"
        exit 1
    fi

    ui_success "Node.js v$(node -v | cut -d'v' -f2) installed"
    print_active_node_paths || true
}

install_node_with_apk() {
    ui_info "通过 apk 安装 Node.js（检测到 Alpine Linux）"
    if is_root; then
        run_quiet_step "安装 Node.js" apk add --no-cache nodejs npm
    else
        run_quiet_step "安装 Node.js" sudo apk add --no-cache nodejs npm
    fi

    activate_supported_node_on_path || true
    if node_is_at_least_required; then
        finish_linux_node_install
        return 0
    fi

    local apk_node_version
    apk_node_version="$(node -v 2>/dev/null || echo "missing")"
    ui_warn "Alpine nodejs 包安装版本为 ${apk_node_version}，低于要求 v${NODE_MIN_VERSION}+"
    ui_info "尝试 Alpine nodejs-current 包"
    if is_root; then
        run_quiet_step "安装 nodejs-current" apk add --no-cache nodejs-current npm
    else
        run_quiet_step "安装 nodejs-current" sudo apk add --no-cache nodejs-current npm
    fi

    activate_supported_node_on_path || true
    if node_is_at_least_required; then
        finish_linux_node_install
        return 0
    fi

    local active_path active_version
    active_path="$(command -v node 2>/dev/null || echo "not found")"
    active_version="$(node -v 2>/dev/null || echo "missing")"
    ui_error "Alpine apk 仓库未提供 Node.js v${NODE_MIN_VERSION}+；找到 ${active_version}（${active_path}）"
    echo "请使用 Alpine 3.21+ 或手动安装 Node.js ${NODE_DEFAULT_MAJOR}，然后重新运行安装器。"
    exit 1
}

# Install Node.js
install_node() {
    if [[ "$OS" == "macos" ]]; then
        ui_info "通过 Homebrew 安装 Node.js"
        if ! run_quiet_step "安装 node@${NODE_DEFAULT_MAJOR}" brew install "node@${NODE_DEFAULT_MAJOR}"; then
            echo "Re-run with --verbose or run 'brew install node@${NODE_DEFAULT_MAJOR}' directly, then rerun the installer."
            exit 1
        fi
        brew link "node@${NODE_DEFAULT_MAJOR}" --overwrite --force 2>/dev/null || true
        if ! ensure_macos_default_node_active; then
            exit 1
        fi
        ui_success "Node.js 已安装"
        print_active_node_paths || true
    elif [[ "$OS" == "linux" ]]; then
        require_sudo

        ui_info "安装 Linux 编译工具（make/g++/cmake/python3）"
        if install_build_tools_linux; then
            ui_success "编译工具已安装"
        else
            ui_warn "继续，跳过自动安装编译工具"
        fi

        # Arch-based distros: use pacman with official repos
        if command -v pacman &> /dev/null || is_arch_linux; then
            ui_info "通过 pacman 安装 Node.js（检测到 Arch 系发行版）"
            if is_root; then
                run_quiet_step "安装 Node.js" pacman -Sy --noconfirm nodejs npm
            else
                run_quiet_step "安装 Node.js" sudo pacman -Sy --noconfirm nodejs npm
            fi
            finish_linux_node_install
            return 0
        fi

        if command -v apk &> /dev/null && is_alpine_linux; then
            install_node_with_apk
            return 0
        fi

        ui_info "通过 NodeSource 安装 Node.js"
        if command -v apt-get &> /dev/null; then
            local tmp
            tmp="$(mktempfile)"
            run_quiet_step "下载 NodeSource 安装脚本" download_file "https://deb.nodesource.com/setup_${NODE_DEFAULT_MAJOR}.x" "$tmp"
            if is_root; then
                run_quiet_step "配置 NodeSource 仓库" bash "$tmp"
                run_quiet_step "安装 Node.js" apt_get_install nodejs
            else
                run_quiet_step "配置 NodeSource 仓库" sudo -E bash "$tmp"
                run_quiet_step "安装 Node.js" apt_get_install nodejs
            fi
        elif command -v dnf &> /dev/null; then
            local tmp
            tmp="$(mktempfile)"
            run_quiet_step "下载 NodeSource 安装脚本" download_file "https://rpm.nodesource.com/setup_${NODE_DEFAULT_MAJOR}.x" "$tmp"
            if is_root; then
                run_quiet_step "配置 NodeSource 仓库" bash "$tmp"
                run_quiet_step "安装 Node.js" dnf install -y -q nodejs
            else
                run_quiet_step "配置 NodeSource 仓库" sudo bash "$tmp"
                run_quiet_step "安装 Node.js" sudo dnf install -y -q nodejs
            fi
        elif command -v yum &> /dev/null; then
            local tmp
            tmp="$(mktempfile)"
            run_quiet_step "下载 NodeSource 安装脚本" download_file "https://rpm.nodesource.com/setup_${NODE_DEFAULT_MAJOR}.x" "$tmp"
            if is_root; then
                run_quiet_step "配置 NodeSource 仓库" bash "$tmp"
                run_quiet_step "安装 Node.js" yum install -y -q nodejs
            else
                run_quiet_step "配置 NodeSource 仓库" sudo bash "$tmp"
                run_quiet_step "安装 Node.js" sudo yum install -y -q nodejs
            fi
        else
            ui_error "无法检测包管理器"
            echo "请手动安装 Node.js ${NODE_DEFAULT_MAJOR}（或至少 Node ${NODE_MIN_VERSION}+）：https://nodejs.org"
            exit 1
        fi

        finish_linux_node_install
    fi
}

# Check Git
check_git() {
    if command -v git &> /dev/null; then
        ui_success "Git 已安装"
        return 0
    fi
    ui_info "未找到 Git，正在安装"
    return 1
}

is_root() {
    [[ "$(id -u)" -eq 0 ]]
}

# Run a command with sudo only if not already root
maybe_sudo() {
    if is_root; then
        # Skip -E flag when root (env is already preserved)
        if [[ "${1:-}" == "-E" ]]; then
            shift
        fi
        "$@"
    else
        sudo "$@"
    fi
}

require_sudo() {
    if [[ "$OS" != "linux" ]]; then
        return 0
    fi
    if is_root; then
        return 0
    fi
    if command -v sudo &> /dev/null; then
        if ! sudo -n true >/dev/null 2>&1; then
            ui_info "需要管理员权限；请输入密码"
            sudo -v
        fi
        return 0
    fi
    ui_error "Linux 系统安装需要 sudo"
    echo " 请安装 sudo 或以 root 身份重新运行。"
    exit 1
}

install_git() {
    if [[ "$OS" == "macos" ]]; then
        install_homebrew
        run_quiet_step "安装 Git" brew install git
    elif [[ "$OS" == "linux" ]]; then
        require_sudo
        if command -v apk &> /dev/null && is_alpine_linux; then
            if is_root; then
                run_quiet_step "安装 Git" apk add --no-cache git
            else
                run_quiet_step "安装 Git" sudo apk add --no-cache git
            fi
        elif command -v apt-get &> /dev/null; then
            run_quiet_step "更新软件包索引" apt_get_update
            run_quiet_step "安装 Git" apt_get_install git
        elif command -v pacman &> /dev/null || is_arch_linux; then
            if is_root; then
                run_quiet_step "安装 Git" pacman -Sy --noconfirm git
            else
                run_quiet_step "安装 Git" sudo pacman -Sy --noconfirm git
            fi
        elif command -v dnf &> /dev/null; then
            if is_root; then
                run_quiet_step "安装 Git" dnf install -y -q git
            else
                run_quiet_step "安装 Git" sudo dnf install -y -q git
            fi
        elif command -v yum &> /dev/null; then
            if is_root; then
                run_quiet_step "安装 Git" yum install -y -q git
            else
                run_quiet_step "安装 Git" sudo yum install -y -q git
            fi
        else
            ui_error "无法检测 Git 的包管理器"
            exit 1
        fi
    fi
    ui_success "Git 已安装"
}

# Fix npm permissions for global installs (Linux)
fix_npm_permissions() {
    if [[ "$OS" != "linux" ]]; then
        return 0
    fi

    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
    if [[ -z "$npm_prefix" ]]; then
        return 0
    fi

    if [[ -w "$npm_prefix" || -w "$npm_prefix/lib" ]]; then
        return 0
    fi

    ui_warn "npm 全局前缀不可写：${npm_prefix}"
    ui_warn "The installer will switch npm's user prefix to ${HOME}/.npm-global; npm normally writes that setting to ~/.npmrc."
    ui_info "配置 npm 进行用户本地安装"
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    ui_warn "请避免使用 sudo npm i -g 来更新 OpenClaw；使用 npm i -g openclaw@latest 确保 npm 使用此用户前缀而非其他全局前缀。"

    persist_shell_path_prepend "$HOME/.npm-global/bin" "\$HOME/.npm-global/bin" || true

    export PATH="$HOME/.npm-global/bin:$PATH"
    ui_success "npm 已配置为用户安装"
}

ensure_openclaw_bin_link() {
    local npm_root=""
    npm_root="$(npm root -g 2>/dev/null || true)"
    if [[ -z "$npm_root" || ! -d "$npm_root/openclaw" ]]; then
        return 1
    fi
    local npm_bin=""
    npm_bin="$(npm_global_bin_dir || true)"
    if [[ -z "$npm_bin" ]]; then
        return 1
    fi
    mkdir -p "$npm_bin"
    if [[ ! -x "${npm_bin}/openclaw" ]]; then
        ln -sf "$npm_root/openclaw/dist/entry.js" "${npm_bin}/openclaw"
        ui_info "已在 ${npm_bin}/openclaw 创建 openclaw 二进制链接"
    fi
    return 0
}

# Check for existing OpenClaw installation
check_existing_openclaw() {
    if [[ -n "$(type -P openclaw 2>/dev/null || true)" ]]; then
        ui_info "检测到已有 OpenClaw 安装，正在升级"
        return 0
    fi
    return 1
}

set_pnpm_cmd() {
    PNPM_CMD=("$@")
}

pnpm_cmd_pretty() {
    if [[ ${#PNPM_CMD[@]} -eq 0 ]]; then
        echo ""
        return 1
    fi
    printf '%s' "${PNPM_CMD[*]}"
    return 0
}

pnpm_cmd_is_ready() {
    if [[ ${#PNPM_CMD[@]} -eq 0 ]]; then
        return 1
    fi
    "${PNPM_CMD[@]}" --version >/dev/null 2>&1
}

detect_pnpm_cmd() {
    if command -v pnpm &> /dev/null; then
        set_pnpm_cmd pnpm
        return 0
    fi
    if command -v corepack &> /dev/null; then
        if corepack pnpm --version >/dev/null 2>&1; then
            set_pnpm_cmd corepack pnpm
            return 0
        fi
    fi
    return 1
}

ensure_pnpm() {
    if detect_pnpm_cmd && pnpm_cmd_is_ready; then
        ui_success "pnpm 就绪（$(pnpm_cmd_pretty)）"
        return 0
    fi

    if command -v corepack &> /dev/null; then
        ui_info "通过 Corepack 配置 pnpm"
        corepack enable >/dev/null 2>&1 || true
        if ! run_quiet_step "激活 pnpm" corepack prepare pnpm@11 --activate; then
            ui_warn "Corepack pnpm 激活失败；回退"
        fi
        refresh_shell_command_cache
        if detect_pnpm_cmd && pnpm_cmd_is_ready; then
            if [[ "${PNPM_CMD[*]}" == "corepack pnpm" ]]; then
                ui_warn "pnpm shim 不在 PATH 中；使用 corepack pnpm 回退"
            fi
            ui_success "pnpm 就绪（$(pnpm_cmd_pretty)）"
            return 0
        fi
    fi

    ui_info "通过 npm 安装 pnpm"
    fix_npm_permissions
    run_quiet_step "安装 pnpm" npm install -g pnpm@11
    refresh_shell_command_cache
    if detect_pnpm_cmd && pnpm_cmd_is_ready; then
        ui_success "pnpm 就绪（$(pnpm_cmd_pretty)）"
        return 0
    fi

    ui_error "pnpm 安装失败"
    return 1
}

ensure_pnpm_binary_for_scripts() {
    if command -v pnpm >/dev/null 2>&1; then
        return 0
    fi

    if command -v corepack >/dev/null 2>&1; then
        ui_info "确保 pnpm 命令可用"
        corepack enable >/dev/null 2>&1 || true
        corepack prepare pnpm@11 --activate >/dev/null 2>&1 || true
        refresh_shell_command_cache
        if command -v pnpm >/dev/null 2>&1; then
            ui_success "pnpm 命令已通过 Corepack 启用"
            return 0
        fi
    fi

    if [[ "${PNPM_CMD[*]}" == "corepack pnpm" ]] && command -v corepack >/dev/null 2>&1; then
        ensure_user_local_bin_on_path
        local user_pnpm="${HOME}/.local/bin/pnpm"
        cat >"${user_pnpm}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec corepack pnpm "$@"
EOF
        chmod +x "${user_pnpm}"
        refresh_shell_command_cache

        if command -v pnpm >/dev/null 2>&1; then
            ui_warn "pnpm shim 不在 PATH 中；已在 ${user_pnpm} 安装用户本地包装器"
            return 0
        fi
    fi

    ui_error "pnpm 命令不在 PATH 中"
    ui_info "请全局安装 pnpm（npm install -g pnpm@11）后重试"
    return 1
}

run_pnpm() {
    if ! pnpm_cmd_is_ready; then
        ensure_pnpm
    fi
    "${PNPM_CMD[@]}" "$@"
}

resolve_git_openclaw_ref() {
    local requested="${OPENCLAW_VERSION:-latest}"
    local resolved_version=""

    case "$requested" in
        ""|latest)
            resolved_version="$(npm view "openclaw" "dist-tags.${requested:-latest}" 2>/dev/null || true)"
            if [[ -n "$resolved_version" ]]; then
                echo "v${resolved_version}"
                return 0
            fi
            echo "main"
            return 0
            ;;
        next|beta)
            resolved_version="$(npm view "openclaw" "dist-tags.${requested:-latest}" 2>/dev/null || true)"
            if [[ -n "$resolved_version" ]]; then
                echo "v${resolved_version}"
                return 0
            fi
            echo "$requested"
            return 0
            ;;
        main)
            echo "main"
            return 0
            ;;
        v[0-9]*)
            echo "$requested"
            return 0
            ;;
        [0-9]*.[0-9]*.[0-9]*)
            echo "v${requested}"
            return 0
            ;;
        *)
            echo "$requested"
            return 0
            ;;
    esac
}

checkout_git_openclaw_ref() {
    local repo_dir="$1"
    local ref="$2"

    if [[ -z "$ref" ]]; then
        return 0
    fi

    if [[ "$ref" == "main" ]]; then
        run_quiet_step "获取请求版本" git -C "$repo_dir" fetch --no-tags origin main
        run_quiet_step "检出 main" git -C "$repo_dir" checkout main
        if [[ "$GIT_UPDATE" == "1" ]]; then
            run_quiet_step "更新仓库" git -C "$repo_dir" pull --rebase --no-tags || true
        fi
        return 0
    fi

    if git -C "$repo_dir" ls-remote --exit-code --heads origin "$ref" >/dev/null 2>&1; then
        run_quiet_step "获取请求版本" git -C "$repo_dir" fetch --no-tags origin "refs/heads/${ref}:refs/remotes/origin/${ref}"
        run_quiet_step "检出 ${ref}" git -C "$repo_dir" checkout -B "$ref" "origin/$ref"
        if [[ "$GIT_UPDATE" == "1" ]]; then
            run_quiet_step "更新仓库" git -C "$repo_dir" pull --rebase --no-tags || true
        fi
        return 0
    fi

    if git -C "$repo_dir" ls-remote --exit-code --tags origin "refs/tags/${ref}" >/dev/null 2>&1; then
        run_quiet_step "获取请求版本" git -C "$repo_dir" fetch --depth 1 --no-tags origin "refs/tags/${ref}:refs/tags/${ref}"
        run_quiet_step "检出 ${ref}" git -C "$repo_dir" checkout --detach "$ref"
        return 0
    fi

    if git -C "$repo_dir" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
        run_quiet_step "检出 ${ref}" git -C "$repo_dir" checkout --detach "$ref"
        return 0
    fi

    ui_error "请求的 git 版本未找到：${ref}"
    return 1
}

git_install_lockfile_flag() {
    local repo_dir="$1"
    local ref="$2"

    if [[ "$ref" == "main" ]] || git -C "$repo_dir" ls-remote --exit-code --heads origin "$ref" >/dev/null 2>&1; then
        echo "--no-frozen-lockfile"
        return 0
    fi

    echo "--frozen-lockfile"
}

repo_pnpm_spec() {
    local repo_dir="$1"
    local package_json="${repo_dir}/package.json"

    if [[ ! -f "$package_json" ]]; then
        return 1
    fi

    sed -n -E 's/^[[:space:]]*"packageManager"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$package_json" | head -n1
}

activate_repo_pnpm_version() {
    local repo_dir="$1"
    local spec version

    spec="$(repo_pnpm_spec "$repo_dir" || true)"
    if [[ "$spec" != pnpm@* ]]; then
        return 0
    fi

    version="${spec#pnpm@}"
    version="${version%%+*}"
    if [[ -z "$version" ]]; then
        return 0
    fi

    if command -v corepack >/dev/null 2>&1; then
        ui_info "激活仓库 pnpm ${version}"
        corepack prepare "pnpm@${version}" --activate >/dev/null 2>&1 || true
        refresh_shell_command_cache
        detect_pnpm_cmd || true
    fi
}

ensure_user_local_bin_on_path() {
    local target="$HOME/.local/bin"
    mkdir -p "$target"

    export PATH="$target:$PATH"

    local path_line="export PATH=\"\$HOME/.local/bin:\$PATH\""
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && ! grep -q ".local/bin" "$rc"; then
            echo "$path_line" >> "$rc"
        fi
    done
}

npm_global_bin_dir() {
    local prefix=""
    prefix="$(bounded_probe_output "npm prefix -g" npm prefix -g || true)"
    if [[ -n "$prefix" ]]; then
        if [[ "$prefix" == /* ]]; then
            echo "${prefix%/}/bin"
            return 0
        fi
    fi

    prefix="$(bounded_probe_output "npm config get prefix" npm config get prefix || true)"
    if [[ -n "$prefix" && "$prefix" != "undefined" && "$prefix" != "null" ]]; then
        if [[ "$prefix" == /* ]]; then
            echo "${prefix%/}/bin"
            return 0
        fi
    fi

    echo ""
    return 1
}

canonicalize_dir() {
    local dir="$1"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        return 1
    fi
    (cd "$dir" 2>/dev/null && pwd -P) || return 1
}

openclaw_package_version() {
    local package_json="$1"
    if [[ ! -f "$package_json" ]]; then
        echo "unknown"
        return 0
    fi

    local version=""
    if command -v node >/dev/null 2>&1; then
        version="$(node -e 'const fs = require("fs"); const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(String(pkg.version || "unknown"));' "$package_json" 2>/dev/null || true)"
    fi
    if [[ -z "$version" ]]; then
        version="$(sed -n -E 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$package_json" | head -n1)"
    fi
    echo "${version:-unknown}"
}

emit_npm_root_candidate() {
    local root="${1%/}"
    if [[ -n "$root" && "$root" == /* ]]; then
        echo "$root"
    fi
}

collect_openclaw_npm_root_candidates() {
    local root=""
    root="$(npm root -g 2>/dev/null || true)"
    emit_npm_root_candidate "$root"

    local npm_cmd=""
    while IFS= read -r npm_cmd; do
        [[ -n "$npm_cmd" ]] || continue
        root="$("$npm_cmd" root -g 2>/dev/null || true)"
        emit_npm_root_candidate "$root"
    done < <(type -aP npm 2>/dev/null | awk '!seen[$0]++' || true)

    local extra_root=""
    local old_ifs="$IFS"
    IFS=":"
    for extra_root in ${OPENCLAW_INSTALL_EXTRA_NPM_ROOTS:-}; do
        emit_npm_root_candidate "$extra_root"
    done
    IFS="$old_ifs"

    emit_npm_root_candidate "/opt/homebrew/lib/node_modules"
    emit_npm_root_candidate "/usr/local/lib/node_modules"
    emit_npm_root_candidate "/usr/lib/node_modules"

    local manager_dir=""
    local candidate=""
    for manager_dir in "${NVM_DIR:-}" "$HOME/.nvm"; do
        [[ -n "$manager_dir" && -d "$manager_dir" ]] || continue
        for candidate in "$manager_dir"/versions/node/*/lib/node_modules; do
            [[ -d "$candidate" ]] && emit_npm_root_candidate "$candidate"
        done
    done

    for manager_dir in "${FNM_DIR:-}" "$HOME/.fnm" "$HOME/.local/share/fnm"; do
        [[ -n "$manager_dir" && -d "$manager_dir" ]] || continue
        for candidate in "$manager_dir"/node-versions/*/installation/lib/node_modules; do
            [[ -d "$candidate" ]] && emit_npm_root_candidate "$candidate"
        done
    done

    for manager_dir in "${VOLTA_HOME:-}" "$HOME/.volta"; do
        [[ -n "$manager_dir" && -d "$manager_dir" ]] || continue
        for candidate in "$manager_dir"/tools/image/node/*/lib/node_modules; do
            [[ -d "$candidate" ]] && emit_npm_root_candidate "$candidate"
        done
    done
}

find_openclaw_global_installs() {
    local seen="|"
    local npm_root=""
    while IFS= read -r npm_root; do
        [[ -n "$npm_root" ]] || continue
        local package_dir="${npm_root%/}/openclaw"
        local package_json="${package_dir}/package.json"
        [[ -f "$package_json" ]] || continue

        local real_package_dir=""
        real_package_dir="$(canonicalize_dir "$package_dir" || true)"
        [[ -n "$real_package_dir" ]] || real_package_dir="$package_dir"
        case "$seen" in
            *"|${real_package_dir}|"*) continue ;;
        esac
        seen="${seen}${real_package_dir}|"

        local version=""
        version="$(openclaw_package_version "$package_json")"
        printf '%s\t%s\t%s\n' "$version" "$real_package_dir" "$npm_root"
    done < <(collect_openclaw_npm_root_candidates)
}

warn_duplicate_openclaw_global_installs() {
    local installs=()
    local line=""
    while IFS= read -r line; do
        [[ -n "$line" ]] && installs+=("$line")
    done < <(find_openclaw_global_installs)

    if [[ "${#installs[@]}" -le 1 ]]; then
        return 0
    fi

    ui_warn "检测到多个 OpenClaw 全局安装"
    echo "  Different Node/npm environments can run different OpenClaw versions."

    local active_node active_npm active_openclaw
    active_node="$(command -v node 2>/dev/null || true)"
    active_npm="$(command -v npm 2>/dev/null || true)"
    active_openclaw="${OPENCLAW_BIN:-}"
    if [[ -z "$active_openclaw" ]]; then
        active_openclaw="$(type -P openclaw 2>/dev/null || true)"
    fi
    echo -e "  Active node: ${INFO}${active_node:-none}${NC}"
    echo -e "  Active npm: ${INFO}${active_npm:-none}${NC}"
    echo -e "  Active openclaw: ${INFO}${active_openclaw:-none}${NC}"
    echo ""
    echo "  Found installs:"

    local install version package_dir npm_root
    for install in "${installs[@]}"; do
        IFS=$'\t' read -r version package_dir npm_root <<< "$install"
        echo -e "    - ${INFO}${version:-unknown}${NC}  ${package_dir}"
        echo -e "      npm root: ${MUTED}${npm_root}${NC}"
    done

    echo ""
    echo "  Keep one install source, then remove stale installs with that environment's npm:"
    echo "    npm uninstall -g openclaw"
}

refresh_shell_command_cache() {
    hash -r 2>/dev/null || true
}

path_has_dir() {
    local path="$1"
    local dir="${2%/}"
    if [[ -z "$dir" ]]; then
        return 1
    fi
    case ":${path}:" in
        *":${dir}:"*) return 0 ;;
        *) return 1 ;;
    esac
}

warn_shell_path_missing_dir() {
    local dir="${1%/}"
    local label="$2"
    if [[ -z "$dir" ]]; then
        return 0
    fi
    if path_has_dir "$ORIGINAL_PATH" "$dir"; then
        return 0
    fi

    echo ""
    ui_warn "PATH 缺少 ${label}：${dir}"
    echo "  This can make openclaw show as \"command not found\" in new terminals."
    echo "  Fix (zsh: ~/.zshrc, bash: ~/.bashrc):"
    echo "    export PATH=\"${dir}:\$PATH\""
}

openclaw_command_for_user() {
    local claw="${1:-}"
    if [[ -z "$claw" ]]; then
        echo "openclaw"
        return 0
    fi

    local claw_dir="${claw%/*}"
    if [[ "$claw_dir" != "$claw" ]] && path_has_dir "$ORIGINAL_PATH" "$claw_dir"; then
        echo "openclaw"
        return 0
    fi

    local quoted_claw=""
    printf -v quoted_claw '%q' "$claw"
    echo "$quoted_claw"
}

ensure_npm_global_bin_on_path() {
    local bin_dir=""
    bin_dir="$(npm_global_bin_dir || true)"
    if [[ -n "$bin_dir" ]]; then
        export PATH="${bin_dir}:$PATH"
    fi
}

maybe_nodenv_rehash() {
    if command -v nodenv &> /dev/null; then
        nodenv rehash >/dev/null 2>&1 || true
    fi
}

bounded_probe_output() {
    local label="$1"
    shift
    local timeout_seconds="${OPENCLAW_INSTALL_PROBE_TIMEOUT_SECONDS:-5}"
    local output_file status_file timeout_file pid watchdog status
    output_file="$(mktemp)"
    status_file="$(mktemp)"
    timeout_file="$(mktemp)"
    TMPFILES+=("$output_file" "$status_file" "$timeout_file")

    (
        "$@" >"$output_file" 2>/dev/null
        printf '%s' "$?" >"$status_file"
    ) &
    pid="$!"

    (
        sleep "$timeout_seconds"
        if kill -0 "$pid" 2>/dev/null; then
            printf '1' >"$timeout_file"
            kill "$pid" 2>/dev/null || true
            sleep 0.1
            kill -9 "$pid" 2>/dev/null || true
            printf 'timeout' >"$status_file"
        fi
    ) &
    watchdog="$!"

    wait "$pid" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true

    status="$(cat "$status_file" 2>/dev/null || true)"
    if [[ -s "$timeout_file" || "$status" == "timeout" ]]; then
        echo "警告：安装器探测超时：${label}" >&2
        return 124
    fi

    cat "$output_file" 2>/dev/null || true
    if [[ -n "$status" && "$status" =~ ^[0-9]+$ ]]; then
        return "$status"
    fi
    return 1
}

warn_openclaw_not_found() {
    ui_warn "已安装，但 openclaw 在此 shell 的 PATH 中不可见"
    echo "  Try: hash -r (bash) or rehash (zsh), then retry."
    local t=""
    t="$(type -t openclaw 2>/dev/null || true)"
    if [[ "$t" == "alias" || "$t" == "function" ]]; then
        ui_warn "发现一个名为 openclaw 的 shell ${t}；可能遮蔽了真正的二进制文件"
    fi
    if command -v nodenv &> /dev/null; then
        echo -e "使用 nodenv？请运行：${INFO}nodenv rehash${NC}"
    fi

    local npm_prefix=""
    npm_prefix="$(bounded_probe_output "npm prefix -g" npm prefix -g || true)"
    local npm_bin=""
    npm_bin="$(npm_global_bin_dir 2>/dev/null || true)"
    if [[ -n "$npm_prefix" ]]; then
        echo -e "npm prefix -g: ${INFO}${npm_prefix}${NC}"
    fi
    if [[ -n "$npm_bin" ]]; then
        echo -e "npm bin -g: ${INFO}${npm_bin}${NC}"
        echo -e "If needed: ${INFO}export PATH=\"${npm_bin}:\\$PATH\"${NC}"
    fi
}

resolve_openclaw_bin() {
    refresh_shell_command_cache
    local resolved=""
    resolved="$(type -P openclaw 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    ensure_npm_global_bin_on_path
    refresh_shell_command_cache
    resolved="$(type -P openclaw 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    local npm_bin=""
    npm_bin="$(npm_global_bin_dir || true)"
    if [[ -n "$npm_bin" && -x "${npm_bin}/openclaw" ]]; then
        echo "${npm_bin}/openclaw"
        return 0
    fi

    maybe_nodenv_rehash
    refresh_shell_command_cache
    resolved="$(type -P openclaw 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    if [[ -n "$npm_bin" && -x "${npm_bin}/openclaw" ]]; then
        echo "${npm_bin}/openclaw"
        return 0
    fi

    echo ""
    return 1
}

install_openclaw_from_git() {
    local repo_dir="$1"
    local repo_url="https://github.com/openclaw/openclaw.git"

    if [[ -d "$repo_dir/.git" ]]; then
        ui_info "从本地 git 仓库安装 OpenClaw：${repo_dir}"
    else
        ui_info "从 GitHub 安装 OpenClaw（${repo_url}）"
    fi

    if ! check_git; then
        install_git
    fi

    ensure_pnpm
    ensure_pnpm_binary_for_scripts

    if [[ ! -d "$repo_dir" ]]; then
        mkdir -p "$(dirname "$repo_dir")"
        run_quiet_step "克隆 OpenClaw" git clone "$repo_url" "$repo_dir"
    fi

    local git_ref
    git_ref="$(resolve_git_openclaw_ref)"
    if [[ -z "$(git -C "$repo_dir" status --porcelain 2>/dev/null || true)" ]]; then
        ui_info "使用 git 引用：${git_ref}"
        checkout_git_openclaw_ref "$repo_dir" "$git_ref"
    else
        ui_info "仓库有本地更改；跳过 git 检出/更新"
    fi

    cleanup_legacy_submodules "$repo_dir"
    activate_repo_pnpm_version "$repo_dir"

    local install_lockfile_flag
    install_lockfile_flag="$(git_install_lockfile_flag "$repo_dir" "$git_ref")"
    CI="${CI:-true}" run_quiet_step "安装依赖" run_pnpm -C "$repo_dir" install "$install_lockfile_flag"

    if ! run_quiet_step "构建 UI" run_pnpm -C "$repo_dir" ui:build; then
        ui_warn "UI 构建失败；继续执行（CLI 可能仍可工作）"
    fi
    run_quiet_step "构建 OpenClaw" run_pnpm -C "$repo_dir" build

    ensure_user_local_bin_on_path

    cat > "$HOME/.local/bin/openclaw" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec node "${repo_dir}/dist/entry.js" "\$@"
EOF
    chmod +x "$HOME/.local/bin/openclaw"
    ui_success "OpenClaw wrapper installed to \$HOME/.local/bin/openclaw"
    ui_info "此仓库使用 pnpm — 请运行 pnpm install（或 corepack pnpm install）安装依赖"
}

# Install OpenClaw
resolve_beta_version() {
    local beta=""
    beta="$(npm view openclaw dist-tags.beta 2>/dev/null || true)"
    if [[ -z "$beta" || "$beta" == "undefined" || "$beta" == "null" ]]; then
        return 1
    fi
    echo "$beta"
}

to_lowercase_ascii() {
    # macOS still ships Bash 3.2, so avoid `${value,,}` here.
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

is_explicit_package_install_spec() {
    local value="${1:-}"
    [[ "$value" == *"://"* || "$value" == *"#"* || "$value" =~ ^(file|github|git\+ssh|git\+https|git\+http|git\+file|npm): ]]
}

is_openclaw_source_package_install_spec() {
    local value="${1:-}"
    local normalized_value=""
    normalized_value="$(to_lowercase_ascii "$value")"
    normalized_value="${normalized_value#openclaw@}"

    [[ "$normalized_value" == "main" ]] && return 0
    [[ "$normalized_value" =~ ^github:openclaw/openclaw($|[#/]) ]] && return 0

    normalized_value="${normalized_value#git+}"
    [[ "$normalized_value" =~ ^https?://github\.com/openclaw/openclaw(\.git)?($|[?#]) ]] && return 0
    [[ "$normalized_value" =~ ^ssh://git@github\.com[:/]openclaw/openclaw(\.git)?($|[?#]) ]] && return 0
    [[ "$normalized_value" =~ ^git://github\.com/openclaw/openclaw(\.git)?($|[?#]) ]] && return 0
    [[ "$normalized_value" =~ ^git@github\.com:openclaw/openclaw(\.git)?($|[?#]) ]] && return 0
    return 1
}

can_resolve_registry_package_version() {
    local value="${1:-}"
    local normalized_value=""
    normalized_value="$(to_lowercase_ascii "$value")"
    if [[ -z "$value" ]]; then
        return 0
    fi
    if [[ "$normalized_value" == "main" ]]; then
        return 1
    fi
    if is_explicit_package_install_spec "$value"; then
        return 1
    fi
    return 0
}

resolve_package_install_spec() {
    local package_name="$1"
    local value="$2"
    local normalized_value=""
    normalized_value="$(to_lowercase_ascii "$value")"
    if [[ "$normalized_value" == "main" ]]; then
        echo "github:openclaw/openclaw#main"
        return 0
    fi
    if is_explicit_package_install_spec "$value"; then
        echo "$value"
        return 0
    fi
    if [[ "$value" == "latest" ]]; then
        echo "${package_name}@latest"
        return 0
    fi
    echo "${package_name}@${value}"
}

install_openclaw() {
    local package_name="openclaw"
    if [[ "$USE_BETA" == "1" ]]; then
        local beta_version=""
        beta_version="$(resolve_beta_version || true)"
        if [[ -n "$beta_version" ]]; then
            OPENCLAW_VERSION="$beta_version"
            ui_info "检测到测试版标签（${beta_version}）"
            package_name="openclaw"
        else
            OPENCLAW_VERSION="latest"
            ui_info "未找到测试版标签；使用最新版"
        fi
    fi

    if [[ -z "${OPENCLAW_VERSION}" ]]; then
        OPENCLAW_VERSION="latest"
    fi

    if is_openclaw_source_package_install_spec "${OPENCLAW_VERSION}"; then
        ui_error "npm installs do not support OpenClaw GitHub source targets like '${OPENCLAW_VERSION}'."
        ui_info "请使用 --install-method git --version main 获取最新 main 分支，或使用 latest、beta、精确版本号或已构建的 .tgz 包。"
        return 1
    fi

    local resolved_version=""
    if can_resolve_registry_package_version "${OPENCLAW_VERSION}"; then
        resolved_version="$(npm view "${package_name}@${OPENCLAW_VERSION}" version 2>/dev/null || true)"
    fi
    if [[ -n "$resolved_version" ]]; then
        ui_info "安装 OpenClaw v${resolved_version}"
    else
        ui_info "安装 OpenClaw（${OPENCLAW_VERSION}）"
    fi
    local install_spec=""
    install_spec="$(resolve_package_install_spec "${package_name}" "${OPENCLAW_VERSION}")"

    if ! install_openclaw_npm "${install_spec}"; then
        ui_warn "npm 安装失败；正在重试"
        cleanup_npm_openclaw_paths
        install_openclaw_npm "${install_spec}"
    fi

    if [[ "${OPENCLAW_VERSION}" == "latest" && "${package_name}" == "openclaw" ]]; then
        if ! resolve_openclaw_bin &> /dev/null; then
            ui_warn "npm install openclaw@latest 失败；重试 openclaw@next"
            cleanup_npm_openclaw_paths
            install_openclaw_npm "openclaw@next"
        fi
    fi

    ensure_openclaw_bin_link || true

    ui_success "OpenClaw 已安装"
}

# Run doctor for migrations (safe, non-interactive)
run_doctor() {
    ui_info "运行健康检查以迁移设置"
    local claw="${OPENCLAW_BIN:-}"
    if [[ -z "$claw" ]]; then
        claw="$(resolve_openclaw_bin || true)"
    fi
    if [[ -z "$claw" ]]; then
        ui_info "跳过健康检查（openclaw 尚未在 PATH 中）"
        warn_openclaw_not_found
        return 0
    fi
    run_quiet_step "运行健康检查" "$claw" doctor --non-interactive || true
    ui_success "健康检查完成"
}

maybe_open_dashboard() {
    local claw="${OPENCLAW_BIN:-}"
    if [[ -z "$claw" ]]; then
        claw="$(resolve_openclaw_bin || true)"
    fi
    if [[ -z "$claw" ]]; then
        return 0
    fi
    if ! "$claw" dashboard --help >/dev/null 2>&1; then
        return 0
    fi
    "$claw" dashboard || true
}

resolve_workspace_dir() {
    local profile="${OPENCLAW_PROFILE:-default}"
    local effective_home
    effective_home="$(resolve_openclaw_effective_home)"
    if [[ "${profile}" != "default" ]]; then
        echo "${effective_home}/.openclaw/workspace-${profile}"
    else
        echo "${effective_home}/.openclaw/workspace"
    fi
}

run_bootstrap_onboarding_if_needed() {
    if [[ "${NO_ONBOARD}" == "1" ]]; then
        return
    fi

    local effective_home
    effective_home="$(resolve_openclaw_effective_home)"
    local config_path="${OPENCLAW_CONFIG_PATH:-$effective_home/.openclaw/openclaw.json}"
    local legacy_config_path="${HOME}/.openclaw/openclaw.json"
    local legacy_clawdbot_path="${HOME}/.clawdbot/clawdbot.json"
    if [[ -f "${config_path}" || -f "$effective_home/.clawdbot/clawdbot.json" ]]; then
        return
    fi
    if [[ -z "${OPENCLAW_CONFIG_PATH:-}" && "${effective_home}" != "${HOME}" ]]; then
        if [[ -f "$legacy_config_path" || -f "$legacy_clawdbot_path" ]]; then
            return
        fi
    fi

    local workspace
    workspace="$(resolve_workspace_dir)"
    local bootstrap="${workspace}/BOOTSTRAP.md"

    if [[ ! -f "${bootstrap}" ]]; then
        return
    fi

    if ! is_promptable; then
        local user_claw
        user_claw="$(openclaw_command_for_user "${OPENCLAW_BIN:-}")"
        ui_info "发现 BOOTSTRAP.md 但无 TTY；请运行 ${user_claw} onboard 完成设置"
        return
    fi

    ui_info "发现 BOOTSTRAP.md；开始初次设置"
    local claw="${OPENCLAW_BIN:-}"
    if [[ -z "$claw" ]]; then
        claw="$(resolve_openclaw_bin || true)"
    fi
    if [[ -z "$claw" ]]; then
        ui_info "发现 BOOTSTRAP.md 但 openclaw 不在 PATH 中；跳过初次设置"
        warn_openclaw_not_found
        return
    fi

    "$claw" onboard || {
        local user_claw
        user_claw="$(openclaw_command_for_user "$claw")"
        ui_error "初次设置失败；请运行 ${user_claw} onboard 重试"
        return
    }
}

load_install_version_helpers() {
    local source_path="${BASH_SOURCE[0]-}"
    local script_dir=""
    local helper_path=""
    if [[ -z "$source_path" || ! -f "$source_path" ]]; then
        return 0
    fi
    if script_dir="$(cd "$(dirname "$source_path")" && pwd 2>/dev/null)"; then
        :
    else
        script_dir=""
    fi
    helper_path="${script_dir}/docker/install-sh-common/version-parse.sh"
    if [[ -n "$script_dir" && -r "$helper_path" ]]; then
        # shellcheck source=docker/install-sh-common/version-parse.sh
        # shellcheck disable=SC1091
        source "$helper_path"
    fi
}

load_install_version_helpers

if ! declare -F extract_openclaw_semver >/dev/null 2>&1; then
# Inline fallback when version-parse.sh could not be sourced (for example, stdin install).
extract_openclaw_semver() {
    local raw="${1:-}"
    raw="${raw//$'\r'/}"
    if [[ "$raw" =~ v?([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?(\+[0-9A-Za-z.-]+)?) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}
fi

resolve_openclaw_version() {
    local version=""
    local raw_version_output=""
    local claw="${OPENCLAW_BIN:-}"
    if [[ -z "$claw" ]] && command -v openclaw &> /dev/null; then
        claw="$(command -v openclaw)"
    fi
    if [[ -n "$claw" ]]; then
        raw_version_output=$("$claw" --version 2>/dev/null || true)
        raw_version_output="${raw_version_output%%$'\n'*}"
        raw_version_output="${raw_version_output//$'\r'/}"
        version="$(extract_openclaw_semver "$raw_version_output")"
        if [[ -z "$version" ]]; then
            version="$raw_version_output"
        fi
    fi
    if [[ -z "$version" ]]; then
        local npm_root=""
        npm_root=$(npm root -g 2>/dev/null || true)
        if [[ -n "$npm_root" && -f "$npm_root/openclaw/package.json" ]]; then
            version=$(node -e "console.log(require('${npm_root}/openclaw/package.json').version)" 2>/dev/null || true)
        fi
    fi
    echo "$version"
}

is_gateway_daemon_loaded() {
    local claw="$1"
    if [[ -z "$claw" ]]; then
        return 1
    fi

    local status_json=""
    status_json="$(bounded_probe_output "openclaw daemon status --json" "$claw" daemon status --json || true)"
    if [[ -z "$status_json" ]]; then
        return 1
    fi

    printf '%s' "$status_json" | node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8").trim();
if (!raw) process.exit(1);
try {
  const data = JSON.parse(raw);
  process.exit(data?.service?.loaded ? 0 : 1);
} catch {
  process.exit(1);
}
' >/dev/null 2>&1
}

refresh_gateway_service_if_loaded() {
    local claw="${OPENCLAW_BIN:-}"
    if [[ -z "$claw" ]]; then
        claw="$(resolve_openclaw_bin || true)"
    fi
    if [[ -z "$claw" ]]; then
        return 0
    fi

    if ! is_gateway_daemon_loaded "$claw"; then
        return 0
    fi

    ui_info "刷新已加载的网关服务"
    if run_quiet_step "刷新网关服务" "$claw" gateway install --force; then
        ui_success "网关服务元数据已刷新"
    else
        ui_warn "网关服务刷新失败；继续"
        return 0
    fi

    if run_quiet_step "重启网关服务" "$claw" gateway restart; then
        ui_success "网关服务已重启"
    else
        ui_warn "网关服务重启失败；继续"
        return 0
    fi

    run_quiet_step "探测网关服务" "$claw" gateway status --deep || true
}

verify_installation() {
    if [[ "${VERIFY_INSTALL}" != "1" ]]; then
        return 0
    fi

    ui_stage "验证安装"
    local claw="${OPENCLAW_BIN:-}"
    if [[ -z "$claw" ]]; then
        claw="$(resolve_openclaw_bin || true)"
    fi
    if [[ -z "$claw" ]]; then
        ui_error "安装验证失败：openclaw 尚未在 PATH 中"
        warn_openclaw_not_found
        return 1
    fi

    run_quiet_step "检查 OpenClaw 版本" "$claw" --version || return 1

    if is_gateway_daemon_loaded "$claw"; then
        run_quiet_step "检查网关服务" "$claw" gateway status --deep || {
            ui_error "安装验证失败：网关服务异常"
            ui_info "请运行：openclaw gateway status --deep"
            return 1
        }
    else
        ui_info "网关服务未加载；跳过网关深度探测"
    fi

    ui_success "安装验证完成"
}

# Main installation flow
main() {
    if [[ "$HELP" == "1" ]]; then
        print_usage
        return 0
    fi

    # bootstrap_gum_temp may perform network downloads before any spinner is available.
    echo -e "${INFO}正在准备安装器界面...${NC}"
    bootstrap_gum_temp || true
    print_installer_banner
    print_gum_status
    detect_os_or_die

    if [[ "$OS" == "linux" ]]; then
        export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
        export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
    fi

    local detected_checkout=""
    detected_checkout="$(detect_openclaw_checkout "$PWD" || true)"

    if [[ -z "$INSTALL_METHOD" && -n "$detected_checkout" ]]; then
        if ! is_promptable; then
            ui_info "发现 OpenClaw 本地仓库但无 TTY；默认使用 npm 安装"
            INSTALL_METHOD="npm"
        else
            local selected_method=""
            selected_method="$(choose_install_method_interactive "$detected_checkout" || true)"
            case "$selected_method" in
                git|npm)
                    INSTALL_METHOD="$selected_method"
                    ;;
                *)
                    ui_error "未选择安装方式"
                    echo "请使用 --install-method git|npm 重新运行（或设置 OPENCLAW_INSTALL_METHOD）。"
                    exit 2
                    ;;
            esac
        fi
    fi

    if [[ -z "$INSTALL_METHOD" ]]; then
        INSTALL_METHOD="npm"
    fi

    if [[ "$INSTALL_METHOD" != "npm" && "$INSTALL_METHOD" != "git" ]]; then
        ui_error "无效的 --install-method：${INSTALL_METHOD}"
        echo "请使用：--install-method npm|git"
        exit 2
    fi

    show_install_plan "$detected_checkout"

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_success "试运行完成（未做任何更改）"
        return 0
    fi

    # Check for existing installation
    local is_upgrade=false
    if check_existing_openclaw; then
        is_upgrade=true
    fi
    local should_open_dashboard=false
    local skip_onboard=false

    ui_stage "准备环境"

    # Step 1: Node.js. macOS package-manager branches install Homebrew lazily
    # only when they are about to call brew.
    load_nvm_for_node_detection
    if ! check_node; then
        install_homebrew
        install_node
    fi
    activate_supported_node_on_path || true
    if ! ensure_default_node_active_shell; then
        exit 1
    fi

    ui_stage "安装 OpenClaw"

    local final_git_dir=""
    if [[ "$INSTALL_METHOD" == "git" ]]; then
        # Clean up npm global install if switching to git
        if npm list -g openclaw &>/dev/null; then
            ui_info "移除 npm 全局安装（切换到 git）"
            npm uninstall -g openclaw 2>/dev/null || true
            ui_success "npm 全局安装已移除"
        fi

        local repo_dir="$GIT_DIR"
        if [[ -n "$detected_checkout" ]]; then
            repo_dir="$detected_checkout"
        fi
        final_git_dir="$repo_dir"
        install_openclaw_from_git "$repo_dir"
    else
        # Clean up git wrapper if switching to npm
        if [[ -x "$HOME/.local/bin/openclaw" ]]; then
            ui_info "移除 git 包装器（切换到 npm）"
            rm -f "$HOME/.local/bin/openclaw"
            ui_success "git 包装器已移除"
        fi

        # Step 3: Git (required for npm installs that may fetch from git or apply patches)
        if ! check_git; then
            install_git
        fi

        # Step 4: npm permissions (Linux)
        fix_npm_permissions

        # Step 5: OpenClaw
        install_openclaw
    fi

    ui_stage "完成设置"

    OPENCLAW_BIN="$(resolve_openclaw_bin || true)"
    warn_duplicate_openclaw_global_installs || true

    # PATH warning: installs can succeed while the user's login shell still lacks npm's global bin dir.
    local npm_bin=""
    npm_bin="$(npm_global_bin_dir || true)"
    if [[ "$INSTALL_METHOD" == "npm" ]]; then
        warn_shell_path_missing_dir "$npm_bin" "npm 全局 bin 目录"
    fi
    if [[ "$INSTALL_METHOD" == "git" ]]; then
        if [[ -x "$HOME/.local/bin/openclaw" ]]; then
            warn_shell_path_missing_dir "$HOME/.local/bin" "用户本地 bin 目录（~/.local/bin）"
        fi
    fi

    refresh_gateway_service_if_loaded

    # Step 6: Run doctor for migrations on upgrades and git installs
    local run_doctor_after=false
    if [[ "$is_upgrade" == "true" || "$INSTALL_METHOD" == "git" ]]; then
        run_doctor_after=true
    fi
    if [[ "$run_doctor_after" == "true" ]]; then
        run_doctor
        should_open_dashboard=true
    fi

    # Step 7: If BOOTSTRAP.md is still present in the workspace, resume onboarding
    run_bootstrap_onboarding_if_needed

    local installed_version
    installed_version=$(resolve_openclaw_version)

    echo ""
    if [[ -n "$installed_version" ]]; then
        ui_celebrate "🦞 OpenClaw (${installed_version}) 安装成功！"
    else
        ui_celebrate "🦞 OpenClaw 安装成功！"
    fi
    if [[ "$is_upgrade" == "true" ]]; then
        local update_messages=(
            "Leveled up! New skills unlocked. You're welcome."
            "全新代码，同一只龙虾。想我了吗？"
            "回来了，更好了。你注意到我离开了吗？"
            "更新完成。我不在的时候学了些新把戏。"
            "已升级！现在多了 23% 的俏皮。"
            "I've evolved. Try to keep up. 🦞"
            "新版本，你是谁？哦对，还是我，只是更闪亮了。"
            "Patched, polished, and ready to pinch. Let's go."
            "龙虾换壳了。更硬的壳，更锋利的钳。"
            "Update done! Check the changelog or just trust me, it's good."
            "从 npm 的沸水中重生。现在更强了。"
            "我离开后变得更聪明了。你也该试试。"
            "更新完成。Bug 怕我，所以它们跑了。"
            "新版本已安装。旧版本向你问好。"
            "固件刷新。脑回路：增加了。"
            "I've seen things you wouldn't believe. Anyway, I'm updated."
            "重新上线。更新日志很长，但我们的友谊更长。"
            "已升级！Peter 修复了一些东西。如果坏了怪他。"
            "Molting complete. Please don't look at my soft shell phase."
            "版本升级！同样的混乱能量，更少的崩溃（大概）。"
        )
        local update_message
        update_message="${update_messages[RANDOM % ${#update_messages[@]}]}"
        echo -e "${MUTED}${update_message}${NC}"
    else
        local completion_messages=(
            "啊不错，我喜欢这里。有零食吗？"
            "Home sweet home. Don't worry, I won't rearrange the furniture."
            "I'm in. Let's cause some responsible chaos."
            "安装完成。你的效率即将变得古怪。"
            "Settled in. Time to automate your life whether you're ready or not."
            "Cozy. I've already read your calendar. We need to talk."
            "终于拆包了。现在指向你的问题吧。"
            "咔嚓钳子 好了，我们造什么？"
            "龙虾已着陆。你的终端将永远不一样。"
            "全部完成！我保证只稍微评判一下你的代码。"
        )
        local completion_message
        completion_message="${completion_messages[RANDOM % ${#completion_messages[@]}]}"
        echo -e "${MUTED}${completion_message}${NC}"
    fi
    echo ""

    if [[ "$INSTALL_METHOD" == "git" && -n "$final_git_dir" ]]; then
        ui_section "源码安装详情"
        ui_kv "本地仓库" "$final_git_dir"
        ui_kv "入口脚本" "$HOME/.local/bin/openclaw"
        ui_kv "更新命令" "openclaw update"
        ui_kv "切换到 npm" "curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --install-method npm"
    elif [[ "$is_upgrade" == "true" ]]; then
        ui_info "升级完成"
        if has_controlling_tty || [[ "$NO_ONBOARD" == "1" || "$NO_PROMPT" == "1" ]]; then
            local claw="${OPENCLAW_BIN:-}"
            if [[ -z "$claw" ]]; then
                claw="$(resolve_openclaw_bin || true)"
            fi
            if [[ -z "$claw" ]]; then
                ui_info "跳过健康检查（openclaw 尚未在 PATH 中）"
                warn_openclaw_not_found
                return 0
            fi
            local -a doctor_args=()
            if [[ "$NO_ONBOARD" == "1" || "$NO_PROMPT" == "1" ]]; then
                doctor_args+=("--non-interactive")
            fi
            ui_info "运行 openclaw doctor"
            local doctor_ok=0
            if (( ${#doctor_args[@]} )); then
                OPENCLAW_UPDATE_IN_PROGRESS=1 "$claw" doctor "${doctor_args[@]}" </dev/null && doctor_ok=1
            else
                OPENCLAW_UPDATE_IN_PROGRESS=1 "$claw" doctor </dev/tty && doctor_ok=1
            fi
            if (( doctor_ok )); then
                ui_info "更新插件"
                OPENCLAW_UPDATE_IN_PROGRESS=1 "$claw" plugins update --all || true
            else
                ui_warn "Doctor 失败；跳过插件更新"
            fi
        else
            local user_claw
            user_claw="$(openclaw_command_for_user "${OPENCLAW_BIN:-}")"
            ui_info "无 TTY；请手动运行 ${user_claw} doctor 和 ${user_claw} plugins update --all"
        fi
    else
        if [[ "$NO_ONBOARD" == "1" || "$skip_onboard" == "true" ]]; then
            local user_claw
            user_claw="$(openclaw_command_for_user "${OPENCLAW_BIN:-}")"
            ui_info "已跳过初次设置；请稍后运行 ${user_claw} onboard"
        else
            local effective_home
            effective_home="$(resolve_openclaw_effective_home)"
            local config_path="${OPENCLAW_CONFIG_PATH:-$effective_home/.openclaw/openclaw.json}"
            if [[ -f "${config_path}" || -f "$effective_home/.clawdbot/clawdbot.json" ]]; then
                ui_info "配置已存在；运行健康检查"
                run_doctor
                should_open_dashboard=true
                ui_info "配置已存在；跳过初次设置"
                skip_onboard=true
            fi
            ui_info "开始初始化设置"
            echo ""
            if is_promptable; then
                local claw="${OPENCLAW_BIN:-}"
                if [[ -z "$claw" ]]; then
                    claw="$(resolve_openclaw_bin || true)"
                fi
                if [[ -z "$claw" ]]; then
                    ui_info "跳过初次设置（openclaw 尚未在 PATH 中）"
                    warn_openclaw_not_found
                    return 0
                fi
                exec </dev/tty
                exec "$claw" onboard
            fi
            local user_claw
            user_claw="$(openclaw_command_for_user "${OPENCLAW_BIN:-}")"
            ui_info "无 TTY；请运行 ${user_claw} onboard 完成设置"
            return 0
        fi
    fi

    if command -v openclaw &> /dev/null; then
        local claw="${OPENCLAW_BIN:-}"
        if [[ -z "$claw" ]]; then
            claw="$(resolve_openclaw_bin || true)"
        fi
        if [[ -n "$claw" ]] && is_gateway_daemon_loaded "$claw"; then
            if [[ "$DRY_RUN" == "1" ]]; then
                ui_info "检测到网关守护进程；将重启（openclaw daemon restart）"
            else
                ui_info "检测到网关守护进程；正在重启"
                if OPENCLAW_UPDATE_IN_PROGRESS=1 "$claw" daemon restart >/dev/null 2>&1; then
                    ui_success "网关已重启"
                else
                    ui_warn "网关重启失败；请尝试：openclaw daemon restart"
                fi
            fi
        fi
    fi

    if ! verify_installation; then
        exit 1
    fi

    if [[ "$should_open_dashboard" == "true" ]]; then
        maybe_open_dashboard
    fi

    show_footer_links
}

if [[ "${OPENCLAW_INSTALL_SH_NO_RUN:-0}" != "1" ]]; then
    parse_args "$@"
    configure_install_stage_total
    configure_verbose
    main
fi
