#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# realm-manager.sh — Realm 端口转发管理器（备注增强版）
#                    Debian / Ubuntu · amd64 / arm64
#
# 特性
#   · 备注是一等公民：添加时写、列表里显示、可随时改、删除前按备注确认
#   · 二进制走自建代理 https://docker.mmzs.space（REALM_MIRROR 可覆盖）
#   · musl 静态版，不依赖 glibc；下载后按 GitHub 官方 digest 校验 sha256
#   · 没有自动更新、不拉取任何第三方脚本、不误删 /etc 下无关文件
#
# 用法
#   curl -fsSL https://raw.githubusercontent.com/DK143297618/scripts/main/realm-manager.sh \
#        -o realm-manager.sh && chmod +x realm-manager.sh
#
#   ./realm-manager.sh                        # 交互菜单
#   ./realm-manager.sh install [版本]         # 安装 / 升级 realm 二进制
#   ./realm-manager.sh add <监听> <目标> [备注] [--multi t2,t3] [--balance rr|iphash]
#   ./realm-manager.sh list                   # 规则表（含备注与实时连接数）
#   ./realm-manager.sh note <序号> <新备注>   # 改备注
#   ./realm-manager.sh retarget <序号> <新目标>
#   ./realm-manager.sh del <序号>
#   ./realm-manager.sh status|start|stop|restart
#   ./realm-manager.sh backup | restore [备份文件]
#   ./realm-manager.sh cron <0-23> | cron-off
#   ./realm-manager.sh uninstall
#
# 环境变量
#   REALM_MIRROR   默认 https://docker.mmzs.space；填 direct 走 GitHub 直连
#   REALM_VARIANT  默认 full（含 proxy/balance/transport）；slim 体积小但缺这三项
#   REALM_VERSION  默认取最新；可固定，如 REALM_VERSION=2.9.6
#
# 实测：Debian 12 arm64 / realm 2.9.6 musl —— 安装、转发（HTTP 200）、备注增改删
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

REALM_DIR="/root/realm"
CONFIG_FILE="${REALM_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
LOG_FILE="/var/log/realm-manager.log"
CRON_TAG="realm-manager"
MIRROR="${REALM_MIRROR:-https://docker.mmzs.space}"
VARIANT="${REALM_VARIANT:-full}"
PINNED_VERSION="${REALM_VERSION:-}"
GH_REPO="zhboner/realm"
SCRIPT_VERSION="2.0.0"

