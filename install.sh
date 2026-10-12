#!/bin/bash
# ============================================================
# install.sh —— 部署器（§5 M9）
#
# 子命令：
#   genconf   生成主/备两份配置骨架（键集合正确、角色正确、值全部留空）
#   install   部署节点（--role primary|standby）
#   venv      按所选适配器决定装什么（只配网络探测时**一个依赖都不装**）
#   arbiter   部署仲裁节点
#   check     自检：可达性 / 权限 / 上报 / 适配器真跑 / 三份配置一致性
#   manifest  脚本与配置的 md5 比对
#
# ============================================================
# ★★ 一条贯穿全文的规则：密码永远不离开目标机器
# ============================================================
#   genconf 生成的骨架里**密码字段全部为空**，一个凭据都不带 ——
#   因为它可能被放进仲裁节点的分发目录（644，谁都能读）。
#   人在这台机器上把值填进**本机**的文件，install 再以那个文件为数据源。
#   所以：没有凭据进版本库，没有凭据过网络，没有凭据出现在命令历史里。
#
# ============================================================
# ★ 为什么这个 .sh 里嵌了十几段 Python
# ============================================================
#   它做两类事：① 文件、权限、systemd、apt —— 这是 shell 的活；
#   ② 解析配置、判空密码、比对三份配置 —— 这是**字符串判断**的活。
#
#   第二类在 bash 里全靠在字符串上做模式匹配，而它们的每一种错法都会
#   **静默地**把"配置有问题"变成"配置没问题" —— 那正是这套系统最怕的
#   一类错误（密码为空时系统能装完、能启动、看起来正常）。
#   所以：凡是"判断"都放进能被 py_compile 检查的 Python 里，
#   bash 只负责搬文件和调 systemd。这与 run-adapters.sh 的理由是同一条。
#
# ============================================================
# 退出码（§7.2）
#   0 成功    1 拒绝/校验不通过    2 参数或配置错误    3 依赖不可达
# ============================================================

set -u

SRC=$(cd -- "$(dirname -- "$0")" && pwd)
PY=/usr/bin/python3

# ★ PROG 是提示语里"重新跑：sudo $PROG install"要用的名字。
#   它**必须**在这里赋值：本脚本开着 set -u，而这几条提示恰好出现在
#   "第一次跑（落骨架等人填）"和"安装成功收尾"这两条路径上 ——
#   没赋值的话，前者的指引会变成一句 "PROG: unbound variable"，
#   后者会在**已经装好之后**报错退出，让人以为装失败了。
PROG=${0:-install.sh}

# ---- 目标路径（★ 与代码里的字面量必须一致，改这里等于改全部）----
HA_DIR=/opt/simplified-ha          # halib.HA_DIR
ARBITER_DIR=/opt/zbx-arbiter       # arbiter.py: ARBITER_DIR
ARBITER_ETC=/etc/zbx-arbiter
ARBITER_ADAPTER_DIR=$ARBITER_ETC/adapters
ARBITER_ADAPTER_CONF_DIR=$ARBITER_ETC/adapters.d
ARBITER_CONF=$ARBITER_ETC/arbiter.conf
ARBITER_STATE=/var/lib/zbx-arbiter
NODE_STATE=/var/lib/zbx-ha
SYSTEMD_DIR=/etc/systemd/system
DIST_DIR_DEFAULT=/srv/zbx-ha-dist

DRY_RUN=no

# ============================================================
# 输出
# ============================================================

c_red=''; c_grn=''; c_yel=''; c_off=''
if [ -t 1 ]; then
    c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
fi

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s[OK]%s %s\n' "$c_grn" "$c_off" "$*"; }
bad()  { printf '  %s[!!]%s %s\n' "$c_red" "$c_off" "$*"; }
warn() { printf '  %s[??]%s %s\n' "$c_yel" "$c_off" "$*"; }
title() { printf '\n=== %s ===\n' "$*"; }
hr()   { printf -- '------------------------------------------------------------\n'; }

# ★ 配置类错误一律 exit 2（§7.2：参数或配置错误）。
die() {
    printf '\n%s部署中止：%s%s\n' "$c_red" "$*" "$c_off" >&2
    exit 2
}

# 干跑（N10：所有脚本支持 --dry-run）
run() {
    if [ "$DRY_RUN" = yes ]; then
        printf '      [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

need_root() {
    [ "$DRY_RUN" = yes ] && return 0
    [ "$(id -u)" = 0 ] || die "需要 root（当前 uid=$(id -u)）。请用 sudo 运行。"
}

# 发行版自检（§5 M9 末）
#   install / check → Debian 系
#   arbiter        → ★ Ubuntu 22.04（与生产同发行版，避免假阴性）
require_distro() {
    local kind="$1" id="" ver=""
    [ -r /etc/os-release ] || die "读不到 /etc/os-release，无法判断发行版。"
    # shellcheck disable=SC1091
    . /etc/os-release
    id=${ID:-unknown}
    ver=${VERSION_ID:-unknown}

    case "$kind" in
    arbiter)
        [ "$id" = ubuntu ] || die "仲裁节点必须是 Ubuntu（当前 ID=$id）。
        仲裁节点与生产环境**同发行版**是有意的：适配器在发行版之间的行为差异
        （arping 的两个包、python3 版本、systemd 的 PATH）会在故障当天才暴露，
        而那时候你不会想到是发行版的问题。"
        [ "$ver" = 22.04 ] || die "仲裁节点必须是 Ubuntu 22.04（当前 $ver）。"
        ;;
    node)
        case "$id" in
        ubuntu|debian) : ;;
        *) die "节点必须是 Debian 系（当前 ID=$id）。
        本套脚本按 Debian 系的 PG 布局写死了：配置在 /etc/postgresql/17/main、
        集群单元叫 postgresql@17-main、用 pg_ctlcluster 管理。
        AlmaLinux 版是**另一套代码**，不要混用，也不要指望它能跑。" ;;
        esac
        ;;
    esac
    info "发行版自检：$id $ver ✓"
}

# ============================================================
# 配置读取
# ============================================================
# ★ 解析规则必须与 halib.parse_conf / ha-guard-pg.py / arbiter.py 完全一致：
#   只把整行以 # 开头的当注释，不做行内注释剥离（值里可能有 #）。

# ★ 前缀是为了**两个文件互不覆盖**：节点上有 cluster.conf 和 node.conf，
#   而 NODE_ROLE 只在后者里、其余键只在前者里。用同一套变量名加载两份文件，
#   后加载的那份会把先加载的**整片抹掉** —— 于是"检查 NODE_ROLE"永远读到空，
#   检查项静默失效。所以：cluster.conf → CONF_*，node.conf → NCONF_*。
#
# ★ 为什么清旧值用的是**写死的键清单**，而不是遍历前缀：
#   bash 的 ${!pfx@} 里那个 pfx 是**字面量**，不是变量名 ——
#   写 ${!pfx@} 得到的是"以 pfx 开头的变量"，一个都清不掉，还不报错。
#   而这个脚本**读哪些键**本来就是有限的、已知的，所以直接列出来：
#   清单少写一个键的后果是那个键可能读到上一次的旧值 —— 比不报错更值得防。
ALL_CONF_KEYS="NODE_A_IP NODE_B_IP VIP VIP_PREFIX NIC PGDATA PGBIN HA_DIR
PG_SERVICE PGCONF AUTO_PROMOTE AUTO_REJOIN ALERT_WEBHOOK ARBITER_URL ARBITER_TOKEN
VERDICT_MAX_AGE FORCE_TOKEN_TTL VIP_REBIND_DELAY REPL_LAG_TOLERANCE
REJOIN_STREAM_TIMEOUT CRED_SELFCHECK ARPING_BIN PG_SUPER_PWD PG_REPL_PWD
PG_ZBX_PWD PROBE_USER PROBE_PWD NODE_ROLE ARBITER_ADAPTER_DIR ADAPTER_TIMEOUT
JUDGE_LEVEL_ADAPTERS SELFCHECK_TARGETS MAINT_WINDOW_MAX ARBITER_ALLOW_FROM
LISTEN_ADDR LISTEN_PORT DIST_DIR VERDICT_TTL ARBITER_STATE_DIR"

