#!/system/bin/sh
# 进程守护 (Process Guardian) v2.2
# 模块：hy_process_guardian
#
# 白名单来自 /data/adb/hy_guardian/list.conf（由 WebUI 维护），
# 每行一个包名。守护进程按该名单对每个包的所有进程做多层加固。
#
# 一加/ColorOS 的四层杀进程机制（本机实测）：
#   ① freeze      cgroup.freeze = 1       进程冻结
#   ② suspend     oplus_suspend_resume    线程挂起
#   ③ kill        lmkd / athena           进程消失
#   ④ force-stop  framework 直接终止       任何模块拦不住
#
# 本脚本对①②③做对策，④无法拦截。
#
# 另提供内存清理（mem_* 函数，由 WebUI 调用）：
#   - 按优先级逐级清理（drop_caches → 回收后台 → 终止空进程）
#   - 白名单内的应用永不清理，避免与守护逻辑冲突

DATADIR="/data/adb/hy_guardian"
LIST="$DATADIR/list.conf"
CONF="$DATADIR/guard.conf"
LOG="/data/local/tmp/hy_guardian.log"

# 读配置（WebUI 写入）
# load_conf 在主循环里也会周期调用，保证 WebUI 改完不用重启即生效
load_conf() {
    OOM_ADJ="-1000"
    POLL_INTERVAL="1"
    ENABLE_FREEZE_THAW="1"
    ENABLE_CGROUP_MOVE="1"
    ENABLE_DOZE="1"
    ENABLE_APPOPS="1"
    MEM_AUTO_CLEAN="0"
    MEM_AUTO_INTERVAL="1800"
    MEM_CLEAN_LEVEL="2"
    MEM_MIN_AVAIL_MB="1500"
    [ -f "$CONF" ] && . "$CONF"
    # 防呆：非法值回退到安全默认
    case "$POLL_INTERVAL" in ''|*[!0-9]*|0) POLL_INTERVAL=1 ;; esac
    [ "$POLL_INTERVAL" -lt 1 ] && POLL_INTERVAL=1
    [ "$POLL_INTERVAL" -gt 60 ] && POLL_INTERVAL=60
    case "$MEM_CLEAN_LEVEL" in 1|2|3) ;; *) MEM_CLEAN_LEVEL=2 ;; esac
    case "$MEM_MIN_AVAIL_MB" in ''|*[!0-9]*) MEM_MIN_AVAIL_MB=1500 ;; esac
}

load_conf

log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt 204800 ]; then
        tail -c 102400 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    fi
}

# 读白名单（去掉空行与注释）
read_list() {
    [ -f "$LIST" ] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$LIST" 2>/dev/null | grep -v '^$'
}

# 包名 → 进程名匹配（含 :remote 子进程）
is_target() {
    local name="$1" pkg
    for pkg in $PKGS; do
        case "$name" in
            "$pkg"|"$pkg":*) return 0 ;;
        esac
    done
    return 1
}

# ────────────────────────────────────────────────────────────
# 内存清理
# ────────────────────────────────────────────────────────────

# 输出内存状态（键值行，便于 WebUI 解析）
mem_stat() {
    awk '
        $1=="MemTotal:"{t=$2}
        $1=="MemAvailable:"{a=$2}
        $1=="MemFree:"{f=$2}
        $1=="Cached:"{c=$2}
        $1=="Buffers:"{b=$2}
        $1=="SwapTotal:"{st=$2}
        $1=="SwapFree:"{sf=$2}
        END{
            printf "total_kb=%d\n", t
            printf "avail_kb=%d\n", a
            printf "free_kb=%d\n", f
            printf "cached_kb=%d\n", c
            printf "buffers_kb=%d\n", b
            printf "swap_total_kb=%d\n", st
            printf "swap_free_kb=%d\n", sf
            if (t > 0) printf "used_pct=%d\n", (t-a)*100/t
        }' /proc/meminfo 2>/dev/null
    # 进程数统计（dumpsys 可能返回空，统一归 0，避免命令替换污染输出）
    local total cached
    total=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
    cached=$(dumpsys activity processes 2>/dev/null | grep -c "cached=true" 2>/dev/null)
    case "$cached" in ''|*[!0-9]*) cached=0 ;; esac
    echo "proc_total=${total:-0}"
    echo "proc_cached=$cached"
    # zram（dumpsys meminfo 的 ZRAM 行："ZRAM:  717,280K physical used for 2,723,736K in swap"）
    # 注意：数字带千位分隔符逗号（","），正则需容纳并剔除
    local zused
    zused=$(dumpsys meminfo 2>/dev/null \
        | sed -n 's/.*ZRAM:[[:space:]]*\([0-9,]*\)K.*/\1/p' \
        | head -n1 | tr -d ',')
    echo "zram_used_kb=${zused:-0}"
}

