#!/system/bin/sh
kill $(cat /data/local/tmp/hy_guardian.pid 2>/dev/null) 2>/dev/null
rm -f /data/local/tmp/hy_guardian.pid /data/local/tmp/hy_guardian.log
# 撤销 Doze 白名单
[ -f /data/adb/hy_guardian/list.conf ] && \
  for pkg in $(grep -v '^#' /data/adb/hy_guardian/list.conf); do
    dumpsys deviceidle whitelist -"$pkg" >/dev/null 2>&1
  done
rm -rf /data/adb/hy_guardian