conf_load() {
    local file="$1" pfx="${2:-CONF_}" k v line
    # ★ 只清**自己这个前缀**下的键。两个前缀一起清会让
    #   "先加载 cluster.conf、再加载 node.conf"这一步把前者的值全抹掉 ——
    #   而抹掉之后的所有 conf_get 都返回空，检查项静默变成"通过"。
    for k in $ALL_CONF_KEYS; do
        unset "${pfx}${k}"
    done
    [ -r "$file" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        k=${line%%$'\t'*}
        v=${line#*$'\t'}
        printf -v "$pfx$k" '%s' "$v"
    done < <("$PY" - "$file" <<'PY'
import sys

path = sys.argv[1]
try:
    fh = open(path, encoding="utf-8-sig")
except OSError:
    sys.exit(0)
with fh:
    for line in fh:
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
            v = v[1:-1]
        if "\t" in v or "\n" in v or "\r" in v:
            sys.stderr.write("  [??] 配置项 %s 的值里有制表符或换行，已跳过。\n" % k)
            continue
        sys.stdout.write("%s\t%s\n" % (k, v))
PY
)
}

conf_get() {
    local n="CONF_$1"
    printf '%s' "${!n-}"
}

nconf_load() {  # 读 node.conf —— 用独立前缀，不碰 cluster.conf 已加载的键
    conf_load "$1" NCONF_
}

nconf_get() {   # 读 node.conf 里的键（实际上只有 NODE_ROLE）
    local n="NCONF_$1"
    printf '%s' "${!n-}"
}

# ============================================================
# ★★ 空密码闸门（§5 M9）
# ============================================================
# 命中任一条即中止（exit 2）。**在写配置之前**跑 —— 失败时磁盘上什么都没动。
#
# 这条闸门存在的唯一理由：
#   密码为空时系统**能装完、能启动、看起来正常**，直到某天复制断了
#   或 Zabbix 连不上库才暴露。让它在安装那天就失败。
#
# ★ 报错信息里**永远不打印密码的值**，只说哪个键、哪一类问题。
config_gate() {
    local file="$1" mode="$2"
    "$PY" - "$file" "$mode" <<'PY'
import os
import re
import subprocess
import sys

path, mode = sys.argv[1], sys.argv[2]

# §8.3 的禁止字符集。它们会在**别的地方**（shell 插值、psql 命令行、
# PG 配置的引号里）造成不报错的截断或转义，所以不允许进密码。
FORBIDDEN = {"|", "&", "\\", "'", '"', " ", "$", "`"}
PLACEHOLDERS = ("__FILL_ME__", "FILL_ME", "CHANGEME", "CHANGE_ME", "TODO",
                "XXXXXX", "YYYYYY", "12345678", "PASSWORD")

if mode == "arbiter":
    REQUIRED = ["NODE_A_IP", "NODE_B_IP", "VIP", "ARBITER_TOKEN",
                "SELFCHECK_TARGETS", "ARBITER_ALLOW_FROM"]
    PWD_KEYS = []
    LABEL = "arbiter.conf"
else:
    REQUIRED = ["NODE_A_IP", "NODE_B_IP", "VIP", "NIC", "PGDATA",
                "ARBITER_URL", "ARBITER_TOKEN"]
    PWD_KEYS = ["PG_SUPER_PWD", "PG_REPL_PWD", "PG_ZBX_PWD", "PROBE_PWD"]
    LABEL = "cluster.conf"

d = {}
bad = []

if not os.path.isfile(path):
    print("  [!!] 读不到配置文件：%s" % path)
    sys.exit(2)

with open(path, encoding="utf-8-sig") as fh:
    for i, line in enumerate(fh, 1):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
            v = v[1:-1]
        if k in d:
            bad.append("第 %d 行：%s 重复了。**后一个会覆盖前一个** —— "
                       "重复的键几乎总是「改了一半」留下的，请删掉旧的。" % (i, k))
        d[k] = v

# ---- ① 必填项 ----
for k in REQUIRED:
    v = (d.get(k) or "").strip()
    if not v:
        bad.append("%s 为空。%s" % (k, "请先补齐（见 §5 M10）。"))

# ---- ② 密码：非空 / 非占位符 / 无禁止字符 ----
for k in PWD_KEYS:
    v = (d.get(k) or "").strip()
    if not v:
        bad.append("%s 为空。请先补齐密码（见 §5 M10）。\n"
                   "         ★ 值只能在本机填写 —— 模板里刻意留空，"
                   "就是这个原因。")
        continue
    up = v.upper()
    if any(p in up for p in PLACEHOLDERS):
        bad.append("%s 看起来还是模板占位符，没有真的填。"
                   "（没有打印它的值）" % k)
        continue
    if v.startswith("<") and v.endswith(">") and len(v) >= 3:
        bad.append("%s 还是 <...> 形状的占位符，没有真的填。" % k)
        continue
    hit = sorted(set(ch for ch in v if ch in FORBIDDEN))
    if hit:
        bad.append("%s 含禁止字符 %s。\n"
                   "         允许的字符集：A-Z a-z 0-9 @ # %% ^ _ + - .\n"
                   "         ★ 为什么这些字符被禁：它们会在 shell 插值、"
                   "psql 命令行、\n"
                   "           PG 配置的引号里被**静默**吃掉一截，"
                   "而报错会出现在完全\n"
                   "           无关的地方。在部署时拦住，比在故障当天排查便宜。"
                   % (k, " ".join(repr(c) for c in hit)))
        continue
    if not re.match(r"^[A-Za-z0-9@#%^_+.\-]+$", v):
        # 兜底：上面的集合漏了某个可打印字符（比如全角）
        bad.append("%s 含非 ASCII 或未列出的字符。只允许 "
                   "A-Z a-z 0-9 @ # %% ^ _ + - ." % k)

# ---- ③ 地址与网卡 ----
IPV4 = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")


def ip_ok(v):
    m = IPV4.match(v or "")
    return bool(m) and all(int(g) <= 255 for g in m.groups())


a, b, vip = d.get("NODE_A_IP", ""), d.get("NODE_B_IP", ""), d.get("VIP", "")
for name, val in (("NODE_A_IP", a), ("NODE_B_IP", b), ("VIP", vip)):
    if val and not ip_ok(val):
        bad.append("%s=%s 不是合法的 IPv4 地址。" % (name, val))

if ip_ok(a) and ip_ok(b) and a == b:
    bad.append("NODE_A_IP 与 NODE_B_IP 是同一个地址 —— "
               "两台机器的地址配成了同一个。")
if ip_ok(vip):
    if vip == a or vip == b:
        bad.append("VIP 与某一台节点的地址相同。VIP 必须是**第三个**地址，"
                   "否则节点之间会互相抢答。")

nic = d.get("NIC", "")
if mode != "arbiter" and nic:
    if not os.path.isdir("/sys/class/net/%s" % nic):
        have = ""
        try:
            have = ", ".join(sorted(os.listdir("/sys/class/net")))
        except OSError:
            pass
        bad.append("NIC=%s 在本机上不存在。本机有：%s\n"
                   "         用 `ip -4 addr` 确认真实网卡名后再填。" % (nic, have))

# ---- ④ 本机身份：这台机器必须是配置里的两台之一 ----
if mode != "arbiter" and ip_ok(a) and ip_ok(b):
    out = ""
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"],
                             capture_output=True, text=True,
                             timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        pass
    mine = set(re.findall(r"inet\s+(\d+\.\d+\.\d+\.\d+)", out))
    if mine:
        have = mine & {a, b}
        if not have:
            bad.append("本机网卡上既没有 %s 也没有 %s。\n"
                       "         本机实际地址：%s\n"
                       "         ★ 最常见的原因：用的是**另一台**的模板。"
                       "两台机器的\n"
                       "           模板只差 NODE_ROLE 与各机自己的值，"
                       "拷错了不容易看出来。"
                       % (a, b, ", ".join(sorted(mine)) or "（无）"))
        elif len(have) == 2:
            bad.append("本机网卡上同时存在 %s 和 %s —— "
                       "两台机器的地址配到了同一台机器上。" % (a, b))

# ---- ⑤ 装到别处一律拒绝 ----
if mode != "arbiter":
    hid = (d.get("HA_DIR") or "").strip()
    if hid and hid != "/opt/simplified-ha":
        bad.append("HA_DIR=%s —— 本部署器只肯装到 /opt/simplified-ha。\n"
                   "         ★ 这个键是**记录**不是旋钮：改它不会把任何东西搬走，"
                   "只会让\n"
                   "           守卫的挂载点、systemd 单元的路径、"
                   "timer 的路径全部失配。" % hid)

if bad:
    print("  [!!] %s 未通过安装前检查（共 %d 条）：" % (LABEL, len(bad)))
    for i, msg in enumerate(bad, 1):
        print("       %d) %s" % (i, msg))
    print("")
    print("  ★ 这些都是**故意的**失败。它们的共同点是：")
    print("    放过去以后，系统能装完、能启动、看起来正常，")
    print("    直到某天复制断了 / Zabbix 连不上库 / 该切换时切不了，才暴露。")
    sys.exit(2)

print("  [OK] %s 通过安装前检查（必填项 / 密码字符集 / 地址与网卡 / 本机身份）"
      % LABEL)
PY
}

# ============================================================
# 文件映射
# ============================================================
# ★ 每个列表都是「源|目标」两列。install 与 manifest **共用**这些列表 ——
#   这样"装了什么"和"比对什么"不可能漂移。

node_bin_files() {
    cat <<EOF
$SRC/scripts/bin/halib.py|$HA_DIR/halib.py
$SRC/scripts/bin/ha-guard-pg.py|$HA_DIR/ha-guard-pg.py
$SRC/scripts/bin/ha-agent.py|$HA_DIR/ha-agent.py
$SRC/scripts/bin/ha-promote.py|$HA_DIR/ha-promote.py
$SRC/scripts/bin/ha-force.py|$HA_DIR/ha-force.py
$SRC/scripts/bin/ha-rejoin.py|$HA_DIR/ha-rejoin.py
$SRC/scripts/bin/ha-status.py|$HA_DIR/ha-status.py
$SRC/scripts/bin/ha-faults.py|$HA_DIR/ha-faults.py
$SRC/scripts/bin/ha-confsync.py|$HA_DIR/ha-confsync.py
EOF
}

node_unit_files() {
    # ★ 守卫是 drop-in，不是独立单元：它必须挂到 postgresql@17-main.service 上，
    #   否则 PG 启动根本不经过它。
    cat <<EOF
$SRC/scripts/systemd/postgresql@17-main-guard.conf|$SYSTEMD_DIR/postgresql@17-main.service.d/guard.conf
$SRC/scripts/systemd/zbx-ha-agent.service|$SYSTEMD_DIR/zbx-ha-agent.service
$SRC/scripts/systemd/zbx-ha-agent.timer|$SYSTEMD_DIR/zbx-ha-agent.timer
EOF
}

arbiter_bin_files() {
    cat <<EOF
$SRC/scripts/arbiter/arbiter.py|$ARBITER_DIR/arbiter.py
$SRC/scripts/arbiter/arbiter-round.py|$ARBITER_DIR/arbiter-round.py
$SRC/scripts/arbiter/arbiter-window.py|$ARBITER_DIR/arbiter-window.py
$SRC/scripts/arbiter/run-adapters.sh|$ARBITER_DIR/run-adapters.sh
$SRC/scripts/bin/ha-faults.py|$ARBITER_DIR/ha-faults.py
EOF
}

arbiter_unit_files() {
    cat <<EOF
$SRC/scripts/systemd/zbx-arbiter.service|$SYSTEMD_DIR/zbx-arbiter.service
$SRC/scripts/systemd/zbx-arbiter.timer|$SYSTEMD_DIR/zbx-arbiter.timer
$SRC/scripts/systemd/zbx-arbiter-http.service|$SYSTEMD_DIR/zbx-arbiter-http.service
EOF
}

# 按名字取一个适配器及其参数模板。适配器**不是全装** ——
# 现场有哪几路观测能力才装哪几路（§2.3），默认只装必选的 10-network.sh。
adapter_files() {
    local name="$1"
    printf '%s|%s\n' "$SRC/scripts/arbiter/adapters/$name" "$ARBITER_ADAPTER_DIR/$name"
    # 适配器的参数模板 → 落到适配器自己的配置目录（600），不挤进 arbiter.conf
    local stem="${name%.*}"
    if [ -f "$SRC/scripts/config/adapters.d/$stem.conf.template" ]; then
        printf '%s|%s\n' "$SRC/scripts/config/adapters.d/$stem.conf.template" \
            "$ARBITER_ADAPTER_CONF_DIR/$stem.conf"
    fi
}

# 每个适配器需要什么外部依赖（§2.3 的表）
adapter_deps() {
    case "$1" in
    10-network.sh)  printf 'iputils-arping|iputils-arping|arping' ;;
    20-oob-ipmi.sh) printf 'ipmitool|ipmitool|ipmitool' ;;
    90-pg-role.sh)  printf 'psql|postgresql-client-17|psql' ;;
    20-oob-esxi.py) printf 'pyVmomi|python3-pyvmomi|-' ;;
    *)              printf -- '-|-|-' ;;
    esac
}

# ============================================================
# 通用文件操作
# ============================================================

copy_file() {  # copy_file <src> <dst> <mode>
    local s="$1" d="$2" m="$3"
    if [ ! -f "$s" ]; then
        bad "源文件不存在：$s（部署包不完整？）"
        return 1
    fi
    if [ "$DRY_RUN" = yes ]; then
        printf '      [dry-run] install -m %s %s %s\n' "$m" "$s" "$d"
        return 0
    fi
    install -D -m "$m" -o root -g root "$s" "$d" || {
        bad "拷不动：$s → $d"
        return 1
    }
    return 0
}

copy_if_absent() {  # ★ 已存在就**不覆盖**（活着的机器上不能被静默改配置）
    local s="$1" d="$2" m="$3"
    if [ -e "$d" ]; then
        warn "已存在，保持不动：$d"
        return 0
    fi
    copy_file "$s" "$d" "$m"
}

write_here() {  # write_here <dst> <mode>   （内容走 stdin）
    local d="$1" m="$2"
    if [ "$DRY_RUN" = yes ]; then
        printf '      [dry-run] 写文件 %s（%s）\n' "$d" "$m"
        cat >/dev/null
        return 0
    fi
    mkdir -p -- "$(dirname -- "$d")" || return 1
    cat >"$d" || return 1
    chmod "$m" "$d" || return 1
    chown root:root "$d" 2>/dev/null || true
    return 0
}

# ============================================================
# genconf —— 生成配置骨架
# ============================================================

usage_genconf() {
    cat <<'EOF'
install.sh genconf [--out DIR] [--force]

  生成三份**值全部留空**的配置骨架：

    cluster.conf.template-primary     给机器 A（221）
    cluster.conf.template-standby     给机器 B（222）
    arbiter.conf.template             给仲裁节点

  ★ 骨架里**不含任何凭据**（连密文也没有），因为它可能要进仲裁节点的
    分发目录（644，谁都能读）。密码字段一律留空，由人在目标机器上填。

  ★ primary / standby 两份的差别只有一处：文件末尾那个盖章的 NODE_ROLE。
    它的作用是**让拷错文件这件事变得可见** —— install 会核对盖章与 --role，
    不一致就在安装那一刻拦住，而不是在演练当天表现为「该切换却没切换」。
EOF
}

cmd_genconf() {
    local out="$SRC/config" force=no
    while [ $# -gt 0 ]; do
        case "$1" in
        --out) [ $# -ge 2 ] || die "--out 后面要跟目录"; out=$2; shift 2 ;;
        --out=*) out=${1#*=}; shift ;;
        --force) force=yes; shift ;;
        -h|--help) usage_genconf; return 0 ;;
        *) die "genconf: 不认识的参数 $1" ;;
        esac
    done

    local base="$SRC/scripts/config/cluster.conf.template"
    [ -f "$base" ] || die "找不到配置模板：$base"
    [ -f "$SRC/scripts/config/arbiter.conf.template" ] || \
        die "找不到配置模板：$SRC/scripts/config/arbiter.conf.template"

    mkdir -p -- "$out" || die "建不了目录：$out"

    local role dst
    for role in primary standby; do
        dst="$out/cluster.conf.template-$role"
        if [ -e "$dst" ] && [ "$force" != yes ]; then
            warn "已存在，跳过（要覆盖加 --force）：$dst"
            continue
        fi
        # ★ 用 Python 做这件事，是为了把 CRLF 归一成 LF、去掉 BOM、
        #   并保证末尾只有一个换行 —— 这三件事直接决定
        #   "两台机器的 cluster.conf 是否逐字符一致"（§8.3）。
        "$PY" - "$base" "$role" <<'PY' | write_here "$dst" 644
import sys

src, role = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8-sig", newline="") as fh:
    text = fh.read()

# 归一：CRLF/CR → LF，去掉首尾多余空行，末尾恰好一个换行。
# ★ 这一步不是洁癖：§8.3 要求两台机器的 cluster.conf **逐字符一致**，
#   而"一个人在 Windows 上编辑过"就会让肉眼相同的两份文件字节不同。
text = text.replace("\r\n", "\n").replace("\r", "\n")
if "﻿" in text:
    text = text.replace("﻿", "")
text = text.strip("\n") + "\n"