# v2.9.6 官方 sha256（GitHub API digest 取不到时的兜底）
declare -A FALLBACK_SHA=(
    ["full:x86_64"]="b1cc335547bea8bb2a88178bef12ec7f2363e36200e7ea1d4e1e67627929bf65"
    ["full:aarch64"]="f4c0318dd86854da483dcb7645b4f39cae2cc3f91c688fef969d53220b949488"
    ["slim:x86_64"]="d5b7e8aee1b5c78486e0fc88d536f190bac8525c53bb61a65c2b583f0a84e6e8"
    ["slim:aarch64"]="cbe7da020de778d1d55faba037d8bdae48e386ed210c24cd461a4b7c05a44bba"
)

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }
title() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }
fail()  { err "$*"; exit 1; }
log()   { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
need_root() { [[ ${EUID} -eq 0 ]] || fail "需要 root 权限（用 sudo 或 root 登录）"; }

check_deps() {
    local miss=()
    for c in curl tar sha256sum systemctl ss; do
        command -v "$c" >/dev/null 2>&1 || miss+=("$c")
    done
    ((${#miss[@]})) || return 0
    warn "缺少命令：${miss[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        read -rp "用 apt-get 安装？(y/N): " c
        [[ "$c" == y || "$c" == Y ]] || fail "已取消"
        apt-get update -qq && apt-get install -y curl tar coreutils systemd iproute2 || fail "安装失败"
    else
        fail "请手动安装后重试：${miss[*]}"
    fi
}

# ── 镜像 / 下载 ───────────────────────────────────────────────────────────────
url_api() { if [[ "$MIRROR" == "direct" ]]; then echo "https://api.github.com/$1";
            else echo "${MIRROR%/}/api.github.com/$1"; fi; }
url_dl()  { if [[ "$MIRROR" == "direct" ]]; then echo "https://github.com/$1";
            else echo "${MIRROR%/}/github.com/$1"; fi; }

host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo x86_64 ;;
        aarch64|arm64) echo aarch64 ;;
        *) return 1 ;;
    esac
}

asset_name() {
    local arch; arch=$(host_arch) || return 1
    if [[ "$VARIANT" == "slim" ]]; then echo "realm-slim-${arch}-unknown-linux-musl.tar.gz"
    else echo "realm-${arch}-unknown-linux-musl.tar.gz"; fi
}

latest_version() {
    local json
    json=$(curl -fsSL --connect-timeout 15 "$(url_api "repos/${GH_REPO}/releases/latest")") || return 1
    echo "$json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
        | sed -E 's/.*"v?([0-9]+\.[0-9]+\.[0-9]+)".*/\1/'
}

api_digest() {  # $1=版本 $2=资产名 → hex（无 python3 依赖）
    local json
    json=$(curl -fsSL --connect-timeout 15 "$(url_api "repos/${GH_REPO}/releases/tags/v$1")" 2>/dev/null) || return 1
    printf '%s' "$json" | awk -v asset="$2" '
        { s = s $0 }
        END {
            gsub(/[ \t\r\n]/, "", s)
            key = "\"name\":\"" asset "\""
            p = index(s, key)
            if (p == 0) exit
            rest = substr(s, p)
            if (match(rest, /"digest":"sha256:[0-9a-f]+"/)) {
                d = substr(rest, RSTART, RLENGTH)
                sub(/.*sha256:/, "", d); gsub(/"/, "", d); print d
            }
        }'
}

do_install() {
    need_root; check_deps
    local ver="$1" arch asset dl tmp expect got bin before
    arch=$(host_arch) || fail "不支持的架构：$(uname -m)（仅 x86_64 / aarch64）"

    if [[ -z "$ver" ]]; then
        if [[ -n "${PINNED_VERSION:-}" ]]; then
            ver="${PINNED_VERSION#v}"; info "使用 REALM_VERSION 指定的版本 v$ver"
        else
            info "查询最新版本…"
            ver=$(latest_version) && info "最新版本 v$ver"
            ver="${ver:-2.9.6}"
        fi
    fi
    asset=$(asset_name "$ver") || fail "无法确定资产名"

    title "安装 Realm ${ver}（${VARIANT} · musl · ${arch}）"
    mkdir -p "$REALM_DIR"
    tmp=$(mktemp -d) || fail "创建临时目录失败"

    dl="$(url_dl "${GH_REPO}/releases/download/v${ver}/${asset}")"
    info "下载：$dl"
    if ! curl -fsSL --connect-timeout 20 --retry 2 -o "$tmp/$asset" "$dl"; then
        rm -rf "$tmp"; fail "下载失败 —— 检查网络 / 镜像 REALM_MIRROR=$MIRROR / 版本 v${ver} 是否有该资产"
    fi

    expect=$(api_digest "$ver" "$asset" | sed 's/^sha256://')
    if [[ -z "$expect" ]]; then
        expect="${FALLBACK_SHA["${VARIANT}:${arch}"]:-}"
        [[ -n "$expect" ]] && warn "取不到 API digest，改用内置校验值"
    fi
    got=$(sha256sum "$tmp/$asset" | awk '{print $1}')
    if [[ -n "$expect" ]]; then
        [[ "$got" == "$expect" ]] || { rm -rf "$tmp"; fail "sha256 校验失败！期望 ${expect:0:16}… 实际 ${got:0:16}…（镜像可能返回了错误内容）"; }
        info "sha256 校验通过 ${got:0:16}…"
    else
        warn "无可用校验值，跳过 sha256（实际 ${got:0:16}…）"
    fi

    tar -xzf "$tmp/$asset" -C "$tmp" || { rm -rf "$tmp"; fail "解压失败"; }
    bin=$(find "$tmp" -maxdepth 2 -type f -name 'realm*' ! -name '*.tar.gz' | head -1)
    [[ -n "$bin" ]] || { rm -rf "$tmp"; fail "压缩包里找不到 realm 二进制"; }
    [[ -f "${REALM_DIR}/realm" ]] && cp -f "${REALM_DIR}/realm" "${REALM_DIR}/realm.prev"
    install -m 0755 "$bin" "${REALM_DIR}/realm" || { rm -rf "$tmp"; fail "写入二进制失败"; }
    rm -rf "$tmp"

    write_config_if_missing
    write_service
    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1 || true
    if [[ -z "$(rules_tsv)" ]]; then
        info "安装完成：$("${REALM_DIR}/realm" --version 2>/dev/null | head -1)"
        warn "还没有任何规则 —— realm 需要至少 1 条 endpoint 才能启动，先 add 一条规则即可自动起服务"
        log "install $ver $VARIANT $arch (no rules yet)"
        return 0
    fi
    systemctl restart realm
    sleep 0.6
    if systemctl is-active --quiet realm; then
        info "安装完成：$("${REALM_DIR}/realm" --version 2>/dev/null | head -1)"
        log "install $ver $VARIANT $arch"
    else
        err "服务未启动，日志："
        journalctl -u realm -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    fi
}

write_config_if_missing() {
    [[ -f "$CONFIG_FILE" ]] && return 0
    cat > "$CONFIG_FILE" <<'EOF'
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF
    info "已生成默认配置 $CONFIG_FILE"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Proxy Service
Documentation=https://github.com/zhboner/realm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${REALM_DIR}/realm -c ${CONFIG_FILE}
Restart=always
RestartSec=2
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ── 规则解析（兼容旧 EZrealm 的 config.toml 布局）──────────────────────────────
# TSV：序号 起始行 listen remote extra_remotes balance 备注
rules_tsv() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    awk '
    function flush() {
        if (inb && (ln != "" || rm != ""))
            printf "%d\037%d\037%s\037%s\037%s\037%s\037%s\n", ++n, st, ln, rm, ex, bal, note
    }
    /^[[:space:]]*\[\[endpoints\]\]/ { flush(); inb=1; st=NR; ln=""; rm=""; ex=""; bal=""; note=""; next }
    !inb { next }
    /^[[:space:]]*#/ {
        t=$0; sub(/^[[:space:]]*#[[:space:]]*/,"",t); sub(/^备注[:：][[:space:]]*/,"",t)
        note = (note == "" ? t : note " " t); next
    }
    /^[[:space:]]*listen[[:space:]]*=/        { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/"/,"",v); ln=v; next }
    /^[[:space:]]*extra_remotes[[:space:]]*=/ { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/[][\"[:space:]]/,"",v); ex=v; next }
    /^[[:space:]]*remote[[:space:]]*=/        { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/"/,"",v); rm=v; next }
    /^[[:space:]]*balance[[:space:]]*=/       { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/"/,"",v); bal=v; next }
    END { flush() }
    ' "$CONFIG_FILE"
}

rule_field() { rules_tsv | awk -F'\037' -v i="$1" -v c="$2" '$1==i {print $c}'; }

conn_count() {
    local port="${1##*:}"
    ss -Htn state established "( sport = :${port} )" 2>/dev/null | wc -l | tr -d ' '
}

print_rules() {
    local tsv
    tsv=$(rules_tsv)
    if [[ -z "$tsv" ]]; then warn "还没有任何转发规则"; return 1; fi
    title "转发规则（共 $(echo "$tsv" | wc -l | tr -d ' ') 条）"
    printf "${BOLD}%-4s %-22s %-42s %-6s %s${NC}\n" "序号" "监听" "目标" "连接" "备注"
    echo "──── ────────────────────── ────────────────────────────────────────── ────── ──────────────────────"
    while IFS=$'\037' read -r idx st ln rm ex bal note; do
        local target="$rm"
        [[ -n "$ex" ]] && target="${rm} , ${ex}"
        [[ -n "$bal" ]] && target="${target} [${bal%%:*}]"
        printf "%-4s %-22s %-42s %-6s %s\n" "$idx" "$ln" "${target:0:42}" "$(conn_count "$ln")" "${note:--}"
    done <<< "$tsv"
}

# ── 增 / 删 / 改 ──────────────────────────────────────────────────────────────
validate_addr() {
    [[ "$1" =~ ^(\[[0-9a-fA-F:]+\]|[0-9a-fA-F.:]+|[A-Za-z0-9._-]+):[0-9]{1,5}$ ]] || return 1
    local p="${1##*:}"; (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

listen_in_use_by_other() {
    [[ -n "$(ss -Htln "sport = :${1##*:}" 2>/dev/null)" ]]
}

add_rule() {  # $1=listen $2=remote $3=备注 $4=extra_remotes $5=balance
    need_root
    local listen="$1" remote="$2" note="${3:-}" extra="${4:-}" balance="${5:-}"
    validate_addr "$listen" || fail "监听地址格式不对：$listen（形如 0.0.0.0:8443 / [::]:8443）"
    validate_addr "${remote%%,*}" || fail "目标地址格式不对：$remote（形如 1.2.3.4:443 / example.com:443）"
    if [[ -n "$extra" ]]; then
        local t; IFS=',' read -ra _ts <<< "$extra"
        for t in "${_ts[@]}"; do t="${t// /}"; [[ -z "$t" ]] && continue; validate_addr "$t" || fail "备用目标格式不对：$t"; done
    fi
    write_config_if_missing

    if rules_tsv | awk -F'\037' -v l="$listen" '$3==l {f=1} END{exit !f}'; then
        fail "$listen 已有规则在监听（先 list 看序号）"
    fi
    listen_in_use_by_other "$listen" && warn "$listen 已被其它进程监听，realm 可能起不来"

    note="${note//$'\n'/ }"
    [[ -z "$note" ]] && note="-"
    local before; before=$(wc -l < "$CONFIG_FILE")

    {
        echo
        echo "[[endpoints]]"
        echo "# 备注: ${note}"
        echo "listen = \"$listen\""
        echo "remote = \"$remote\""
        if [[ -n "$extra" ]]; then
            local arr="" t; IFS=',' read -ra _ts <<< "$extra"
            for t in "${_ts[@]}"; do
                t="${t// /}"; [[ -z "$t" ]] && continue
                arr+="\"$t\", "
            done
            echo "extra_remotes = [${arr%, }]"
        fi
        [[ -n "$balance" ]] && echo "balance = \"$balance\""
    } >> "$CONFIG_FILE"

    if restart_and_check; then
        info "已添加：$listen → $remote${extra:+ , $extra}　备注「$note」"
        log "add $listen -> $remote [$note]"
    else
        warn "服务异常，回滚配置…"
        head -n "$before" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        restart_and_check >/dev/null 2>&1 || true
        fail "添加失败（已回滚）"
    fi
}

del_rule() {
    need_root
    local idx="$1" st end note nxt_st
    [[ "$idx" =~ ^[0-9]+$ ]] || fail "序号必须是数字"
    st=$(rule_field "$idx" 2)
    [[ -n "$st" ]] || fail "没有第 $idx 条规则（先 list）"
    note=$(rule_field "$idx" 7)

    nxt_st=$(rules_tsv | awk -F'\037' -v i="$idx" '$1==i+1 {print $2; exit}')
    if [[ -n "$nxt_st" ]]; then end=$((nxt_st - 1)); else end=$(wc -l < "$CONFIG_FILE"); fi

    # 向前吃掉紧邻的备注行与空行，避免留垃圾
    while (( st > 1 )); do
        local prev; prev=$(sed -n "$((st-1))p" "$CONFIG_FILE")
        if [[ "$prev" =~ ^[[:space:]]*$ || "$prev" =~ ^[[:space:]]*# ]]; then st=$((st-1)); else break; fi
    done
    sed -i "${st},${end}d" "$CONFIG_FILE"

    if restart_and_check; then
        info "已删除第 $idx 条（备注「$note」）"
        log "del #$idx [$note]"
    else
        warn "删除后服务异常，请检查配置 $CONFIG_FILE"
        return 1
    fi
}

edit_rule() {  # $1=序号 $2=note|remote|listen $3=新值
    need_root
    local idx="$1" field="$2" val="$3" st nl
    [[ "$idx" =~ ^[0-9]+$ ]] || fail "序号必须是数字"
    st=$(rule_field "$idx" 2)
    [[ -n "$st" ]] || fail "没有第 $idx 条规则"

    case "$field" in
        note)
            val="${val//$'\n'/ }"
            local esc; esc=$(printf '%s' "$val" | sed 's/[&|\\]/\\&/g')
            nl=$(awk -v s="$st" 'NR>=s && /^[[:space:]]*#[[:space:]]*备注/ {print NR; exit}' "$CONFIG_FILE")
            if [[ -n "$nl" ]]; then
                sed -i "${nl}s|.*|# 备注: ${esc}|" "$CONFIG_FILE"
            else
                sed -i "${st}a # 备注: ${esc}" "$CONFIG_FILE"
            fi
            info "第 $idx 条备注 → 「$val」"
            log "note #$idx = $val"
            ;;
        remote|listen)
            validate_addr "$val" || fail "地址格式不对：$val"
            awk -v s="$st" -v k="$field" -v v="$val" '
                NR>s && !done && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k " = \"" v "\""; done=1; next }
                { print }' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
                && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            if restart_and_check; then info "第 $idx 条 $field → $val"; log "$field #$idx = $val"; fi
            ;;
        *) fail "不支持的字段：$field（note/remote/listen）" ;;
    esac
}

# ── 服务 / 备份 / 定时 / 卸载 ─────────────────────────────────────────────────
restart_and_check() {
    systemctl daemon-reload
    # realm 要求至少有一条 endpoint，否则直接 panic（配合 Restart=always 会变成 crash-loop）
    if [[ -z "$(rules_tsv)" ]]; then
        warn "配置里没有任何规则 —— realm 至少要有 1 条 endpoint 才能启动，服务保持停止"
        systemctl stop realm 2>/dev/null || true
        return 0
    fi
    systemctl restart realm
    sleep 0.6
    systemctl is-active --quiet realm && return 0
    err "realm 服务没起来，最近日志："
    journalctl -u realm -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
}

svc_status() {
    local state bin
    state=$(systemctl is-active realm 2>/dev/null || true); state=${state:-unknown}
    if [[ -x "${REALM_DIR}/realm" ]]; then bin=$("${REALM_DIR}/realm" --version 2>/dev/null | head -1); else bin="未安装"; fi
    echo "  服务：${state}    自启：$(systemctl is-enabled realm 2>/dev/null || echo -)    规则：$(rules_tsv | wc -l | tr -d ' ') 条"
    echo "  版本：${bin}"
    echo "  配置：${CONFIG_FILE}"
}

do_backup() {
    need_root
    [[ -f "$CONFIG_FILE" ]] || fail "没有配置文件"
    local f="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -f "$CONFIG_FILE" "$f" && info "已备份：$f"
    ls -1t "${CONFIG_FILE}".bak.* 2>/dev/null | tail -n +11 | xargs -r rm -f
}

do_restore() {
    need_root
    local f="$1"
    if [[ -z "$f" ]]; then
        title "可用备份"
        ls -1t "${CONFIG_FILE}".bak.* 2>/dev/null | head -10 | nl -w2 -s'. ' || fail "没有备份"
        read -rp "选择序号（回车取消）: " n
        [[ -z "$n" ]] && return 1
        f=$(ls -1t "${CONFIG_FILE}".bak.* 2>/dev/null | sed -n "${n}p")
    fi
    [[ -f "$f" ]] || fail "备份不存在：$f"
    cp -f "$CONFIG_FILE" "${CONFIG_FILE}.before-restore.$(date +%H%M%S)" 2>/dev/null || true
    cp -f "$f" "$CONFIG_FILE" && restart_and_check && info "已从 $f 恢复"
}

manage_cron() {
    need_root
    local hour="$1"
    if [[ "$hour" == "off" ]]; then
        sed -i "/${CRON_TAG}/d" /etc/crontab
        info "已清除本脚本的定时任务"
        return 0
    fi
    [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 )) || fail "小时需为 0-23"
    sed -i "/${CRON_TAG}/d" /etc/crontab 2>/dev/null
    echo "0 ${hour} * * * root /usr/bin/systemctl restart realm # ${CRON_TAG}" >> /etc/crontab
    info "已设置每天 ${hour} 点重启 realm"
}

do_uninstall() {
    need_root
    title "卸载 Realm"
    echo "  删除：$REALM_DIR、$SERVICE_FILE、cron 中带 ${CRON_TAG} 的行"
    read -rp "  确认？(y/N): " c
    [[ "$c" == y || "$c" == Y ]] || { warn "已取消"; return 1; }
    [[ -f "$CONFIG_FILE" ]] && do_backup
    systemctl stop realm 2>/dev/null || true
    systemctl disable realm 2>/dev/null || true
    rm -rf "$REALM_DIR" "$SERVICE_FILE"
    sed -i "/${CRON_TAG}/d" /etc/crontab 2>/dev/null || true
    systemctl daemon-reload
    info "已卸载（配置备份保留为 ${CONFIG_FILE}.bak.*）"
    log "uninstall"
}

# ── 交互菜单 ──────────────────────────────────────────────────────────────────
menu_add() {
    echo
    read -rp "监听地址（如 0.0.0.0:8443）: " listen;  [[ -z "$listen" ]] && return
    read -rp "目标地址（如 1.2.3.4:443）: "   remote;  [[ -z "$remote" ]] && return
    read -rp "备注（回车跳过）: "             note
    read -rp "备用目标（逗号分隔，回车跳过）: " extra
    local bal=""
    if [[ -n "${extra// /}" ]]; then
        read -rp "负载均衡 [roundrobin/iphash，回车=不加] : " bal
        if [[ -n "$bal" ]]; then
            local cnt; cnt=$(( $(tr -cd ',' <<< "$extra" | wc -c) + 2 ))
            local w=""; for ((i=0;i<cnt;i++)); do w+="1, "; done
            bal="${bal}: ${w%, }"
        fi
    fi
    add_rule "$listen" "$remote" "$note" "$extra" "$bal"
}

menu_delete() {
    print_rules || return
    read -rp "要删除的序号（回车取消）: " idx; [[ -z "$idx" ]] && return
    local note; note=$(rule_field "$idx" 7)
    read -rp "确认删除第 $idx 条（备注「${note:--}」）？(y/N): " c
    [[ "$c" == y || "$c" == Y ]] && del_rule "$idx"
}

menu_service() {
    echo; echo "  1) 启动   2) 停止   3) 重启   4) 只看状态"
    read -rp "  选择: " c
    case "$c" in
        1) systemctl enable --now realm && info "已启动" ;;
        2) systemctl stop realm && info "已停止" ;;
        3) restart_and_check && info "已重启" ;;
        4) ;;
        *) return ;;
    esac
    svc_status
}

menu_cron() {
    echo; echo "  1) 设置每日重启   2) 清除   3) 查看当前"
    read -rp "  选择: " c
    case "$c" in
        1) read -rp "  几点（0-23）: " h; manage_cron "$h" ;;
        2) manage_cron off ;;
        3) grep -n "$CRON_TAG" /etc/crontab 2>/dev/null || warn "没有本脚本添加的任务" ;;
    esac
}

menu() {
    need_root
    while true; do
        clear 2>/dev/null || true
        echo -e "${BOLD}${CYAN}"
        echo "  ╔════════════════════════════════════════════════════╗"
        printf "  ║        Realm 转发管理器（备注增强版） %-13s║\n" "v${SCRIPT_VERSION}"
        echo "  ╚════════════════════════════════════════════════════╝${NC}"
        svc_status
        echo
        echo "   1) 安装 / 升级 Realm         6) 服务管理（启停/重启）"
        echo "   2) 添加转发规则（带备注）    7) 定时任务（每日重启）"
        echo "   3) 查看转发规则             8) 查看服务日志"
        echo "   4) 修改备注 / 目标          9) 备份 / 恢复配置"
        echo "   5) 删除转发规则            10) 完全卸载"
        echo "                               0) 退出"
        echo
        read -rp "  请选择: " choice
        case "$choice" in
            1) read -rp "  指定版本（回车=最新）: " v; do_install "${v#v}" ;;
            2) menu_add ;;
            3) print_rules ;;
            4) echo; echo "  1) 改备注   2) 改目标   3) 改监听"; read -rp "  选择: " k
               case "$k" in
                   1) print_rules; read -rp "序号: " i; read -rp "新备注: " t; edit_rule "$i" note "$t" ;;
                   2) print_rules; read -rp "序号: " i; read -rp "新目标: " t; edit_rule "$i" remote "$t" ;;
                   3) print_rules; read -rp "序号: " i; read -rp "新监听: " t; edit_rule "$i" listen "$t" ;;
               esac ;;
            5) menu_delete ;;
            6) menu_service ;;
            7) menu_cron ;;
            8) journalctl -u realm -n 40 --no-pager 2>/dev/null | tail -40 ;;
            9) echo; echo "  1) 备份   2) 恢复"; read -rp "  选择: " k
               case "$k" in 1) do_backup ;; 2) do_restore "" ;; esac ;;
            10) do_uninstall && return ;;
            0|q|Q) return ;;
            *) warn "无效选项" ;;
        esac
        echo; read -rp "回车继续…" _ || true
    done
}

