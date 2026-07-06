#!/usr/bin/env bash
# =============================================================================
#  Egress Manager —— 轻量级出网策略路由管理工具
#  功能: 为任意服务（Snell、SS、SOCKS等）按实例绑定不同的出站IP
#  实现原理: cgroup v2 + fwmark + 自定义路由表 + SNAT
#  
#  使用场景:
#    - 单VPS多IP: 不同入站端口使用不同出站IP
#    - 多协议混跑: 各协议实例独立出网策略
#    - 出口IP轮转: 服务重启时可更新出网配置
#
#  系统要求:
#    - Linux kernel 4.15+ (cgroup v2, conntrack)
#    - iptables + ipset + iproute2
#    - systemd (服务管理)
#
#  使用方式:
#    bash egress-manager.sh --help
# =============================================================================

set -euo pipefail

# ---------- 配置 ----------
PROG_NAME="egress-manager"
PROG_VERSION="1.0.0"
EGRESS_DIR="${EGRESS_DIR:-/etc/egress-manager}"
EGRESS_HELPER="${EGRESS_HELPER:-/usr/local/bin/egress-helper.sh}"
EGRESS_TABLE_MIN="${EGRESS_TABLE_MIN:-700}"
EGRESS_TABLE_MAX="${EGRESS_TABLE_MAX:-899}"
SYSTEMD_DIR="/etc/systemd/system"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
PLAIN='\033[0m'