stamp = (
    "# ==== GENCONF-ROLE-BEGIN ====\n"
    "# ★ 这份骨架属于【%s】那台机器。这一行由 genconf 盖章。\n"
    "#   install.sh 会把盖章与 --role 核对：把备机的模板拷到主机上装，\n"
    "#   会在安装那一刻被拦住，而不是在演练当天表现为"
    "「该切换却没切换」。\n"
    "#   ★ cluster.conf 里**不会**出现 NODE_ROLE —— 它必须两台逐字符一致；\n"
    "#     角色只写在 node.conf 里。\n"
    "NODE_ROLE=%s\n"
    "# ==== GENCONF-ROLE-END ====\n"
) % (role, role)

sys.stdout.write(text + "\n" + stamp)
PY
        ok "$dst"
    done

    # 仲裁节点那份：它**留在仲裁节点上**，不进分发目录（§8.2）。
    local ac="$out/arbiter.conf.template"
    if [ -e "$ac" ] && [ "$force" != yes ]; then
        warn "已存在，跳过（要覆盖加 --force）：$ac"
    else
        "$PY" - "$SRC/scripts/config/arbiter.conf.template" <<'PY' | write_here "$ac" 644
import sys

with open(sys.argv[1], encoding="utf-8-sig", newline="") as fh:
    text = fh.read()
text = text.replace("\r\n", "\n").replace("\r", "\n").replace("﻿", "")
sys.stdout.write(text.strip("\n") + "\n")
PY
        ok "$ac"
    fi

    hr
    say "骨架已生成到：$out"
    say ""
    say "★ 接下来是**人工**的两步（这两步不做，install 会拒绝执行）："
    say ""
    say "  1) 把这台机器对应的一份拷过去，然后**在这台机器上**填写："
    say "       环境值：VIP / NODE_A_IP / NODE_B_IP / NIC / PGDATA"
    say "       密码：  PG_SUPER_PWD / PG_REPL_PWD / PG_ZBX_PWD / PROBE_PWD"
    say "       仲裁：  ARBITER_URL / ARBITER_TOKEN（与仲裁节点逐字符一致）"
    say "     ★ 密码只能填在这台机器上 —— 这是「密码不离开目标机」的全部做法。"
    say ""
    say "  2) 在仲裁节点上填 arbiter.conf.template，然后跑 install.sh arbiter"
    say ""
    say "  ★ 别用记事本另存为「UTF-8 带 BOM」，也别从共享盘直接拷："
    say "    BOM 会粘在第一个键名上让那个键**静默消失**，而第一个键就是 NODE_A_IP。"
    say "    （解析器按 utf-8-sig 读，容忍它；但容忍是为了不让人在凌晨三点"
    say "      被一个看不见的字节挡住，不是为了允许它。）"
}

# ============================================================
# 拆分配置：骨架 → cluster.conf + node.conf
# ============================================================
# ★ cluster.conf 必须两台**逐字符一致**，所以：
#   · NODE_ROLE 与那对盖章标记从 cluster.conf 里**删掉**，只写进 node.conf；
#   · 顺手把 CRLF 归一成 LF、去掉 BOM、补齐末尾换行。
#   于是"install 装出来的 cluster.conf"在字节上只取决于人填的值，
#   不取决于编辑器和操作系统。
# node.conf 的正文 —— ★ 只在这一处生成（install 与"补写"共用）。
#   它和 cluster.conf 的分工是这套设计里最容易搞混的一处，所以正文里
#   把理由写全了：身份在 cluster.conf、角色在 node.conf，两者不许互相推导。
node_conf_body() {  # node_conf_body <role>
    cat <<EOF
# ============================================================
# 本机角色声明 —— 由 install.sh 生成（§5 M10）
# ============================================================
# ★ 这里只有一件事：本机【现在】是 primary 还是 standby。
#   它是**会被改写**的：接管脚本把它改成 primary，归位脚本改回 standby。
#
# ★ 本机是「哪台机器」（221 还是 222）**不在这里**，也不要从这里推导 ——
#   那来自 cluster.conf 的 NODE_A_IP / NODE_B_IP 与网卡上真实地址的比对。
#   两者混用过一次：222 接管之后 node.conf 变成 primary，脚本就以为自己是
#   221，配置校验拒绝启动 —— 一次故障切换把自己锁死。
#
# ★ 两台机器的 cluster.conf 必须逐字符一致，唯一允许的差异是 NIC；
#   而角色差异全在这个文件里 —— 这就是角色不能写进 cluster.conf 的原因。
NODE_ROLE=$1
EOF
}

write_node_conf() {  # write_node_conf <role> <dst>
    node_conf_body "$1" | write_here "$2" 600
}

split_conf() {  # split_conf <骨架> <角色> <cluster.conf> <node.conf>
    "$PY" - "$1" "$2" "$3" <<'PY'
import sys

# ★ 只解三个：node.conf 由 bash 侧（write_node_conf）写，Python 这边用不到它。
#   这里曾经写的是 `sys.argv[1:5]`（四个名字）而调用处只传了三个 ——
#   结果是 split_conf **每次**都以 ValueError 失败（退出码 2），
#   也就是 install 永远走不到"写配置"这一步。解包个数必须与传参个数一致。
src, role, cpath = sys.argv[1:4]

with open(src, encoding="utf-8-sig", newline="") as fh:
    raw = fh.read()
raw = raw.replace("\r\n", "\n").replace("\r", "\n").replace("﻿", "")

MB = "# ==== GENCONF-ROLE-BEGIN ===="
ME = "# ==== GENCONF-ROLE-END ===="
lines, out, i = raw.split("\n"), [], 0
stamped = None
while i < len(lines):
    if lines[i].strip() == MB:
        i += 1
        while i < len(lines) and lines[i].strip() != ME:
            s = lines[i].strip()
            if s.startswith("NODE_ROLE="):
                stamped = s.split("=", 1)[1].strip()
            i += 1
        i += 1  # 跳过后面的 END 标记
        continue
    out.append(lines[i])
    i += 1

cluster = "\n".join(out).strip("\n") + "\n"

# ★ 盖章与 --role 不一致 = 这台机器上放的是**另一台**的模板。
#   放过去也不报错，只会在演练当天表现为"该切换却没切换"。
if stamped and stamped != role:
    sys.stderr.write(
        "  [!!] 这份模板盖的是 %s 的章，但你要按 %s 安装。\n"
        "       两台机器的模板只差这个章与各机自己的值，拷错了不容易看出来 ——\n"
        "       所以这里直接拒绝，而不是装上去等演练当天发现。\n"
        % (stamped, role))
    sys.exit(2)

with open(cpath, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(cluster)
PY
    # ★ node.conf 由 bash 侧写（正文只有 node_conf_body 一处）。
    #   分成两边写是为了让"角色"这件事只有一个来源 —— 四处各写一遍
    #   迟早会漂移，而漂移的表现是"演练当天该切换却没切换"。
    [ $? -eq 0 ] || return 2
    write_node_conf "$2" "$4"
}

# ============================================================
# install —— 部署节点
# ============================================================

usage_install() {
    cat <<'EOF'
install.sh install --role primary|standby [--conf-file FILE] [--dry-run]

  在这台节点上：放脚本 → 写配置 → 建状态目录 → 装守卫与定时器。

  --conf-file   填好的配置骨架（默认按顺序找：
                  $HA_DIR/cluster.conf.template-<role>
                  <部署包>/cluster.conf.template-<role>
                  <部署包>/scripts/config/cluster.conf.template
                最后那个是**没盖过章**的总模板，第一次跑时会被拷到
                $HA_DIR/cluster.conf.template-<role> 等你填。）

  ★ 已存在的 cluster.conf / node.conf **不会被覆盖** ——
    它们可能正是一台活着的机器上的配置。
EOF
}

cmd_install() {
    local role="" conf_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --role) [ $# -ge 2 ] || die "--role 后面要跟 primary 或 standby"; role=$2; shift 2 ;;
        --role=*) role=${1#*=}; shift ;;
        --conf-file) [ $# -ge 2 ] || die "--conf-file 后面要跟文件"; conf_file=$2; shift 2 ;;
        --conf-file=*) conf_file=${1#*=}; shift ;;
        --dry-run) DRY_RUN=yes; shift ;;
        -h|--help) usage_install; return 0 ;;
        *) die "install: 不认识的参数 $1" ;;
        esac
    done

    case "$role" in
    primary|standby) : ;;
    "") die "必须指定 --role primary 或 --role standby。" ;;
    *) die "--role 只能是 primary 或 standby（收到 $role）。" ;;
    esac

    # ★ 干跑也必须过发行版与闸门 —— 否则干跑会给出一个假的"没问题"。
    require_distro node
    need_root

    title "① 找到配置骨架"
    local tmpl="$HA_DIR/cluster.conf.template-$role"
    if [ -n "$conf_file" ]; then
        tmpl=$conf_file
        info "用 --conf-file 指定的：$tmpl"
    elif [ -f "$tmpl" ]; then
        info "用本机已有的骨架：$tmpl"
    elif [ -f "$SRC/cluster.conf.template-$role" ]; then
        tmpl="$SRC/cluster.conf.template-$role"
        info "用部署包里的骨架：$tmpl"
    else
        # 第一次跑：把总模板落成这台机器的那一份，然后停下来等人填。
        tmpl="$HA_DIR/cluster.conf.template-$role"
        warn "本机还没有 $role 的骨架 —— 现在落一份，等你填。"
        run mkdir -p -- "$HA_DIR"
        if [ "$DRY_RUN" = yes ]; then
            printf '      [dry-run] 落骨架 %s\n' "$tmpl"
        else
            "$PY" - "$SRC/scripts/config/cluster.conf.template" "$role" "$tmpl" <<'PY' || die "落骨架失败"
import sys
src, role, dst = sys.argv[1:4]
with open(src, encoding="utf-8-sig", newline="") as fh:
    text = fh.read()
text = text.replace("\r\n", "\n").replace("\r", "\n").replace("﻿", "")
stamp = ("# ==== GENCONF-ROLE-BEGIN ====\n"
         "# ★ 这份骨架属于【%s】那台机器。\n"
         "NODE_ROLE=%s\n"
         "# ==== GENCONF-ROLE-END ====\n") % (role, role)