# 保护名单里的 pid 集合，用于清理时排除
protected_pids() {
    local pkg d cname p
    local n=0
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        cname=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -n1)
        [ -n "$cname" ] || cname=$(cat "$d/comm" 2>/dev/null)
        [ -n "$cname" ] || continue
        for pkg in $PKGS; do
            case "$cname" in
                "$pkg"|"$pkg":*) echo "$p"; n=$((n+1)); break ;;
            esac
        done
    done
    : $n
}

# 第 1 级：只清页缓存（最安全，不杀进程）
mem_clean_l1() {
    sync 2>/dev/null
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null && {
        log "MEM L1 drop_caches ok"
        return 0
    }
    log "MEM L1 drop_caches 失败（无写权限）"
    return 1
}

# 第 2 级：清缓存 + 回收后台（am kill-all，只杀 cached 空进程）
# 白名单进程通过 oom_score_adj=-1000 天然豁免
mem_clean_l2() {
    mem_clean_l1
    local before after
    before=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)

    # am kill-all 只终止可回收的后台进程，不影响前台与白名单（-1000 受保护）
    am kill-all >/dev/null 2>&1

    sleep 1
    after=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    echo "l2_freed_mb=$(( (after - before) / 1024 ))"
}

# 第 3 级：深度回收（不杀进程，只做更彻底的缓存/swap 回收）
# 实测结论：kill -9 第三方后台进程对 MemAvailable 几乎无收益
# （杀掉的页会立刻被系统复用），且有误杀风险，因此不做进程杀戮。
# 真正的收益来自：压缩 swap 回收 + 多次 drop_caches 迭加。
mem_clean_l3() {
    mem_clean_l2
    local before after i
    before=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)

    # 反复 sync + drop_caches，分几步释放脏页（一次不够）
    for i in 1 2 3; do
        sync 2>/dev/null
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        sleep 1
    done

    after=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    echo "l3_freed_mb=$(( (after - before) / 1024 ))"
}

# 统一入口：mem_clean <level>
# 会临时重设 PKGS，结束时恢复原值（避免影响调用方的守护循环）
mem_clean() {
    local level="${1:-2}"
    local saved_pkgs="$PKGS"
    PKGS=$(read_list)
    log "=== 内存清理开始 level=$level 保护组=[${PKGS}] ==="
    echo "before_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
    case "$level" in
        1) mem_clean_l1 ;;
        3) mem_clean_l3 ;;
        *) mem_clean_l2 ;;
    esac
    echo "after_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
    mem_stat
    PKGS="$saved_pkgs"
    log "=== 内存清理结束 ==="
}

# 加固单个 pid
harden() {
    local pid="$1" name="$2"

    # ① oom_score_adj
    local adj="/proc/$pid/oom_score_adj"
    if [ -w "$adj" ]; then
        local cur
        cur=$(cat "$adj" 2>/dev/null)
        if [ "$cur" != "$OOM_ADJ" ]; then
            echo "$OOM_ADJ" > "$adj" 2>/dev/null && log "ADJ $name($pid) $cur->$OOM_ADJ"
        fi
    fi

    # ② cgroup freezer 解冻
    [ "$ENABLE_FREEZE_THAW" = "1" ] || return 0
    local fz
    fz=$(awk -F: '$2=="freezer"{print $3}' "/proc/$pid/cgroup" 2>/dev/null)
    [ -n "$fz" ] || return 0
    local ffile="/sys/fs/cgroup${fz}/cgroup.freeze"
    if [ -f "$ffile" ]; then
        [ "$(cat "$ffile" 2>/dev/null)" = "1" ] && \
            echo 0 > "$ffile" 2>/dev/null && log "THAW $name($pid) $fz"
    fi
}