usage() { sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; }

# ── 入口 ──────────────────────────────────────────────────────────────────────
cmd="${1:-menu}"; shift || true
case "$cmd" in
    install)  do_install "${1:-}" ;;
    add)
        [[ $# -ge 2 ]] || fail "用法: add <监听> <目标> [备注] [--multi t2,t3] [--balance rr|iphash]"
        listen="$1"; remote="$2"
        if [[ $# -ge 3 ]]; then note="$3"; shift 3; else note=""; shift $#; fi
        extra=""; bal=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --multi)   extra="${2:-}"; shift 2 ;;
                --balance)
                    b="${2:-rr}"; shift 2
                    bt="${b%%:*}"; bw="${b#*:}"
                    [[ "$bt" == rr ]] && bt=roundrobin
                    case "$bt" in roundrobin|iphash) ;; *) fail "--balance 只支持 rr / iphash" ;; esac
                    if [[ "$bw" == "$b" ]]; then
                        cnt=$(( $(tr -cd ',' <<< "${extra:-}," | wc -c) + 1 ))
                        w=""; for ((i=0;i<cnt;i++)); do w+="1, "; done; bw="${w%, }"
                    fi
                    bal="${bt}: ${bw}" ;;
                *) shift ;;
            esac
        done
        [[ -n "$bal" && -z "$extra" ]] && warn "只给了 balance 没给 --multi，均衡无意义"
        add_rule "$listen" "$remote" "$note" "$extra" "$bal" ;;
    list|ls)  print_rules ;;
    dump)     printf '%s\n' "$(rules_tsv)" | cat -A ;;   # 诊断用：看原始 TSV 字段
    note)     [[ $# -ge 2 ]] || fail "用法: note <序号> <新备注>"; edit_rule "$1" note "$2" ;;
    retarget) [[ $# -ge 2 ]] || fail "用法: retarget <序号> <新目标>"; edit_rule "$1" remote "$2" ;;
    relisten) [[ $# -ge 2 ]] || fail "用法: relisten <序号> <新监听>"; edit_rule "$1" listen "$2" ;;
    del|rm)   [[ $# -ge 1 ]] || fail "用法: del <序号>"; del_rule "$1" ;;
    start)    need_root; systemctl enable --now realm && info "已启动" ;;
    stop)     need_root; systemctl stop realm && info "已停止" ;;
    restart)  need_root; restart_and_check && info "已重启" ;;
    status)   svc_status ;;
    backup)   do_backup ;;
    restore)  do_restore "${1:-}" ;;
    cron)     manage_cron "${1:-}" ;;
    cron-off) manage_cron off ;;
    uninstall) do_uninstall ;;
    -v|--version) echo "realm-manager.sh ${SCRIPT_VERSION}" ;;
    -h|--help|help) usage ;;
    menu|"")  menu ;;
    *) err "未知命令：$cmd"; echo; usage; exit 1 ;;
esac