with open(dst, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text.strip("\n") + "\n\n" + stamp)
PY
            chmod 600 -- "$tmpl"
            chown root:root -- "$tmpl" 2>/dev/null || true
        fi
        hr
        say "现在去填它 —— ★ **在这台机器上**填，不要把文件拷出去填："
        say "    $tmpl"
        say ""
        say "  必填：VIP / NODE_A_IP / NODE_B_IP / NIC / PGDATA /"
        say "        PG_SUPER_PWD / PG_REPL_PWD / PG_ZBX_PWD / PROBE_PWD /"
        say "        ARBITER_URL / ARBITER_TOKEN"
        say "  然后重新跑：sudo $PROG install --role $role"
        say ""
        say "  ★ 为什么非要在本机填：密码不离开目标机器，也不进版本库。"
        say "    本文件填完是 600，除 root 外无人可读。"
        return 2
    fi

    title "② 安装前检查（空密码闸门）"
    config_gate "$tmpl" node || return $?

    title "③ 写配置"
    # ★ 先写 cluster.conf 再写 node.conf；两者都只在不存在时写。
    if [ -e "$HA_DIR/cluster.conf" ]; then
        warn "已存在，保持不动：$HA_DIR/cluster.conf"
        # 已存在的配置**不能**被静默盖掉，但两个文件必须对得上。
        # ★ 注意：NODE_ROLE 只应出现在 node.conf 里。cluster.conf 两台逐字符
        #   一致，多一行角色就破坏了这个前提 —— 所以这里读的是 node.conf。
        if [ -e "$HA_DIR/node.conf" ]; then
            nconf_load "$HA_DIR/node.conf"
            local cur; cur=$(nconf_get NODE_ROLE)
            if [ "$cur" = "$role" ]; then
                ok "node.conf 的 NODE_ROLE=$cur 与 --role 一致"
            else
                die "已存在的 node.conf 里 NODE_ROLE=${cur:-（空）}，与 --role $role 不一致。
        ★ 这一步是在拦「在一台活着的机器上按另一个角色重装」。
          确实要改角色，就改 node.conf 的 NODE_ROLE（值守会在 30 秒内按新角色
          纠正），或者用 ha-rejoin.py 走归位流程 —— 不要靠重装来改角色。"
            fi
        else
            warn "有 cluster.conf 但没有 node.conf —— 按 --role $role 补写一个"
            write_node_conf "$role" "$HA_DIR/node.conf" || die "写 node.conf 失败"
            ok "node.conf（600，NODE_ROLE=$role）"
        fi
    else
        # ★ --dry-run 必须**什么都不写**（N10）。这里曾经只保护了 chmod/chown，
        #   而 split_conf 照样把 cluster.conf 落盘 —— 含口令、按 umask 是 644；
        #   真跑时看到"已存在"就保持不动，那个 644 会一直留到 check 报出来。
        #   ★ 但也**不能**因此跳过 split_conf：它还负责核对角色盖章，
        #   盖错章的骨架必须当场 exit 2 —— 那是本套件的头号陷阱。
        #   所以让 cluster.conf 写去 /dev/null，校验照跑、文件不落。
        if [ "$DRY_RUN" = yes ]; then
            split_conf "$tmpl" "$role" /dev/null "$HA_DIR/node.conf" || {
                bad "配置拆分失败（见上面的原因）。"
                return 2
            }
            printf '      [dry-run] 写 %s（600）\n' "$HA_DIR/cluster.conf"
        else
            split_conf "$tmpl" "$role" "$HA_DIR/cluster.conf" "$HA_DIR/node.conf" || {
                bad "配置拆分失败（见上面的原因）。"
                return 2
            }
            chmod 600 -- "$HA_DIR/cluster.conf" "$HA_DIR/node.conf"
            chown root:root -- "$HA_DIR/cluster.conf" "$HA_DIR/node.conf" 2>/dev/null || true
            ok "cluster.conf（600，两台逐字符一致的那一份）"
            ok "node.conf（600，只含 NODE_ROLE=$role）"
        fi
    fi

    title "④ 放脚本"
    local pair s d n=0
    while IFS='|' read -r s d; do
        [ -n "$s" ] || continue
        copy_file "$s" "$d" 755 || return 1
        n=$((n + 1))
    done < <(node_bin_files)
    ok "$n 个脚本 → $HA_DIR"

    title "⑤ 建状态目录"
    # ★ 700：这个目录里躺着 superseded 标记、令牌、force 留痕、
    #   还有值守的日志。它们既不是秘密，也不该被别人改写 ——
    #   superseded 标记被改掉就等于关掉一道防线。
    run install -d -m 700 -o root -g root "$NODE_STATE" && ok "$NODE_STATE（700）"

    title "⑥ 装 systemd 单元"
    while IFS='|' read -r s d; do
        [ -n "$s" ] || continue
        copy_file "$s" "$d" 644 || return 1
    done < <(node_unit_files)
    run systemctl daemon-reload && ok "systemd 已重载"
    ok "守卫已挂到 postgresql@17-main.service（ExecStartPre）"

    # ★ 日志轮转：/var/lib/zbx-ha/*.log 是 append-only 的（审计与守卫留痕），
    #   不轮转的话几个月后磁盘满会变成一个新的故障源（03 §5.4、§11 第 7 条）。
    # ★ 用 copy_if_absent（已存在就**不动**）：现场要调份数/尺寸，就在这台
    #   机器上改 /etc/logrotate.d/zbx-ha，重装不会把它覆盖回去。
    # ★ 它**不进 manifest** —— manifest 比的是脚本与单元，这个是可以被现场
    #   合法改动的策略文件，比对它只会天天报"不一致"。
    copy_if_absent "$SRC/scripts/config/logrotate.d-zbx-ha" \
        /etc/logrotate.d/zbx-ha 644 || return 1
    ok "日志轮转 → /etc/logrotate.d/zbx-ha"

    # ★ 配置同步的清单（ha-confsync.py 读它）。与上面同一条理由：
    #   现场要加自定义监控目录就得改它，所以**不进 manifest**、已存在就不动。
    copy_if_absent "$SRC/scripts/config/zbx-sync.list" \
        "$HA_DIR/zbx-sync.list" 644 || return 1
    ok "配置同步清单 → $HA_DIR/zbx-sync.list"
    ok "值守单元与定时器已就位"

    title "⑦ 起守卫的验证"
    # ★ 这里**不启动 PG**，只让守卫自己跑一次 —— 这是唯一能在不影响
    #   运行中服务的前提下，验证"守卫真的会拦"的时机。
    if [ "$DRY_RUN" = yes ]; then
        printf '      [dry-run] %s %s/ha-guard-pg.py\n' "$PY" "$HA_DIR"
    else
        if "$PY" "$HA_DIR/ha-guard-pg.py" --explain >/dev/null 2>&1; then
            ok "守卫自测通过（它在当前局面下会放行 —— 属正常）"
        else
            local rc=$?
            case "$rc" in
            1) ok "守卫自测：当前局面下它会**拒绝**启动 —— 这是正常的，
                  说明它真的在工作（VIP 有人在答 / 没有仲裁许可 / 有标记）。
                  装完的这一刻它拒绝，正是它该做的事。" ;;
            2) warn "守卫自测返回 2（配置类错误）。先看它的输出再往下走：
                  sudo $PY $HA_DIR/ha-guard-pg.py --explain" ;;
            3) warn "守卫自测返回 3（依赖不可达：仲裁节点或者 arping 有问题）。" ;;
            *) warn "守卫自测返回 $rc，非预期。看它的输出：sudo $PY $HA_DIR/ha-guard-pg.py --explain" ;;
            esac
        fi
    fi

    title "⑧ 起定时器"
    run systemctl enable --now zbx-ha-agent.timer && ok "zbx-ha-agent.timer 已启用"
    run systemctl start postgresql@17-main.service >/dev/null 2>&1 || true

    hr
    # ★ 以「文件在不在」为条件，而不是以 $DRY_RUN 为条件：
    #   在一台已有真配置的机器上跑 --dry-run，这里应当报**真话**。
    if [ -r "$HA_DIR/cluster.conf" ]; then
        conf_load "$HA_DIR/cluster.conf"
        local ap aj
        ap=$(conf_get AUTO_PROMOTE)
        aj=$(conf_get AUTO_REJOIN)
        say "节点部署完成。"
        say ""
        say "  AUTO_PROMOTE = ${ap:-（未设，代码缺省 yes）}"
        say "  AUTO_REJOIN  = ${aj:-（未设，代码缺省 no）}"
        say ""
        # ★ 三分支，与 check ⑩ 一致：**「没写」不等于「no」**。
        #   代码缺省是 yes（halib.getbool），把空值当 no 会报出一句假的「已抑制」——
        #   而在"该切换却没切换"这件事上，一句假的"已抑制"正是最贵的误导。
        if [ "$ap" = "no" ]; then
            ok "AUTO_PROMOTE=no —— 自动接管当前是**抑制**状态。"
        elif [ "$ap" = "yes" ]; then
            warn "★ AUTO_PROMOTE 不是 no —— 自动接管是**开启**的。"
            say "     交付与演练期间应当是 no；演练二（自动接管）才需要 yes。"
            say "     ★ 这是全套设计里最容易设错、而且设错时**表现为失败而不是报错**的一项："
            say "       no 的时候，演练会看起来像「该接管却没接管」。"
        else
            bad "AUTO_PROMOTE 的值是 ${ap:-（空）} —— 认不出来；代码按缺省 **yes** 处理。"
            say "     也就是说这一份**不是**抑制状态。显式写上 no 或 yes。"
        fi
    else
        warn "[dry-run] 没有写 $HA_DIR/cluster.conf —— AUTO_PROMOTE / AUTO_REJOIN 这次**没有验**。"
        say "     ★ 「自动接管被抑制」这句此刻并不成立：文件不存在，代码缺省是 yes。"
    fi
    say ""
    say "  下一步："
    say "    sudo $PROG check                 # 自检（含真跑一次 arping）"
    say "    sudo $PROG venv                  # 需要第三方依赖时才用（见 --help）"
    say "    在**另一台**节点上做同样的部署，然后用 check 核对两份配置一致"
}

# ============================================================
# venv
# ============================================================

usage_venv() {
    cat <<'EOF'
install.sh venv [--with-esxi]

  ★ 节点侧**不需要 venv**：守卫、值守、force、rejoin、status 全部只用
    标准库。多一个虚拟环境就多一个「起不来」的理由，而守卫在 PG 的启动
    路径上 —— 它起不来，数据库就起不来。

  仲裁节点也只有一种情况需要 venv：适配器目录里放了 20-oob-esxi.py
  （pyVmomi）。只配网络探测时**一个第三方依赖都不需要**（N8）。
EOF
}

cmd_venv() {
    local with_esxi=no
    while [ $# -gt 0 ]; do
        case "$1" in
        --with-esxi) with_esxi=yes; shift ;;
        --dry-run) DRY_RUN=yes; shift ;;
        -h|--help) usage_venv; return 0 ;;
        *) die "venv: 不认识的参数 $1" ;;
        esac
    done
    need_root

    if [ -d "$ARBITER_DIR" ]; then
        title "仲裁节点的 venv"
        if [ "$with_esxi" != yes ]; then
            say "  --with-esxi 没给。如果适配器目录里有 20-oob-esxi.py，"
            say "  它的观测会在故障当天返回「不可用」 —— 那时你会以为是对端的问题。"
            say "  确认不用就跳过；要用就重跑：sudo $PROG venv --with-esxi"
            return 0
        fi
        if ! "$PY" -c 'import pyVmomi' 2>/dev/null; then
            run apt-get install -y python3-pyvmomi ||
                die "装 python3-pyvmomi 失败。离线环境请把 deb 与依赖树一起带进介质（U5）。"
        fi
        ok "pyVmomi 可用（适配器 20-oob-esxi.py 能跑）"
        return 0
    fi

    say "本机不是仲裁节点（没有 $ARBITER_DIR）。"
    ok "节点侧不需要 venv —— 全部脚本只用标准库。什么都不用做。"
}

# ============================================================
# arbiter —— 部署仲裁节点
# ============================================================

usage_arbiter() {
    cat <<'EOF'
install.sh arbiter [--adapters "10-network.sh 20-oob-ipmi.sh"] [--install-deps] [--dry-run]

  部署仲裁节点：HTTP 服务 + 观测周期 + 分发目录 + 适配器目录 + 适配器依赖。

  --adapters      要装哪几路观测，默认只装必选的 10-network.sh。
                  可选：20-oob-esxi.py 20-oob-ipmi.sh 30-snmp-switch.py 90-pg-role.sh
  --install-deps  用 apt 补齐适配器要的系统包（离线环境请预先把 deb 带进介质）

  ★ 仲裁节点永久只读：它不启动、不停止、不重启任何东西，也不接受任何
    「执行指令」。适配器读的是电源**状态**，不是电源**开关**。
EOF
}

