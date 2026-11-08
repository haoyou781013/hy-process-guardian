#!/system/bin/sh
# 开机拉起守护
MODDIR="${0%/*}"
BIN="$MODDIR/system/bin/hy_guardian.sh"
DATADIR="/data/adb/hy_guardian"
LOG="/data/local/tmp/hy_guardian.log"
PIDF="/data/local/tmp/hy_guardian.pid"

# 首次安装：种下默认白名单与配置（已存在则不覆盖）
mkdir -p "$DATADIR"
[ -f "$DATADIR/list.conf" ] || cp -f "$MODDIR/list.conf.default" "$DATADIR/list.conf" 2>/dev/null
[ -f "$DATADIR/guard.conf" ] || cp -f "$MODDIR/guard.conf.default" "$DATADIR/guard.conf" 2>/dev/null
chmod 644 "$DATADIR/list.conf" "$DATADIR/guard.conf" 2>/dev/null

# 清理旧实例
if [ -f "$PIDF" ]; then
    oldpid=$(cat "$PIDF" 2>/dev/null)
    [ -n "$oldpid" ] && kill -9 "$oldpid" 2>/dev/null
    rm -f "$PIDF"
fi

sleep 20

sh -c "exec sh '$BIN' </dev/null >/dev/null 2>&1" &
echo $! > "$PIDF"

echo "[$(date '+%m-%d %H:%M:%S')] service.sh 拉起 pid=$(cat "$PIDF" 2>/dev/null)" >> "$LOG"
