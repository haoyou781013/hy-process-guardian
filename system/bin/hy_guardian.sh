#!/system/bin/sh
# 进程守护 (Process Guardian) v2.0
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

DATADIR="/data/adb/hy_guardian"
LIST="$DATADIR/list.conf"
CONF="$DATADIR/guard.conf"
LOG="/data/local/tmp/hy_guardian.log"

# ── 读配置（WebUI 写入）──
OOM_ADJ="-1000"
POLL_INTERVAL="1"
ENABLE_FREEZE_THAW="1"
ENABLE_CGROUP_MOVE="1"
ENABLE_DOZE="1"
ENABLE_APPOPS="1"
[ -f "$CONF" ] && . "$CONF"

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

main() {
    mkdir -p "$DATADIR"
    log "=== 进程守护 v2.0 启动 ==="

    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do sleep 5; done
    log "系统就绪"

    local last_list=""
    local static_done=""
    while true; do
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
            for d in /proc/[0-9]*; do
                pid="${d#/proc/}"
                cname=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -n1)
                [ -n "$cname" ] || cname=$(cat "$d/comm" 2>/dev/null)
                [ -n "$cname" ] || continue
                if is_target "$cname"; then
                    harden "$pid" "$cname"
                fi
            done
        fi

        sleep "$POLL_INTERVAL"
    done
}

main