cmd_arbiter() {
    local adapters="10-network.sh" install_deps=no
    while [ $# -gt 0 ]; do
        case "$1" in
        --adapters) [ $# -ge 2 ] || die "--adapters 后面要跟适配器文件名"; adapters=$2; shift 2 ;;
        --adapters=*) adapters=${1#*=}; shift ;;
        --install-deps) install_deps=yes; shift ;;
        --dry-run) DRY_RUN=yes; shift ;;
        -h|--help) usage_arbiter; return 0 ;;
        *) die "arbiter: 不认识的参数 $1" ;;
        esac
    done

    require_distro arbiter
    need_root

    title "① 建目录与专用用户"
    run install -d -m 755 -o root -g root "$ARBITER_DIR" && ok "$ARBITER_DIR"
    run install -d -m 755 -o root -g root "$ARBITER_ADAPTER_DIR" && ok "$ARBITER_ADAPTER_DIR"
    run install -d -m 700 -o root -g root "$ARBITER_ADAPTER_CONF_DIR" && ok "$ARBITER_ADAPTER_CONF_DIR（700：里面是 SNMP/IPMI 凭据）"
    run install -d -m 755 -o root -g root "$DIST_DIR_DEFAULT" && ok "$DIST_DIR_DEFAULT（分发目录：**只放工具集与无密码模板**）"

    # ★ HTTP 服务以非 root 运行（zbx-arbiter-http.service 的 User=zbxarb）。
    #   它只读状态文件，不需要任何特权；而**对外监听的进程不该是 root**。
    if ! id zbxarb >/dev/null 2>&1; then
        run useradd --system --no-create-home --shell /usr/sbin/nologin zbxarb &&
            ok "建了系统用户 zbxarb（无登录 shell）"
    else
        ok "系统用户 zbxarb 已存在"
    fi

    # ★ 状态目录**两个身份都要写**：
    #     root   写 adapters.json（观测周期，zbx-arbiter.service 以 root 跑）
    #     zbxarb 写 reports.json（POST /report，由 HTTP 服务自己落盘）
    #   所以是 770 而不是 750 —— 750 只给组 r-x，zbxarb 建不出
    #   reports.json.tmp，/report 会 PermissionError，而现场看到的是
    #   "Remote end closed connection without response"，像网络问题。
    #   ★ 三个文件各由一个身份写，不存在跨用户覆盖，所以不需要 setgid。
    run install -d -m 770 -o root -g zbxarb "$ARBITER_STATE" && ok "$ARBITER_STATE（root:zbxarb 770 —— 两边都要写）"

    title "② 放脚本"
    local pair s d n=0
    while IFS='|' read -r s d; do
        [ -n "$s" ] || continue
        copy_file "$s" "$d" 755 || return 1
        n=$((n + 1))
    done < <(arbiter_bin_files)
    ok "$n 个脚本 → $ARBITER_DIR"

    title "③ 装适配器"
    local a found=no
    for a in $adapters; do
        if [ ! -f "$SRC/scripts/arbiter/adapters/$a" ]; then
            bad "没有这个适配器：$a（可选：10-network.sh 20-oob-esxi.py 20-oob-ipmi.sh 30-snmp-switch.py 90-pg-role.sh）"
            return 2
        fi
    done
    for a in $adapters; do
        while IFS='|' read -r s d; do
            [ -n "$s" ] || continue
            case "$d" in
            *.conf) copy_if_absent "$s" "$d" 600 ;;
            *)      copy_file "$s" "$d" 755 ;;
            esac
        done < <(adapter_files "$a")
        ok "$a"
        [ "$a" = "10-network.sh" ] && found=yes
    done
    if [ "$found" != yes ]; then
        warn "★ 适配器目录里没有 10-network.sh —— 它是**必选**的。"
        warn "  没有它，判据①（对端在不在服务）只剩带外与 SNMP 两路。"
    fi

    title "④ 适配器依赖"
    local dep pkg probe
    for a in $adapters; do
        dep=$(adapter_deps "$a")
        pkg=${dep#*|}; pkg=${pkg%%|*}
        probe=${dep##*|}
        if [ "$probe" = "-" ]; then
            info "$a：无系统包依赖"
            continue
        fi
        if command -v "$probe" >/dev/null 2>&1; then
            ok "$a：$probe 在（$pkg）"
        elif [ "$install_deps" = yes ]; then
            run apt-get install -y "$pkg" || {
                bad "装 $pkg 失败 —— 它没装，$a 在故障当天会返回「不可用」。"
                return 1
            }
            ok "$a：已装 $pkg"
        else
            bad "$a 需要 $pkg（找不到 $probe）—— 加 --install-deps，或先手工装上。"
            warn "  ★ 缺依赖不会让 check 立刻失败，但会让那一路观测在故障当天"
            warn "    返回「不可用（rc=2）」—— 那不是「对端不在服务」，是「我们自己瞎了」。"
        fi
    done
    # ★ arping 装错包是本方案的头号陷阱（U3）：/usr/sbin/arping 与
    #   /usr/bin/arping 是两个不同的包，而 systemd 的 PATH 里 /usr/sbin 在前。
    if [ -x /usr/sbin/arping ] && [ ! -x /usr/bin/arping ]; then
        warn "本机只有 /usr/sbin/arping（Habets 版，不支持 -D）—— 它**不是**要的那个。"
        warn "  装：apt install iputils-arping   → /usr/bin/arping"
    fi

    title "⑤ 装 systemd 单元"
    while IFS='|' read -r s d; do
        [ -n "$s" ] || continue
        copy_file "$s" "$d" 644 || return 1
    done < <(arbiter_unit_files)
    run systemctl daemon-reload && ok "systemd 已重载"

    # ★ 日志轮转：/var/lib/zbx-arbiter/*.log（维护窗口的开与关，append-only）。
    #   与节点装的是**同一份**配置 —— 里面两段，各自 missingok，
    #   所以"本机只有其中一个目录"不会报错。
    #   已存在就不覆盖（现场可改），理由同节点侧。
    copy_if_absent "$SRC/scripts/config/logrotate.d-zbx-ha" \
        /etc/logrotate.d/zbx-ha 644 || return 1
    ok "日志轮转 → /etc/logrotate.d/zbx-ha"
    title "⑥ 配置"
    if [ ! -e "$ARBITER_CONF" ]; then
        warn "$ARBITER_CONF 不存在 —— 现在落一份空骨架，等你填。"
        # ★ 落成最终文件名（而不是 .template）：它**只在这台机器上**存在、
        #   只被这个进程读，没必要多一个中间名字。闸门会挡住"没填就启用"。
        copy_file "$SRC/scripts/config/arbiter.conf.template" "$ARBITER_CONF" 600
        [ "$DRY_RUN" = yes ] || chmod 600 -- "$ARBITER_CONF"
    fi

    if config_gate "$ARBITER_CONF" arbiter; then
        ok "配置通过闸门"
        run systemctl enable --now zbx-arbiter.timer && ok "zbx-arbiter.timer 已启用（每 30 秒一轮观测）"
        run systemctl enable --now zbx-arbiter-http.service && ok "zbx-arbiter-http.service 已启用（只读 HTTP，非 root）"
        say ""
        say "  验证："
        say "    curl -s http://127.0.0.1:8080/health"
        say "    curl -s http://127.0.0.1:8080/state | head -40"
        say "    ls -l $ARBITER_STATE/                # 一轮之后应有 adapters.json"
    else
        hr
        bad "配置没通过闸门 —— **服务没有启用**（这是有意的）。"
        say ""
        say "现在填它（★ 就在这台机器上填，不要拷出去）："
        say "    $ARBITER_CONF"
        say ""
        say "  必填：NODE_A_IP / NODE_B_IP / VIP / ARBITER_TOKEN /"
        say "        SELFCHECK_TARGETS / ARBITER_ALLOW_FROM"
        say ""
        say "  ★ SELFCHECK_TARGETS 里必须有**网关或交换机管理地址**："
        say "    如果仲裁节点自己的网断了，它跑出来的每一个结论都是"
        say "    「对端不在服务」 —— 而它其实只是瞎了。"
        say "  ★ ARBITER_ALLOW_FROM 里**必须有 VIP**：Zabbix 从 VIP 那一侧"
        say "    访问仲裁节点，漏了它表现为「监控项没数据」，你会先怀疑网络。"
        say ""
        say "填完再跑一次：sudo $PROG arbiter"
        return 2
    fi
}

# ============================================================
# check —— 自检
# ============================================================

usage_check() {
    cat <<'EOF'
install.sh check [--role node|arbiter] [--target IP] [--dry-run]

  节点侧检查：
    配置可读性与权限 · 必填项与密码字符集 · 空密码闸门
    状态目录权限 · 令牌文件权限
    本地依赖（iputils-arping / psql / systemd 单元）
    守卫自测（真跑一次，含 arping）
    仲裁节点可达性 · /report 是否成功
    ★ 三份配置的 VIP 一致性
    AUTO_PROMOTE 当前值（★ 显著提示）

  仲裁节点侧检查：
    发行版（必须 Ubuntu 22.04）· 配置闸门 · 目录与权限
    观测是否在跑 · 自检闸是否通过
    ★ 适配器**逐个真跑验证**（含类别判定：判据型 / 否决型）
    分发目录里**是否混进了凭据**

  --target  真跑适配器时把哪个 IP 当作「对端」，默认取 NODE_A_IP。

  退出码：0 全通过 / 1 有失败项 / 2 配置错误 / 3 仲裁节点不可达
EOF
}

# 一次 HTTP GET，打印 body。不可达时返回非 0（供 check 判 3）。
http_get() {  # http_get <url>
    "$PY" - "$1" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=10) as r:
        sys.stdout.write(r.read().decode("utf-8", "replace"))
except Exception as e:
    sys.stderr.write("%s\n" % e)
    sys.exit(1)
PY
}