msg()  { echo -e "${CYAN}➜${PLAIN}  $*"; }
ok()   { echo -e "${GREEN}✓${PLAIN}  $*"; }
warn() { echo -e "${YELLOW}!${PLAIN}  $*"; }
err()  { echo -e "${RED}✗${PLAIN}  $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- 前置检查 ----------
check_root() {
    [[ $EUID -eq 0 ]] || die "需要root权限运行此脚本"
}

check_deps() {
    local missing=()
    for cmd in iptables ip systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "缺少必要工具: ${missing[*]}"
    fi
}

check_cgroup_v2() {
    if ! grep -q "cgroup2" /proc/filesystems; then
        die "系统不支持 cgroup v2，需要 Linux 4.15+ 并启用 systemd unified hierarchy"
    fi
}

# ---------- 路由表管理 ----------
egress_alloc_table() {
    local table
    for table in $(seq "$EGRESS_TABLE_MIN" "$EGRESS_TABLE_MAX"); do
        # 检查该表号是否已被使用
        if ! ip route show table "$table" 2>/dev/null | grep -q .; then
            echo "$table"
            return 0
        fi
    done
    return 1
}

# ---------- Helper脚本生成 ----------
egress_write_helper() {
    cat > "${EGRESS_HELPER}" <<'EGEOF'
#!/usr/bin/env bash
# Egress Helper —— 由 egress-manager 自动生成
# 职责: 在 systemd 服务启停时，应用/移除出网策略路由规则

set -uo pipefail

ACTION="${1:-}"; SVC="${2:-}"
DIR="/etc/egress-manager"
CONF="${DIR}/${SVC}.conf"

# 未配置出网策略则直接返回
[[ -n "${SVC}" && -f "${CONF}" ]] || exit 0

iface=""; gateway=""; subnet=""; srcip=""; table=""; mark=""
# shellcheck disable=SC1090
. "${CONF}"

[[ -n "${iface}" && -n "${table}" && -n "${mark}" ]] || exit 0

# cgroup 路径: systemd 将服务放在 system.slice 下
CG="system.slice/${SVC}.service"

# ========== 工具函数 ==========

# 计算该出网路径的源IP: 优先级 srcip > gateway推导 > subnet推导 > 网卡首IP
eg_src_ip() {
    local s=""
    if [[ -n "${srcip}" ]]; then
        printf '%s' "${srcip}"; return
    fi
    if [[ -n "${gateway}" ]]; then
        s=$(ip route get "${gateway}" 2>/dev/null | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -n1)
    fi
    if [[ -z "${s}" && -n "${subnet}" ]]; then
        s=$(ip route get "${subnet%/*}" 2>/dev/null | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -n1)
    fi
    if [[ -z "${s}" ]]; then
        s=$(ip -o -4 addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | sed 's#/.*##' | head -n1)
    fi
    printf '%s' "${s}"
}

# 启用出网策略路由
eg_up() {
    local SRC; SRC=$(eg_src_ip)
    
    # 放宽反向路径检查，允许非对称路由
    sysctl -w "net.ipv4.conf.all.rp_filter=2" >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.conf.${iface}.rp_filter=2" >/dev/null 2>&1 || true
    
    # 创建/清空自定义路由表
    ip route flush table "${table}" 2>/dev/null || true
    
    # 添加子网路由（如果指定）
    if [[ -n "${subnet}" ]]; then
        ip route replace "${subnet}" dev "${iface}" table "${table}" 2>/dev/null || true
    fi
    
    # 添加默认路由
    if [[ -n "${gateway}" ]]; then
        ip route replace default via "${gateway}" dev "${iface}" ${SRC:+src ${SRC}} table "${table}" 2>/dev/null \
            || ip route replace default via "${gateway}" dev "${iface}" table "${table}" 2>/dev/null || true
    else
        ip route replace default dev "${iface}" ${SRC:+src ${SRC}} table "${table}" 2>/dev/null \
            || ip route replace default dev "${iface}" table "${table}" 2>/dev/null || true
    fi
    
    # 添加策略路由规则: fwmark -> 自定义表
    ip rule list 2>/dev/null | grep -qw "lookup ${table}" \
        || ip rule add fwmark "${mark}" lookup "${table}" 2>/dev/null || true
    
    # mangle OUTPUT: 为该service新发出的连接打标记
    # - ESTABLISHED,RELATED: 恢复 connmark（回程流量用主表，不改源IP）
    # - NEW: 打上新标记 + 保存到 connmark
    iptables -t mangle -C OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark 2>/dev/null \
        || iptables -t mangle -A OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark 2>/dev/null || true
    
    iptables -t mangle -C OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate NEW -j MARK --set-mark "${mark}" 2>/dev/null \
        || iptables -t mangle -A OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate NEW -j MARK --set-mark "${mark}" 2>/dev/null || true
    
    iptables -t mangle -C OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate NEW -j CONNMARK --save-mark 2>/dev/null \
        || iptables -t mangle -A OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate NEW -j CONNMARK --save-mark 2>/dev/null || true
    
    # POSTROUTING SNAT: 改变源地址使出口身份真正切换
    if [[ -n "${SRC}" ]]; then
        iptables -t nat -C POSTROUTING -m mark --mark "${mark}" -j SNAT --to-source "${SRC}" 2>/dev/null \
            || iptables -t nat -A POSTROUTING -m mark --mark "${mark}" -j SNAT --to-source "${SRC}" 2>/dev/null || true
    fi
}

# 禁用出网策略路由
eg_down() {
    local SRC; SRC=$(eg_src_ip)
    
    # 删除 SNAT 规则
    if [[ -n "${SRC}" ]]; then
        iptables -t nat -D POSTROUTING -m mark --mark "${mark}" -j SNAT --to-source "${SRC}" 2>/dev/null || true
    fi
    
    # 兜底: 删除任何指向本 mark 的 SNAT 残留
    while iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "--mark ${mark} .*SNAT"; do
        local rule; rule=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -m1 -- "--mark ${mark} .*SNAT")
        [[ -n "${rule}" ]] || break
        # shellcheck disable=SC2086
        iptables -t nat ${rule/-A/-D} 2>/dev/null || break
    done
    
    # 删除 mangle 规则
    iptables -t mangle -D OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate NEW -j CONNMARK --save-mark 2>/dev/null || true
    iptables -t mangle -D OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate NEW -j MARK --set-mark "${mark}" 2>/dev/null || true
    iptables -t mangle -D OUTPUT -m cgroup --path "${CG}" -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark 2>/dev/null || true
    
    # 删除策略路由规则
    ip rule del fwmark "${mark}" lookup "${table}" 2>/dev/null || true
    ip route flush table "${table}" 2>/dev/null || true
}

# ========== 主逻辑 ==========
case "${ACTION}" in
    up)   eg_up ;;
    down) eg_down ;;
    *)    exit 0 ;;
esac

exit 0
EGEOF
    chmod 755 "${EGRESS_HELPER}"
}

# ---------- Systemd Drop-in 管理 ----------
egress_install_dropin() {
    local svc="$1"
    local d="${SYSTEMD_DIR}/${svc}.service.d"
    mkdir -p "${d}"
    cat > "${d}/egress.conf" <<EOF
[Service]
ExecStartPost=-${EGRESS_HELPER} up ${svc}
ExecStopPost=-${EGRESS_HELPER} down ${svc}
EOF
    chmod 644 "${d}/egress.conf"
}

egress_remove_dropin() {
    local svc="$1"
    rm -f "${SYSTEMD_DIR}/${svc}.service.d/egress.conf"
    rmdir "${SYSTEMD_DIR}/${svc}.service.d" 2>/dev/null || true
}