# 批量加固（性能关键路径）
#
# 两次实测教训：
#  1) 原实现 for 每个进程调 tr+head+cat，941 进程单轮 1159ms，
#     1 秒轮询实际 15 秒一轮，自动清理与守护全被拖垮。
#  2) /proc/<pid>/comm 被内核截断到 15 字符（"com.tungsten.fcl" → "com.tungsten.fc"），
#     所以必须用前缀匹配，不能"先精确匹配、失败再读 cmdline"
#     （后者会让几乎每个进程都走回退分支，比原方案更慢）。
#
# 现方案：一次 cat 通配符读完所有 comm（29ms），纯 bash 内建前缀匹配，
# 只有真正命中白名单的进程才去读 cmdline 取完整名（用于 :remote 子进程）。
harden_all() {
    local pid_list name_list pid name pkg full
    # 两个 glob 都按 pid 数值升序展开，顺序一致，可按下标对应
    pid_list=$(ls /proc 2>/dev/null | grep -E '^[0-9]+$')
    name_list=$(cat /proc/[0-9]*/comm 2>/dev/null)

    set -- $pid_list
    while [ $# -gt 0 ] && IFS= read -r name; do
        pid="$1"; shift
        [ -n "$name" ] || continue

        # 前缀匹配：comm 可能是包名前 15 字符
        for pkg in $PKGS; do
            case "$pkg" in
                "$name"*)           # comm 是包名或其前缀 → 命中
                    full=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n1)
                    harden "$pid" "${full:-$name}"
                    break ;;
            esac
        done
    done <<EOF
$name_list
EOF
}

# 一次性设置（Doze 白名单 / appops）：只在名单变化时重做
apply_static() {
    [ "$ENABLE_DOZE" = "1" ] && {
        for pkg in $PKGS; do
            dumpsys deviceidle whitelist +"$pkg" >/dev/null 2>&1
        done
    }
    [ "$ENABLE_APPOPS" = "1" ] && {
        for pkg in $PKGS; do
            cmd appops set "$pkg" RUN_IN_BACKGROUND allow 2>/dev/null
            cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND allow 2>/dev/null
            cmd appops set "$pkg" WAKE_LOCK allow 2>/dev/null
            cmd appops set "$pkg" START_FOREGROUND allow 2>/dev/null
        done
    }
    log "静态策略已应用（Doze=$ENABLE_DOZE appops=$ENABLE_APPOPS）"
}

# 自动清理：内存低于阈值时按配置级别清理
# 注意：mem_clean 内部会重设全局 PKGS，这里必须先存后恢复，
# 否则主循环的 is_target 判断会被打乱（白名单漏掉→进程失去保护）
auto_clean_check() {
    [ "$MEM_AUTO_CLEAN" = "1" ] || return 0
    local avail_mb
    avail_mb=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [ -n "$avail_mb" ] || return 0
    if [ "$avail_mb" -lt "$MEM_MIN_AVAIL_MB" ]; then
        local saved_pkgs="$PKGS"
        log "自动清理触发：可用 ${avail_mb}MB < 阈值 ${MEM_MIN_AVAIL_MB}MB"
        mem_clean "$MEM_CLEAN_LEVEL"
        PKGS="$saved_pkgs"
    fi
}

main() {
    mkdir -p "$DATADIR"
    log "=== 进程守护 v2.2 启动 ==="

    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do sleep 5; done
    log "系统就绪"

    local last_list=""
    local static_done=""
    local auto_tick=0
    local AUTO_EVERY=60
    local conf_tick=0
    local CONF_EVERY=5
    while true; do
        # 每 5 秒重读一次配置，WebUI 改完即生效（不用重启）
        conf_tick=$((conf_tick + POLL_INTERVAL))
        if [ "$conf_tick" -ge "$CONF_EVERY" ]; then
            conf_tick=0
            load_conf
        fi

        PKGS=$(read_list)

        # 名单变了 → 重做静态策略
        if [ "$PKGS" != "$last_list" ]; then
            log "白名单变更: [$PKGS]"
            static_done=""
            last_list="$PKGS"
        fi
        if [ -n "$PKGS" ] && [ -z "$static_done" ]; then
            apply_static
            static_done=1
        fi

        if [ -n "$PKGS" ]; then
            harden_all
        fi

        # 自动清理：按真实时间每 60 秒检查一次
        # （不能按循环次数算，否则 POLL_INTERVAL=30 时会变成 30 分钟才检查）
        auto_tick=$((auto_tick + POLL_INTERVAL))
        if [ "$auto_tick" -ge "$AUTO_EVERY" ]; then
            auto_tick=0
            auto_clean_check
        fi

        sleep "$POLL_INTERVAL"
    done
}

# 命令行子命令（供 WebUI 直接调用，无需常驻进程）
case "$1" in
    mem_stat)   PKGS=$(read_list); mem_stat ;;
    mem_clean)  mem_clean "$2" ;;
    *)
        # 无参数或非子命令 → 以等待模式和守护进程身份运行
        main
        ;;
esac