# ---- 节点侧检查 ----
check_node() {
    local target="$1" fail=0 unreachable=0

    title "① 配置"
    local c="$HA_DIR/cluster.conf" n="$HA_DIR/node.conf"
    if [ ! -e "$c" ]; then
        bad "没有 $c —— 先跑 install.sh install --role primary|standby"
        return 2
    fi
    ok "cluster.conf 存在"
    if [ "$DRY_RUN" != yes ]; then
        local m
        m=$(stat -c '%a' "$c" 2>/dev/null || echo "?")
        if [ "$m" = "600" ]; then ok "cluster.conf 权限 600"; else
            bad "cluster.conf 权限是 $m，应当是 600（它含数据库口令）"; fail=1
        fi
    fi
    if [ -e "$n" ]; then
        ok "node.conf 存在"
        if [ "$DRY_RUN" != yes ]; then
            local mn; mn=$(stat -c '%a' "$n" 2>/dev/null || echo "?")
            [ "$mn" = "600" ] && ok "node.conf 权限 600" || { bad "node.conf 权限是 $mn，应当是 600"; fail=1; }
        fi
    else
        bad "没有 $n —— 没有它脚本认不出自己的角色"; fail=1
    fi
    # ★ cluster.conf 里**不该**有 NODE_ROLE（两台必须逐字符一致），
    #   角色只看 node.conf。所以这里读两份文件、用两个前缀，互不覆盖。
    conf_load "$c"
    if grep -qE '^[[:space:]]*NODE_ROLE[[:space:]]*=' "$c" 2>/dev/null; then
        warn "★ cluster.conf 里有 NODE_ROLE —— 角色只应写在 node.conf 里。"
        warn "  cluster.conf 必须两台逐字符一致，多一行角色就破坏了这个前提，"
        warn "  而且**只改一台**正是本方案最容易踩的坑。"
        fail=1
    fi
    if [ -e "$n" ]; then
        nconf_load "$n"
        local role; role=$(nconf_get NODE_ROLE)
        case "$role" in
        primary|standby) ok "node.conf 的 NODE_ROLE=$role" ;;
        "") bad "node.conf 里没有 NODE_ROLE —— 脚本会拒绝启动（halib 会校验）"; fail=1 ;;
        *)  bad "node.conf 的 NODE_ROLE=$role 非法（只能是 primary 或 standby）"; fail=1 ;;
        esac
    fi

    title "② 空密码闸门"
    config_gate "$c" node || fail=1

    title "③ 状态目录与令牌"
    if [ -d "$NODE_STATE" ]; then
        local ms; ms=$(stat -c '%a' "$NODE_STATE" 2>/dev/null || echo "?")
        [ "$ms" = "700" ] && ok "$NODE_STATE 权限 700" || { warn "$NODE_STATE 权限是 $ms（期望 700）"; fail=1; }
    else
        bad "没有 $NODE_STATE"; fail=1
    fi
    local tok="$NODE_STATE/force-primary.token"
    if [ -e "$tok" ]; then
        local mt; mt=$(stat -c '%a' "$tok" 2>/dev/null || echo "?")
        if [ "$mt" = "600" ]; then
            warn "★ 强制启动令牌**存在**（$tok，600）—— 它还没被用掉。"
            warn "  看一眼是谁写的、还剩多久：sudo $HA_DIR/ha-status.py"
            warn "  ★ 令牌只该在人工故障处置时短暂存在；用完即删（S11）。"
        else
            bad "令牌文件权限是 $mt，应当是 600 —— 它能让 PG 跳过仲裁启动"; fail=1
        fi
    else
        ok "没有强制启动令牌（正常）"
    fi

    title "④ 本地依赖"
    # ★ arping 是本方案的头号陷阱（U3）：`arping` 是**两个包**，
    #   iputils-arping → /usr/bin/arping（要这个，支持 -D）
    #   arping         → /usr/sbin/arping（Habets 版，-D 语义不同）
    #   而 systemd 的 PATH 里 /usr/sbin 在前 —— 装错的那个永远赢，
    #   表现是"数据库永远起不来"。
    local arp="" cand cfg_arp
    cfg_arp=$(conf_get ARPING_BIN)
    if [ -n "$cfg_arp" ]; then
        [ -x "$cfg_arp" ] && arp=$cfg_arp || {
            bad "cluster.conf 里的 ARPING_BIN=$cfg_arp 不可执行"; fail=1
        }
    else
        for cand in /usr/bin/arping /usr/sbin/arping; do
            [ -x "$cand" ] && { arp=$cand; break; }
        done
    fi
    if [ -n "$arp" ]; then
        case "$arp" in
        /usr/bin/arping)  ok "arping：$arp（iputils 版 ★ 要的就是这个）" ;;
        /usr/sbin/arping) bad "arping：$arp（Habets 版，**不支持 -D**）—— 装 iputils-arping"; fail=1 ;;
        *)                warn "arping：$arp（不在两个已知路径上，自己确认它是 iputils 版）" ;;
        esac
        info "  $("$arp" -V 2>&1 | head -1 || true)"
    else
        bad "没找到任何 arping —— 守卫会因「判据不可用」永远拒绝启动（U3）"; fail=1
    fi
    if [ -x "$(conf_get PGBIN)/psql" ]; then
        ok "psql：$(conf_get PGBIN)/psql"
    else
        warn "找不到 $(conf_get PGBIN)/psql —— PGBIN 可能填错了（Debian 系的 PG 二进制不在 /usr/pgsql-17/bin）"
    fi
    local pgd; pgd=$(conf_get PGDATA)
    if [ -d "$pgd" ]; then
        ok "PGDATA 存在：$pgd"
        [ -e "$pgd/PG_VERSION" ] && ok "  $pgd/PG_VERSION 在" || warn "  $pgd/PG_VERSION 不在 —— 这不像一个数据目录"
        # ★ standby.signal 在**数据目录里**，而 PG 配置不在 —— 这两件事
        #   在 Debian 系里是分开的，混淆它正是 U4 那类静默失败的来源。
        if [ -e "$pgd/standby.signal" ]; then
            info "  有 standby.signal（$pgd/standby.signal）"
        else
            info "  没有 standby.signal"
        fi
    else
        bad "PGDATA 不存在：$pgd"; fail=1
    fi

    title "⑤ systemd 单元"
    # ★ postgresql@17-main.service **不能**用 systemctl 判：
    #   它是 postgresql-common 的 generator 运行时生成的实例单元，磁盘上没有
    #   这个单元文件 —— `systemctl list-unit-files` 找不到它，会误报"没加载"；
    #   而 `systemctl cat` 会**回退到 postgresql@.service 模板**，在"集群根本
    #   没注册"时照样成功（再加 install.sh 自己写的 drop-in，cat 永远有输出）。
    #   两个探针在两种状态下给出同一个答案 ⇒ 判"注册了没有"只能问 pg_lsclusters。
    local pgl
    pgl=$(pg_lsclusters 2>/dev/null | awk 'NR>1 && $1=="17" && $2=="main" {print $4}')
    # ★ 不要用 pg_lsclusters -h —— 那里的 -h 是 --no-header，不是 help。
    if [ -n "$pgl" ]; then
        ok "PG 集群 17/main 已注册（状态 $pgl）"
    else
        bad "postgresql-common 里没有 17/main 集群 —— PG 起不来"
        say "      pg_lsclusters 里应当有一行以 17  main 开头；没有就说明集群"
        say "      没建或没注册（与本次 check 无关，先按安装文档把它建出来）。"
        say "      ★ 别改用 systemctl 判这一项：集群没注册时 systemctl cat 也会成功。"
        fail=1
    fi
    # ★★ 集群注册了、也在跑，**不等于对端连得上**。
    #    PG 的出厂缺省是 listen_addresses = 'localhost'（Ubuntu 的
    #    postgresql.conf 里那一行是注释掉的），所以只有 127.0.0.1 在听。
    #    对端与仲裁节点会在**认证之前**就收到 Connection refused，
    #    而那个症状看起来像"密码不对"或"网络不通"，会把排查带偏很远。
    #    ★ 这一条**并进 ⑤**，不新增项 —— 节点侧 check 在文档里是"十项"。
    if [ "$pgl" = online ]; then
        local na nb laddrs lgot h ss_ok=no
        na=$(conf_get NODE_A_IP); nb=$(conf_get NODE_B_IP)
        laddrs=""
        if command -v ss >/dev/null 2>&1; then
            ss_ok=yes
            # ★ 取 Local Address:Port 那一列再去掉端口，按**宿主部分**比对。
            #   不要子串 grep：ss 在部分版本把 0.0.0.0 打成 *，子串会漏。
            laddrs=$(ss -lnt 2>/dev/null | awk '$4 ~ /:5432$/ {sub(/:5432$/, "", $4); print $4}')
        fi
        if [ "$ss_ok" = no ]; then
            warn "没有 ss，查不了 PG 在听哪个地址 —— **这一条没验**"
        elif [ -z "$laddrs" ]; then
            bad "5432 上没有在监听 —— PG 没起来，或端口不是 5432"; fail=1
        else
            lgot=no
            for h in $laddrs; do
                case "$h" in
                0.0.0.0|'*'|"$na"|"$nb") lgot=yes ;;
                esac
            done
            if [ "$lgot" = yes ]; then
                ok "PG 在监听对端可达的地址（5432）"
            else
                bad "PG 只监听 $laddrs —— 对端与仲裁节点都会收到 Connection refused"
                say "      让 PG 也听节点地址：往 /etc/postgresql/17/main/conf.d/99-ha.conf 加"
                say "        listen_addresses = '*'"
                say "      两台都要改，改完 systemctl restart postgresql@17-main.service"
                fail=1
            fi
        fi
    else
        info "PG 集群状态是 ${pgl:-没查到}，跳过监听地址检查"
    fi
    local u
    for u in zbx-ha-agent.service zbx-ha-agent.timer; do
        if systemctl cat "$u" >/dev/null 2>&1; then
            ok "$u 已加载"
        else
            bad "$u 没加载 —— 跑 install.sh install 或 systemctl daemon-reload"; fail=1
        fi
    done
    if systemctl cat postgresql@17-main.service 2>/dev/null | grep -q 'ha-guard-pg.py'; then
        ok "守卫已挂在 postgresql@17-main.service 的 ExecStartPre 上"
    else
        bad "守卫**没有**挂上 ExecStartPre —— PG 启动会绕过它"; fail=1
    fi
    if systemctl is-enabled zbx-ha-agent.timer >/dev/null 2>&1; then
        ok "zbx-ha-agent.timer 已启用"
    else
        bad "zbx-ha-agent.timer 没启用 —— 值守不会跑"; fail=1
    fi

    title "⑥ 守卫自测（真跑一次，含 arping）"
    if [ "$DRY_RUN" = yes ]; then
        printf '      [dry-run] %s %s/ha-guard-pg.py --explain\n' "$PY" "$HA_DIR"
    else
        local out rc
        out=$("$PY" "$HA_DIR/ha-guard-pg.py" --explain 2>&1)
        rc=$?
        case "$rc" in
        0) ok "守卫会放行（当前局面下正常）" ;;
        1) ok "守卫会**拒绝**启动 —— 这是它该做的事" ;;
        2) bad "守卫返回 2（配置类错误）"; fail=1 ;;
        3) bad "守卫返回 3（依赖不可达：仲裁节点或 arping）"; fail=1 ;;
        *) bad "守卫返回 $rc"; fail=1 ;;
        esac
        say ""
        printf '%s\n' "$out" | sed 's/^/    /'
    fi

    title "⑦ 仲裁节点"
    local url; url=$(conf_get ARBITER_URL)
    if [ -z "$url" ]; then
        bad "没配 ARBITER_URL —— 没有仲裁节点就没有自动切换（§3.2 条件二）"; fail=1
        return 1
    fi
    local body mbody
    if body=$(http_get "${url%/}/health" 2>/dev/null); then
        ok "$url/health 可达"
        # ★ /health 里**没有** blind 这个键（它只回 composite / vip / nodes /
        #   observed_age_sec）。blind 只有 /metrics 有 —— 所以这里发第二个请求，
        #   两个都喂给下面那段。
        mbody=$(http_get "${url%/}/metrics" 2>/dev/null || true)
        # ★ 这个 Python 的退出码**参与** fail 判定：blind 与"没配节点"
        #   都会让它返回非 0。它们是"仲裁节点在运行但给不出可用结论"，
        #   与"仲裁节点不可达"是两件事，但对自动切换的后果一样 —— 都不能切。
        if ! "$PY" - "$body" "$mbody" <<'PY'
import json
import sys

body, mbody = sys.argv[1:3]

try:
    d = json.loads(body)
except ValueError:
    print("      [!!] /health 返回的不是 JSON")
    sys.exit(1)

# ★ composite 是**字符串**（"OK" / "BLIND" / "NO_PRIMARY" / "SPLIT_BRAIN" …），
#   不是字典。这里曾经按 d["composite"]["state"] 取，于是每一次 check 都在
#   这一项抛 AttributeError —— 下面这些提示一次都没跑到过。
print("      综合状态：%s" % (d.get("composite") or "?"))
print("      结论年龄：%s 秒" % (d.get("observed_age_sec")))

bad = 0

# ★ /metrics 是 `key value` 的扁平文本。要**精确匹配键名**，
#   不能用子串找 —— 否则 selfcheck_ok 这类键会被当成 blind。
blind = None
for line in (mbody or "").splitlines():
    p = line.split()
    if len(p) == 2 and p[0] == "blind":
        blind = (p[1] == "1")
        break

if blind is None:
    # ★ 「判据不可用」不等于「判据通过」。拿不到就明说，不要静默放过。
    print("      [!!] 取不到 /metrics 的 blind —— 无法确认仲裁节点是不是自己瞎了。")
    print("           （/health 能通而 /metrics 取不到，多半是它自己的问题。）")
    bad = 1
elif blind:
    print("      [!!] ★ blind=true —— 仲裁节点的**自检闸没过**：")
    print("           它可能是自己瞎了，而不是对端不在服务。")
    print("           此时所有判定都是 unknown + blind，自动接管不会发生。")
    print("           检查 SELFCHECK_TARGETS 里的网关/交换机管理地址。")
    bad = 1

if not d.get("nodes"):
    print("      [!!] 仲裁节点没有配置任何节点 —— 它无法判定任何东西。")
    bad = 1
sys.exit(bad)
PY
        then
            fail=1
        fi
    else
        bad "$url/health 不可达 —— 没有许可，备库不会提升（§6.1 场景 5/11）"
        warn "  这是**依赖不可达**（退出码 3），不是配置错误。"
        unreachable=1
    fi

    title "⑧ /report 是否成功"
    if [ "$DRY_RUN" = yes ]; then
        printf '      [dry-run] 向 %s/report 发一次上报\n' "${url%/}"
    else
        local rmsg
        rmsg=$("$PY" - "$HA_DIR" <<'PY' 2>&1
import sys

sys.path.insert(0, sys.argv[1])
try:
    import halib as H
except Exception as e:
    print(" 导入 halib 失败：%s" % e)
    sys.exit(2)

try:
    conf = H.Conf()
except Exception as e:
    print(" 构造配置失败：%s" % e)
    sys.exit(2)

ok, err = H.report(conf, action="none", detail="install.sh check 自检上报")
if ok:
    print(" OK")
    sys.exit(0)
print(" %s" % (err or "上报失败"))
sys.exit(1)
PY
)
        case "$rmsg" in
        " OK") ok "/report 成功（仲裁节点已收到本机的角色与动作）" ;;
        *) bad "/report 失败：$rmsg"; fail=1 ;;
        esac
    fi

    title "⑨ ★ 三份配置的 VIP 一致性"
    # 三份 = 221 的 cluster.conf + 222 的 cluster.conf + 仲裁的 arbiter.conf。
    # 本机能读到的只有两份：本机的，和仲裁节点回显的。
    # ★ 对端那一份**读不到** —— 两机之间没有 SSH 互信（N9），这是有意的。
    #   所以这里把"验了什么"和"没验什么"分开说，而不是含糊地报个 OK。
    local myvip aip bip
    myvip=$(conf_get VIP); aip=$(conf_get NODE_A_IP); bip=$(conf_get NODE_B_IP)
    say "  本机 cluster.conf  VIP = ${myvip:-（空）}"
    if [ -n "${body:-}" ]; then
        "$PY" - "$body" "$myvip" "$aip" "$bip" <<'PY'
import json
import re
import subprocess
import sys

body, myvip, aip, bip = sys.argv[1:5]
d = json.loads(body)
avip = (d.get("vip") or "").strip()
anodes = [x for x in (d.get("nodes") or []) if x]

print("  仲裁 arbiter.conf  VIP = %s" % (avip or "（空）"))
bad = 0
if not avip:
    print("      [!!] 仲裁节点没配 VIP —— 它无法判断 VIP 归属，"
          "判据①会一直是「不可用」。")
    bad = 1
elif avip != myvip:
    print("      [!!] ★ 两份不一致：本机 %s，仲裁 %s。" % (myvip, avip))
    print("           这是**静默**错误里最贵的一种：平时一切正常，")
    print("           直到需要切换的那天才发现仲裁看的是另一个地址。")
    bad = 1
else:
    print("      [OK] 与本机一致")

if anodes:
    if sorted(anodes) != sorted([x for x in (aip, bip) if x]):
        print("      [!!] 节点集合不一致：本机配的是 %s，仲裁配的是 %s。"
              % ("/".join(x for x in (aip, bip) if x), "/".join(anodes)))
        bad = 1
    else:
        print("      [OK] 节点集合一致（%s）" % "/".join(anodes))
        out = ""
        try:
            out = subprocess.run(["ip", "-4", "-o", "addr", "show"],
                                 capture_output=True, text=True,
                                 timeout=10).stdout
        except Exception:
            pass
        mine = set(re.findall(r"inet\s+(\d+\.\d+\.\d+\.\d+)", out))
        if mine and not (mine & set(anodes)):
            print("      [!!] 本机地址 %s 不在节点集合里 —— 配置文件放错了机器。"
                  % ", ".join(sorted(mine)))
            bad = 1
else:
    print("      [!!] 仲裁节点没有配置任何节点。")
    bad = 1

