# 进程守护 Process Guardian v2.0

**白名单式进程保护**，抵御一加 / ColorOS 的后台杀进程。带 WebUI，可直接从应用列表勾选。

---

## 为什么需要

一加（ColorOS 16）有**四层**杀后台机制，逐层加重：

| 层 | 机制 | 本机证据 | 表现 |
|---|---|---|---|
| ① | **freeze** | `/sys/fs/cgroup/.../cgroup.freeze` | 进程冻结，等同假死 |
| ② | **suspend** | `persist.oplus.theia.enable_suspend_resume_monitor=true` | 线程全挂起，比 freeze 更彻底 |
| ③ | **kill** | `oplus.lmkd_super_critical_threshold_12g=800`<br>`persist.sys.lmk.oplus.kill_memleak_process=1` | 进程彻底消失 |
| ④ | **force-stop** | framework 层 | 手动/一键清理，**无法拦截** |

主控是 `com.oplus.athena`（含 `RemoteGuardElfService`），
配合 `com.oplus.powermonitor` 与 `oplus_suspend_resume_monitors`。

**普通前台服务挡不住这些** —— 前台服务只决定 `oom_score_adj` 的**初始值**，
之后系统仍会按内存压力上调。

## 内存现实（本机实测）

```
MemTotal     10.9 GB
SwapTotal    12.0 GB  (zram)
MemAvailable  2.1 GB   ← 仅剩这些
```

FCL 这类 Minecraft 启动器单进程 3-4 GB，**缺口 1-2 GB，必然触发 lmkd**。
只调 `oom_score_adj` 不能解决内存缺口，但能让它**排在最后被杀**。

## 它做什么

对白名单里每个包的**所有进程**（含 `:remote` 子进程）循环执行：

```
① oom_score_adj = -1000      劝退 lmkd（本机内核接受 -1000，已实测）
② cgroup.freeze = 0          解冻
③ dumpsys deviceidle whitelist +pkg     防 Doze
④ cmd appops set ... allow   后台/唤醒/前台服务放行
```

**为什么必须循环**：系统每次进程重建、迁移 cgroup、内存调度都会**重写**
`oom_score_adj`，一次性设置无效。默认 1 秒一次。

## 安装

```bash
cp -r "/sdcard/Android/haoyou781/13-进程守护" /data/adb/modules/hy_process_guardian
chmod -R 755 /data/adb/modules/hy_process_guardian
# 重启，或在 KernelSU 里启用模块
```

首次启动会把 `list.conf.default` / `guard.conf.default` 种到 `/data/adb/hy_guardian/`。

## 使用 WebUI

KernelSU 管理器 → 模块 → 进程守护 → **打开**。

界面提供：
- **应用列表勾选**（自动列出全部第三方应用，可搜索）
- **oom_score_adj 滑块**（-1000 ~ 0）
- **扫描间隔滑块**（1~30 秒）
- **解冻 / Doze / appops 开关**
- **实时状态**（每个目标的 pid、当前 adj、冻结状态）

## 手工配置

```bash
# 白名单
/data/adb/hy_guardian/list.conf        每行一个包名

# 参数
/data/adb/hy_guardian/guard.conf
OOM_ADJ="-1000"
POLL_INTERVAL="1"
ENABLE_FREEZE_THAW="1"
ENABLE_CGROUP_MOVE="1"
ENABLE_DOZE="1"
ENABLE_APPOPS="1"
```

改完等 1 秒自动生效（守护进程每秒重读名单）。

## 验证

```bash
# 守护是否在跑
cat /data/local/tmp/hy_guardian.pid

# 目标进程的实际加固值
pid=$(pidof com.tungsten.fcl)
cat /proc/$pid/oom_score_adj          # 应为 -1000
cat /proc/$pid/cgroup | grep freezer  # 看 freezer 路径
```

或在 WebUI 的「运行状态」卡片里直接看。

## 局限（必须知道）

1. **拦不住 force-stop**
   设置里点「强行停止」、或 ROM 一键清理调 `am force-stop`，那是 framework
   直接发信号，**任何 root 模块都拦不住**。

2. **`-1000` 有风险**
   等于告诉内核「绝不杀它」。若目标内存爆到系统真撑不住，可能触发**整机 OOM**
   而不是杀掉它。内存紧张的机器建议 `-900`。

3. **suspend 只能降低概率**
   `oplus_suspend_resume_monitors` 是独立机制，`cgroup.freeze` 拦不住它。
   appops 放行能减少触发，但不是根治。

4. **每 1 秒扫 /proc 有开销**
   进程多（>800）时可见。日常应用可以调到 10~15 秒。

## 卸载

```bash
touch /data/adb/modules/hy_process_guardian/remove
# 重启
```

`uninstall.sh` 会自动撤销 Doze 白名单并清理 `/data/adb/hy_guardian/`。