# ---------- 配置保存/删除 ----------
egress_save() {
    local svc="$1" ifc="$2" gw="$3" net="$4" src="${5:-}"
    
    mkdir -p "${EGRESS_DIR}"
    local conf="${EGRESS_DIR}/${svc}.conf"
    local table=""
    
    # 复用已分配的路由表
    [[ -f "${conf}" ]] && table=$(awk -F= '/^table=/{print $2}' "${conf}" 2>/dev/null | head -n1)
    
    if [[ -z "${table}" ]]; then
        table=$(egress_alloc_table) || {
            warn "无可用路由表号 (${EGRESS_TABLE_MIN}-${EGRESS_TABLE_MAX} 已满)"
            return 1
        }
    fi
    
    {
        echo "service=${svc}"
        echo "iface=${ifc}"
        echo "gateway=${gw}"
        echo "subnet=${net}"
        echo "srcip=${src}"
        echo "table=${table}"
        echo "mark=${table}"
    } > "${conf}"
    
    chmod 600 "${conf}"
    egress_write_helper
    egress_install_dropin "${svc}"
    
    ok "已保存出网配置: ${conf}"
    ok "路由表号: ${table}, firewall mark: ${table}"
    return 0
}

egress_remove() {
    local svc="$1"
    local conf="${EGRESS_DIR}/${svc}.conf"
    
    if [[ ! -f "${conf}" ]]; then
        warn "未找到配置: ${conf}"
        return 1
    fi
    
    # 先执行清理，再删除文件
    [[ -x "${EGRESS_HELPER}" ]] && "${EGRESS_HELPER}" down "${svc}" 2>/dev/null || true
    
    rm -f "${conf}"
    egress_remove_dropin "${svc}"
    
    ok "已删除出网配置: ${svc}"
    return 0
}

egress_show() {
    local svc="$1"
    local conf="${EGRESS_DIR}/${svc}.conf"
    
    if [[ ! -f "${conf}" ]]; then
        err "未找到配置: ${svc}"
        return 1
    fi
    
    echo
    echo "出网策略配置: ${svc}"
    echo "────────────────────────────────────────"
    cat "${conf}" | sed 's/^/  /'
    echo "────────────────────────────────────────"
    echo
}