print("")
print("  第三份（对端节点的 cluster.conf）**本机读不到**：")
print("    两机之间刻意没有 SSH 互信（N9），所以这里不假装验过它。")
print("    做法：在**另一台**节点上跑同一条命令。两台都通过 = 三份一致。")
sys.exit(bad)
PY
        if [ $? -ne 0 ]; then fail=1; fi
    else
        warn "仲裁节点不可达，无法比对（这正是退出码 3 的情形）"
    fi

    title "⑩ AUTO_PROMOTE 当前值"
    local ap; ap=$(conf_get AUTO_PROMOTE)
    if [ "$ap" = "yes" ]; then
        warn "★ AUTO_PROMOTE = yes（自动接管**开启**）"
        say "    演练与交付期间应当是 no。设成 no 时系统其余行为全部照旧，"
        say "    只是不执行接管判定 —— 也就是「该切换却不切换」。"
    elif [ "$ap" = "no" ]; then
        ok "AUTO_PROMOTE = no（自动接管当前被抑制）"
        say "    演练二（自动接管）需要 yes。"
    else
        bad "AUTO_PROMOTE 的值是 ${ap:-（空）} —— 认不出来。"
        say "    代码在认不出来时按缺省 yes 处理（见 halib.getbool 的注释）。"
        say "    ★ 显式写上 no 或 yes，不要让「缺省意图」替你决定。"
        fail=1
    fi
    local aj; aj=$(conf_get AUTO_REJOIN)
    info "AUTO_REJOIN = ${aj:-（缺省 no）}（自动归位；演练四过了再开）"

    hr
    if [ "$fail" -ne 0 ]; then
        bad "有检查项没通过（退出码 1）"
        return 1
    fi
    if [ "$unreachable" -ne 0 ]; then
        warn "本机检查通过，但**仲裁节点不可达**（退出码 3）"
        warn "  ★ 此时能维持现状：主库不停、备库不提升（N13）。"
        warn "    但没有自动切换能力，直到仲裁节点回来。"
        return 3
    fi
    ok "全部检查通过"
    return 0
}