# ---------- 列表/查询 ----------
egress_list() {
    if [[ ! -d "${EGRESS_DIR}" ]]; then
        msg "未发现配置目录，暂无服务配置出网策略"
        return 0
    fi
    
    local count=0
    echo
    echo "已配置的出网策略:"
    echo "────────────────────────────────────────"
    
    for conf in "${EGRESS_DIR}"/*.conf; do
        [[ -f "$conf" ]] || continue
        local svc; svc=$(basename "$conf" .conf)
        local ifc gw net src table
        ifc=$(awk -F= '/^iface=/{print $2}' "$conf" 2>/dev/null | head -n1)
        gw=$(awk -F= '/^gateway=/{print $2}' "$conf" 2>/dev/null | head -n1)
        net=$(awk -F= '/^subnet=/{print $2}' "$conf" 2>/dev/null | head -n1)
        src=$(awk -F= '/^srcip=/{print $2}' "$conf" 2>/dev/null | head -n1)
        table=$(awk -F= '/^table=/{print $2}' "$conf" 2>/dev/null | head -n1)
        
        printf "  %-30s table=%-4s  iface=%-10s\n" "${svc}" "${table}" "${ifc}"
        [[ -n "${src}" ]] && printf "    └─ 出站IP: %s\n" "${src}"
        [[ -n "${gw}" ]] && printf "    └─ 网关: %s\n" "${gw}"
        [[ -n "${net}" ]] && printf "    └─ 子网: %s\n" "${net}"
        count=$((count + 1))
    done
    
    if (( count == 0 )); then
        msg "暂无服务配置"
    else
        echo "────────────────────────────────────────"
        ok "共 ${count} 个服务配置了出网策略"
    fi
    echo
}

# ---------- 路由表查看 ----------
egress_show_routes() {
    echo
    echo "自定义路由表 (${EGRESS_TABLE_MIN}-${EGRESS_TABLE_MAX}):"
    echo "────────────────────────────────────────"
    
    local found=0
    for table in $(seq "$EGRESS_TABLE_MIN" "$EGRESS_TABLE_MAX"); do
        if ip route show table "$table" 2>/dev/null | grep -q .; then
            found=1
            echo "表 ${table}:"
            ip route show table "$table" 2>/dev/null | sed 's/^/  /'
            echo
        fi
    done
    
    if (( found == 0 )); then
        msg "未发现活跃的自定义路由表"
    fi
    echo
}

# ---------- 规则查看 ----------
egress_show_rules() {
    echo
    echo "策略路由规则:"
    echo "────────────────────────────────────────"
    ip rule show 2>/dev/null | grep -E "lookup (70[0-9]|8[0-9][0-9])" | sed 's/^/  /' || msg "未发现策略路由规则"
    echo
}

# ---------- 帮助文本 ----------
show_help() {
    cat <<EOF
${BOLD}${CYAN}${PROG_NAME} v${PROG_VERSION}${PLAIN} - 轻量级出网策略路由管理工具

${BOLD}用法:${PLAIN}
  sudo bash egress-manager.sh COMMAND [OPTIONS]

${BOLD}命令:${PLAIN}
  set <service> <iface> <gateway> <subnet> [srcip]
      为服务配置出网策略
      示例: set snell-443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.5
            set ss-8388 eth1 192.168.1.1 192.168.1.0/24

  remove <service>
      删除服务的出网策略配置
      示例: remove snell-443

  show <service>
      显示指定服务的出网策略详情
      示例: show snell-443

  list
      列表显示所有已配置的出网策略

  routes
      显示当前活跃的自定义路由表

  rules
      显示当前活跃的策略路由规则

  init
      初始化: 创建配置目录和 helper 脚本（仅需运行一次）

  help
      显示此帮助信息

  version
      显示版本信息

${BOLD}参数说明:${PLAIN}
  <service>     systemd 服务名称（如 snell-443, ss-8388）
  <iface>       出网网卡名（如 eth0, eth1）
  <gateway>     出网网关IP（如 10.0.0.1）；留空用 - 表示直连
  <subnet>      出网网段CIDR（如 10.0.0.0/24）；留空用 -
  [srcip]       出网源IP（多IP必须显式指定；可选）

${BOLD}工作原理:${PLAIN}
  1. 每个服务分配独立的路由表号和 fwmark
  2. 服务启动时，helper 脚本自动配置:
     - 创建自定义路由表
     - 通过 cgroup 标记该服务的出站流量
     - 在 POSTROUTING 做 SNAT 改源IP
  3. 服务停止时自动清理所有规则

${BOLD}典型场景:${PLAIN}
  # VPS有多个IP: 443端口走10.0.0.5，8443端口走10.0.0.6
  sudo bash egress-manager.sh init
  sudo bash egress-manager.sh set snell-443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.5
  sudo bash egress-manager.sh set snell-8443 eth0 10.0.0.1 10.0.0.0/24 10.0.0.6
  systemctl restart snell-443 snell-8443

${BOLD}系统要求:${PLAIN}
  - Linux 4.15+ (cgroup v2, conntrack)
  - iptables + iproute2 + systemd
  - root 权限

${BOLD}配置文件位置:${PLAIN}
  - 配置目录: ${EGRESS_DIR}
  - Helper脚本: ${EGRESS_HELPER}
  - 路由表范围: ${EGRESS_TABLE_MIN}-${EGRESS_TABLE_MAX}

EOF
}

# ---------- 主逻辑 ----------
main() {
    check_root
    check_deps
    check_cgroup_v2
    
    local cmd="${1:-help}"
    shift || true
    
    case "${cmd}" in
        set)
            [[ $# -ge 4 ]] || die "set 命令需要至少4个参数"
            local svc="$1" ifc="$2" gw="$3" net="$4" src="${5:-}"
            [[ "${gw}" == "-" ]] && gw=""
            [[ "${net}" == "-" ]] && net=""
            egress_save "$svc" "$ifc" "$gw" "$net" "$src"
            ;;
        remove)
            [[ $# -ge 1 ]] || die "remove 命令需要服务名参数"
            egress_remove "$1"
            ;;
        show)
            [[ $# -ge 1 ]] || die "show 命令需要服务名参数"
            egress_show "$1"
            ;;
        list)
            egress_list
            ;;
        routes)
            egress_show_routes
            ;;
        rules)
            egress_show_rules
            ;;
        init)
            msg "初始化出网管理系统..."
            mkdir -p "${EGRESS_DIR}"
            egress_write_helper
            chmod 755 "${EGRESS_HELPER}"
            ok "初始化完成"
            ok "配置目录: ${EGRESS_DIR}"
            ok "Helper脚本: ${EGRESS_HELPER}"
            ;;
        version)
            echo "${PROG_NAME} v${PROG_VERSION}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            err "未知命令: ${cmd}"
            echo "使用 'bash egress-manager.sh help' 查看帮助"
            exit 1
            ;;
    esac
}

main "$@"