# ---- 仲裁节点侧检查 ----
check_arbiter() {
    local target="$1" fail=0

    title "① 配置"
    [ -e "$ARBITER_CONF" ] || { bad "没有 $ARBITER_CONF —— 先跑 install.sh arbiter"; return 2; }
    local m; m=$(stat -c '%a' "$ARBITER_CONF" 2>/dev/null || echo "?")
    [ "$m" = "600" ] && ok "arbiter.conf 权限 600" || { bad "arbiter.conf 权限是 $m，应当是 600（它含 ARBITER_TOKEN）"; fail=1; }
    config_gate "$ARBITER_CONF" arbiter || fail=1
    conf_load "$ARBITER_CONF"

    title "② 目录、权限与服务"
    local d mm owner
    for d in "$ARBITER_DIR" "$ARBITER_ADAPTER_DIR" "$ARBITER_ADAPTER_CONF_DIR" "$ARBITER_STATE" "$(conf_get DIST_DIR)"; do
        [ -n "$d" ] || continue
        if [ -d "$d" ]; then
            mm=$(stat -c '%a' "$d" 2>/dev/null || echo "?")
            owner=$(stat -c '%U:%G' "$d" 2>/dev/null || echo "?")
            ok "$d（$mm $owner）"
        else
            bad "目录不存在：$d"; fail=1
        fi
    done
    if id zbxarb >/dev/null 2>&1; then
        ok "系统用户 zbxarb 在（HTTP 服务以它运行）"
    else
        bad "没有 zbxarb 用户 —— zbx-arbiter-http.service 起不来"; fail=1
    fi
    # ★ 真的**以 zbxarb 的身份**去试，而不是看模式数字：
    #   ① root 自己 test -w 永远是 true，那样这条检查永远不会失败；
    #   ② 模式数字看不见 ACL —— 本套件给 arbiter.conf 的推荐补丁正是 setfacl，
    #      只判数字会在"已经用 ACL 修好了"的机器上报假警。
    local sd
    sd=$(conf_get ARBITER_STATE_DIR); [ -n "$sd" ] || sd=$ARBITER_STATE
    if [ "$(id -u)" != 0 ]; then
        warn "当前不是 root，跳过「zbxarb 能否写状态目录」（runuser 要 root）"
    elif ! id zbxarb >/dev/null 2>&1 || ! command -v runuser >/dev/null 2>&1; then
        warn "没有 zbxarb 或 runuser，跳过「zbxarb 能否写状态目录」"
    elif runuser -u zbxarb -- /usr/bin/test -w "$sd" &&
         runuser -u zbxarb -- /usr/bin/test -x "$sd"; then
        ok "zbxarb 能写 $sd（POST /report 往这里落 reports.json）"
    else
        bad "★ zbxarb **写不了** $sd —— POST /report 会 PermissionError"
        say "      HTTP 服务以 zbxarb 运行；它没有写权限时，收一次上报就崩一次连接，"
        say "      而节点侧看到的是「Remote end closed connection without response」，"
        say "      像是网络问题。journalctl 里才是 Errno 13 的真话。"
        say "      修：sudo chmod 770 $sd"
        fail=1
    fi
    if grep -qE '^\s*User\s*=\s*root' "$SYSTEMD_DIR/zbx-arbiter-http.service" 2>/dev/null; then
        bad "★ HTTP 服务以 root 运行 —— 它只读一个 JSON 文件，不需要特权"
        fail=1
    else
        ok "HTTP 服务不是 root（对外监听的进程不该是 root）"
    fi
    # ★ ProtectSystem=strict 不是 DAC 权限，上面那个 runuser 探针**看不见它** ——
    #   所以单独确认另一半：单元自己声明了可写路径。
    if grep -qE '^[[:space:]]*ReadWritePaths=.*zbx-arbiter' "$SYSTEMD_DIR/zbx-arbiter-http.service" 2>/dev/null; then
        ok "单元里 ReadWritePaths 放开了状态目录（ProtectSystem=strict 的另一半）"
    else
        warn "单元里没看到 ReadWritePaths=…zbx-arbiter —— ProtectSystem=strict 下写不进去"
    fi
    if systemctl is-active --quiet zbx-arbiter-http.service; then
        ok "zbx-arbiter-http.service 在跑"
    else
        bad "★ zbx-arbiter-http.service 没在跑（或没装 / 没启用）"
        say "      节点侧因此拿不到许可 —— 备库不会提升。看："
        say "      systemctl status zbx-arbiter-http.service"
        say "      journalctl -u zbx-arbiter-http.service -n 30"
        say "      ★ 若那行是 Errno 13 而路径里含 arbiter.conf，那是**读不到配置**，"
        say "        与上面那条「状态目录写不了」是两件不同的事，别按同一个办法修。"
        fail=1
    fi

    title "③ 观测是否在跑"
    local st="$ARBITER_STATE/adapters.json"
    if [ -e "$st" ]; then
        ok "状态文件在：$st"
        "$PY" - "$st" <<'PY'
import json
import sys
import time

try:
    with open(sys.argv[1], encoding="utf-8-sig") as fh:
        a = json.load(fh)
except (OSError, ValueError) as e:
    print("      [!!] 读不出状态文件：%s" % e)
    sys.exit(1)
age = int(time.time() - a.get("run_epoch", 0)) if a.get("run_epoch") else None
if age is None:
    print("      [!!] 状态文件里没有 run_epoch —— 一轮观测都没跑完过")
    sys.exit(1)
print("      上一轮观测：%s 秒前（%s）"
      % (age, "正常" if age <= 90 else "★ 太旧 —— 判定会全部变成 unknown"))
sc = a.get("selfcheck") or {}
print("      自检闸：%s（%s）" % ("通过" if sc.get("ok") else "★ 未通过",
                                 sc.get("reason") or ""))
if not sc.get("ok"):
    print("      [!!] ★ 自检闸不过 = 仲裁节点可能自己瞎了。")
    print("           (这不是「对端不在服务」，是「我们自己看不见」。)")
    print("           检查 SELFCHECK_TARGETS（里要有网关或交换机管理地址）。")

# ★ 复制实况：这一路**不是**许可判据，但它决定页面与 /metrics 停在哪个状态。
#   常年停在 NO_STANDBY 的后果是一条真报警淹没在假报警里，所以要看得见。
#   ★ 这里**不算失败**：刚装完第一台时（对端还没就位）它本来就该是 false。
rep = a.get("replication") or {}
if rep.get("streaming"):
    print("      复制实况：streaming（%s）" % (rep.get("detail") or ""))
else:
    print("      复制实况：★ 没有备库在 streaming —— %s"
          % (rep.get("detail") or "（无详情）"))
    print("                ★ 若详情里是「probe 账号连不上」，检查 arbiter.conf 的")
    print("                  PROBE_PWD / PROBE_USER / PSQL（这一路用的是它们，")
    print("                  与装了哪几个适配器无关）。")
    print("                ★ 若已装好但仍是这一句，那可能是**真**没有备库在复制 ——")
    print("                  备库活得好好的却不复制是常见故障（U4）。")
PY
        if [ $? -ne 0 ]; then fail=1; fi
    else
        bad "没有 $st —— 观测周期没跑过。看："
        say "      systemctl status zbx-arbiter.timer zbx-arbiter.service"
        say "      journalctl -u zbx-arbiter.service -n 50"
        fail=1
    fi

    title "④ ★ 适配器逐个真跑验证"
    # ★ 这是本子命令里最要紧的一段：**真跑**，不是看文件在不在。
    #   适配器目录里放着一个跑不起来的脚本，和没放它，在故障当天
    #   的差别是"我们瞎了"与"这路观测本来就没有" —— 而修法完全不同。
    local adir; adir=$(conf_get ARBITER_ADAPTER_DIR)
    [ -n "$adir" ] || adir=$ARBITER_ADAPTER_DIR
    if [ ! -d "$adir" ]; then
        bad "适配器目录不存在：$adir"; fail=1
        return 1
    fi
    local n=0 f
    for f in "$adir"/*; do
        [ -x "$f" ] && [ -f "$f" ] || continue
        n=$((n + 1))
    done
    if [ "$n" -eq 0 ]; then
        bad "适配器目录 $adir 里没有任何可执行文件 —— 判定会全部是 unknown"; fail=1
    fi
    local jl; jl=$(conf_get JUDGE_LEVEL_ADAPTERS)
    say "  判据型白名单 JUDGE_LEVEL_ADAPTERS = ${jl:-（空）}"
    say "  ★ 不在白名单里的一律是**否决型**：它能说「不行」，不能说「行」。"
    say "    这是安全边界，不是性能开关。"
    say ""
    if [ "$DRY_RUN" = yes ]; then
        say "  [dry-run] 不真跑适配器（它们会去 ping/arping/问 BMC）。"
        return "$fail"
    fi

    "$PY" - "$adir" "$jl" "$target" "$ARBITER_CONF" <<'PY'
import fnmatch
import json
import os
import re
import subprocess
import sys

adir, jl, target, conf_path = sys.argv[1:5]

def parse(path):
    d = {}
    try:
        with open(path, encoding="utf-8-sig") as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, v = s.split("=", 1)
                d[k.strip()] = v.strip().strip("'\"")
    except OSError:
        pass
    return d

conf = parse(conf_path)
pats = [p for p in re.split(r"[,\s]+", (jl or "").strip()) if p]
timeout = int(conf.get("ADAPTER_TIMEOUT") or 10)

env = dict(os.environ)
for k in ("VIP", "VIP_PREFIX", "NIC", "ARBITER_TOKEN", "ARBITER_STATE_DIR"):
    if conf.get(k):
        env[k] = conf[k]

# ★★ 网卡必须**在这里也推导一遍**，与 arbiter-round.py 用同一条路
#    （NIC 填了就用，没填就 `ip route get <VIP>`）。
#    否则 check 验的就不是线上跑的那一套：线上有网卡、check 说"配置里缺 NIC"，
#    或者反过来 —— 两种都会把人引到错的方向。
nic = (conf.get("NIC") or "").strip()
nic_note = "配置里填的"
if not nic:
    vip = (conf.get("VIP") or "").strip()
    if vip:
        try:
            r = subprocess.run(["ip", "route", "get", vip],
                               capture_output=True, text=True, timeout=5)
            m = re.search(r"\bdev\s+(\S+)", r.stdout or "")
            nic = m.group(1) if m else ""
        except Exception:
            nic = ""
    nic_note = "由 `ip route get %s` 推导" % ((conf.get("VIP") or "").strip() or "?")
if nic:
    env["NIC"] = nic
print("  观测网卡：%s（%s）" % (nic or "★ 没推出来", nic_note))
if not nic:
    print("  [!!] ★ 拿不到网卡名 —— 10-network.sh 会返回「不可用（rc=2）」，")
    print("       而它是判据①唯一的底，判定会停在 unknown（看起来像「谁都不能冷启动」）。")
    print("       处置：在 arbiter.conf 里显式填 NIC。")
nodes = [x for x in (conf.get("NODE_A_IP"), conf.get("NODE_B_IP")) if x]
env["NODE_A_IP"] = nodes[0] if nodes else ""
env["NODE_B_IP"] = nodes[1] if len(nodes) > 1 else ""
env["ARBITER_PEER_IP"] = target
env["ARBITER_PEER_MAC"] = ""
env["ARBITER_SELF_IP"] = ""
env["ARBITER_SELF_MAC"] = ""

names = sorted(os.listdir(adir))
RC = {
    0: ("0 证据成立", "对端确实不在服务", "[ OK ]"),
    1: ("1 证据不成立", "对端**在**服务 —— 一票否决", "[否决]"),
    2: ("2 不可用", "我们自己瞎了（不是对端的问题）", "[瞎了]"),
    3: ("3 无结论", "看了，但看不出 —— 既不放行也不否决", "[无结论]"),
}
bad = 0
for name in names:
    path = os.path.join(adir, name)
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        continue
    judge = any(fnmatch.fnmatch(name, p) for p in pats)
    kind = "判据型（可以一票通过）" if judge else "否决型（只能说不行）"
    try:
        r = subprocess.run([path, target], env=env, capture_output=True,
                           text=True, timeout=timeout)
        rc = r.returncode
        out = (r.stdout or "").strip()
    except subprocess.TimeoutExpired:
        rc, out = 2, "超时（%s 秒）—— 按「不可用」处理，**不是**按「证据成立」" % timeout
    except OSError as e:
        rc, out = 2, "跑不起来：%s" % e

    label, meaning, mark = RC.get(rc, ("%d 非法退出码" % rc,
                                       "按「不可用」处理（不是「证据成立」）", "[非法]"))
    first = (out.split("\n")[0] if out else "").strip()
    print("  %s %s" % (mark, name))
    print("        类别：%s" % kind)
    print("        退出码：%s —— %s" % (label, meaning))
    if first:
        print("        理由：%s" % first)
    if rc not in (0, 1, 2, 3):
        bad = 1
    if name.startswith("10-network") and rc == 2:
        print("        [!!] ★ 10-network.sh 是**必选**适配器，它「不可用」"
              "意味着判据①没有底。")
        print("             两个原因，按可能性排：")
        print("             ① arping 装错了包（U3）：要的是 iputils-arping"
              "（/usr/bin/arping）。")
        print("             ② 上面那行「观测网卡」是「没推出来」"
              "—— 适配器拿不到 NIC，第一件事就是退出 2。")
        bad = 1
    if judge and rc == 0:
        print("        ★ 这一路的一票通过是**真的**一票通过 —— 它会直接"
              "让节点拿到许可。")

print("")
print("  ★ 真跑用的是 --target %s。要验另一台：--target <另一个 IP>。" % target)
print("  ★ 「不通过(1)」与「不可用(2)」必须分开看：前者说明对端还活着，")
print("     后者说明我们自己瞎了 —— 两者对运维的含义完全相反。")
sys.exit(bad)
PY
    if [ $? -ne 0 ]; then fail=1; fi

    title "⑤ 分发目录里有没有混进凭据"
    # ★ 分发目录是 644 且**无需认证**（S13）。里面出现任何凭据 ——
    #   哪怕密文 —— 都等于把凭据放在公告板上。
    local dd; dd=$(conf_get DIST_DIR)
    [ -n "$dd" ] || dd=$DIST_DIR_DEFAULT
    if [ -d "$dd" ]; then
        local hits=0 af
        while IFS= read -r af; do
            [ -n "$af" ] || continue
            if grep -qiE '(^|[^A-Z_])(PG_SUPER_PWD|PG_REPL_PWD|PG_ZBX_PWD|PROBE_PWD|ARBITER_TOKEN|IPMI_PWD|SNMP_|ESXI_PWD)[[:space:]]*=[[:space:]]*[^[:space:]]' "$af" 2>/dev/null; then
                bad "$af 里有填了值的凭据字段 —— 分发目录里**禁止**出现凭据"
                hits=1
            fi
        done < <(find "$dd" -maxdepth 1 -type f 2>/dev/null)
        if [ "$hits" -eq 0 ]; then
            ok "$dd 里没有填了值的凭据字段"
        else
            fail=1
        fi
        info "目录内容：$(ls -1 "$dd" 2>/dev/null | tr '\n' ' ')"
    else
        warn "$dd 不存在（还没生成过配置骨架）"
    fi

    title "⑥ AUTO_PROMOTE 是节点侧的键"
    say "  它不在仲裁节点上。审核它的值是**节点侧** check 的第 ⑩ 项"
    say "  （in 每一台节点上都要看一眼 —— 两台设成不一样是本方案最容易踩的坑）。"

    hr
    if [ "$fail" -ne 0 ]; then
        bad "有检查项没通过（退出码 1）"
        return 1
    fi
    ok "全部检查通过"
    return 0
}

cmd_check() {
    local role="" target=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --role) [ $# -ge 2 ] || die "--role 后面要跟 node 或 arbiter"; role=$2; shift 2 ;;
        --role=*) role=${1#*=}; shift ;;
        --target) [ $# -ge 2 ] || die "--target 后面要跟 IP"; target=$2; shift 2 ;;
        --target=*) target=${1#*=}; shift ;;
        --dry-run) DRY_RUN=yes; shift ;;
        -h|--help) usage_check; return 0 ;;
        *) die "check: 不认识的参数 $1" ;;
        esac
    done

    if [ -z "$role" ]; then
        # 靠现场线索判断本机是哪一类 —— 但把判断结果说出来，
        # 因为判错会让整个 check 看错对象。
        if [ -d "$ARBITER_DIR" ] && [ -e "$ARBITER_CONF" ]; then
            role=arbiter
        elif [ -e "$HA_DIR/cluster.conf" ]; then
            role=node
        else
            die "本机既不像节点（没有 $HA_DIR/cluster.conf）也不像仲裁节点"
        fi
        info "本机判为：$role（写死可用 --role 覆盖）"
    fi

    case "$role" in
    node)
        require_distro node
        if [ -z "$target" ]; then
            conf_load "$HA_DIR/cluster.conf"
            target=$(conf_get NODE_A_IP)
            [ -n "$target" ] || target=$(conf_get NODE_B_IP)
        fi
        check_node "$target"
        return $?
        ;;
    arbiter)
        require_distro arbiter
        if [ -z "$target" ]; then
            conf_load "$ARBITER_CONF"
            target=$(conf_get NODE_A_IP)
            [ -n "$target" ] || target=$(conf_get NODE_B_IP)
        fi
        if [ -z "$target" ]; then
            die "不知道该把哪个 IP 当作「对端」 —— 用 --target 指定。"
        fi
        check_arbiter "$target"
        return $?
        ;;
    *) die "--role 只能是 node 或 arbiter（收到 $role）。" ;;
    esac
}

# ============================================================
# manifest —— md5 比对
# ============================================================

usage_manifest() {
    cat <<'EOF'
install.sh manifest [--role node|arbiter] [--src DIR]

  把**装在机器上的**脚本与 systemd 单元，与**部署包里的**逐个 md5 比对。
  用途：交接时确认「装的这一套」就是「审过的那一套」，
        以及事后发现有人手工改过哪个脚本。

  --role    比对哪一类的清单（node / arbiter）。不给就按本机线索自动判。
            ★ 这一步不能省：节点上没有仲裁节点的目录，反之亦然 ——
            不分类会比出一堆「缺失」，让这个命令永远失败。
  --src     部署包所在目录（默认本脚本所在目录）。

  不在比对范围内：适配器目录（按现场选择）、配置文件（含凭据）。
  退出码：0 全一致 / 1 有缺失或不一致 / 2 参数或本机身份无法判定
EOF
}

cmd_manifest() {
    local role="" src="$SRC"
    while [ $# -gt 0 ]; do
        case "$1" in
        --role) [ $# -ge 2 ] || die "--role 后面要跟 node 或 arbiter"; role=$2; shift 2 ;;
        --role=*) role=${1#*=}; shift ;;
        --src) [ $# -ge 2 ] || die "--src 后面要跟目录"; src=$2; shift 2 ;;
        --src=*) src=${1#*=}; shift ;;
        --dry-run) DRY_RUN=yes; shift ;;
        -h|--help) usage_manifest; return 0 ;;
        *) die "manifest: 不认识的参数 $1" ;;
        esac
    done
    SRC=$src

    [ -d "$HA_DIR" ] || [ -d "$ARBITER_DIR" ] || die "本机上既没有 $HA_DIR 也没有 $ARBITER_DIR。"

    # ★ 清单必须按角色选。节点上没有 $ARBITER_DIR、仲裁节点上没有 $HA_DIR，
    #   把两边的清单一起比，另一方的那几个文件会全部报「缺失」——
    #   于是 manifest **永远**失败，也就没人会再信它（而它正是交接时的凭据）。
    if [ -z "$role" ]; then
        if [ -d "$ARBITER_DIR" ] && [ -f "$ARBITER_CONF" ]; then
            role=arbiter
        elif [ -f "$HA_DIR/cluster.conf" ]; then
            role=node
        else
            die "认不出本机是哪一类（既没有 $ARBITER_CONF，也没有 $HA_DIR/cluster.conf）。用 --role 指定。"
        fi
        info "未指定 --role，按本机线索判为：$role"
    fi
    local -a lists
    case "$role" in
    node)    lists=(node_bin_files node_unit_files) ;;
    arbiter) lists=(arbiter_bin_files arbiter_unit_files) ;;
    *)       die "manifest: --role 只认 node 或 arbiter（给的是 $role）" ;;
    esac

    local fail=0 n=0 s d ms md
    hr
    printf '%-46s %-10s %s\n' "文件" "状态" "备注"
    hr
    while IFS='|' read -r s d; do
        [ -n "$s" ] || continue
        n=$((n + 1))
        if [ ! -f "$d" ]; then
            printf '%-46s %-10s %s\n' "$d" "缺失" "部署包里没有对应文件？"
            fail=1
            continue
        fi
        ms=$(md5sum "$s" 2>/dev/null | cut -d' ' -f1)
        md=$(md5sum "$d" 2>/dev/null | cut -d' ' -f1)
        if [ "$ms" = "$md" ]; then
            printf '%-46s %-10s %s\n' "$d" "一致" "$ms"
        else
            printf '%-46s %-10s %s\n' "$d" "★不一致" "包 $ms / 机 $md"
            fail=1
        fi
    done < <(for _f in "${lists[@]}"; do "$_f"; done)
    hr
    say "共比对 $n 个文件。"
    if [ "$fail" -ne 0 ]; then
        bad "有文件缺失或与部署包不一致。"
        say "  ★ 不一致不一定是坏事（有人为了排查手工改过），但它必须是被"
        say "    **知道**的 —— 这套系统的所有判断都建立在「脚本就是审过的那一份」上。"
        return 1
    fi
    ok "全部一致（$n 个文件）"
    say ""
    say "  适配器目录与配置文件不在比对范围内（它们按现场选择、且含凭据）："
    say "    仲裁的适配器：ls -l $(conf_get ARBITER_ADAPTER_DIR 2>/dev/null || echo $ARBITER_ADAPTER_DIR)"
    say "    配置：$HA_DIR/cluster.conf  $HA_DIR/node.conf  $ARBITER_CONF"
    return 0
}

# ============================================================
# 总入口
# ============================================================

usage() {
    cat <<'EOF'
install.sh —— PostgreSQL/Zabbix 高可用部署器（§5 M9）

用法：install.sh <子命令> [选项]

  genconf   生成主/备两份配置骨架（值全部留空）
  install   部署节点：--role primary|standby
  venv      按所选适配器决定装什么（只配网络探测时为**零依赖**）
  arbiter   部署仲裁节点：HTTP 服务 + timer + 分发目录 + 适配器
  check     自检：可达性 / 权限 / 上报 / 适配器真跑 / 三份配置一致性
  manifest  脚本与配置的 md5 比对

每个子命令都支持 -h 看详细说明。
install / venv / arbiter / check / manifest 都支持 --dry-run（N10）；
genconf 没有这个开关 —— 它只在部署包目录里生成模板，不碰系统。

★ 密码永远不离开目标机器：骨架里密码字段一律留空，
  人在**本机**填好，install 以那个文件为数据源。
  install 会拒绝空密码 / 占位符 / 含禁止字符的配置（§5 M9）。
EOF
}

main() {
    [ $# -ge 1 ] || { usage; exit 2; }
    local cmd=$1; shift
    case "$cmd" in
    genconf)  cmd_genconf "$@" ;;
    install)  cmd_install "$@" ;;
    venv)     cmd_venv "$@" ;;
    arbiter)  cmd_arbiter "$@" ;;
    check)    cmd_check "$@" ;;
    manifest) cmd_manifest "$@" ;;
    -h|--help|help) usage ;;
    *) usage; die "不认识的子命令：$cmd" ;;
    esac
    return $?
}

main "$@"
