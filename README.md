# 进程守护 Process Guardian v2.2

**白名单式进程保护 + 内存清理**，抵御一加 / ColorOS 的后台杀进程。带 WebUI，可直接从应用列表勾选。

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

## 内存清理

WebUI 顶部有内存面板（可用 / 已用 / 页缓存 / Swap / 进程数），
下面是三级清理：

| 级别 | 做什么 | 实测效果（10.9 GB 机型） |
|---|---|---|
| **轻度** | `sync` + `drop_caches` 清页缓存 | 缓存 2.23 → 1.24 GB |
| **标准** | 轻度 + `am kill-all` 回收后台 | 可用 3.79 → 4.07 GB，后台进程 54 → 0 |
| **深度** | 标准 + 三轮 `drop_caches` 叠加 | 再 +164 MB |

**清理不会杀掉白名单里的应用。** 白名单进程因为 `oom_score_adj=-1000`
本身就是系统最后才会动的对象，`am kill-all` 也不会碰它们。

### 为什么"深度"不杀进程

早期版本试过用 `kill -9` 终止第三方后台进程，**实测证伪**：

```
杀 5 个进程后：l3_freed_mb=-12     ← 可用内存反而降了
杀 12 个进程后：freed_mb=-228       ← 降得更多
```

原因：进程被杀后其物理页立刻被系统复用（缓存、页表重建、进程重启），
`MemAvailable` 几乎不会增加，还带来误杀风险。

真正有效的只有 `drop_caches`（释放页缓存）和 `am kill-all`（回收 cached 空进程）。

### 自动清理

WebUI 里打开「可用低于阈值时自动清理」，设定阈值（500~4000 MB）与级别，
守护进程每 60 秒检查一次。日志在 `/data/local/tmp/hy_guardian.log`。

实测：阈值 6000 MB、可用 3991 MB 时触发标准清理，释放 340 MB。

### 命令行

```bash
M=/data/adb/modules/hy_process_guardian/system/bin/hy_guardian.sh

sh $M mem_stat          # 内存状态（键值行，供 WebUI 解析）
sh $M mem_clean 1       # 轻度
sh $M mem_clean 2       # 标准
sh $M mem_clean 3       # 深度
```

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

# 内存清理
MEM_AUTO_CLEAN="0"        # 1=开启自动清理
MEM_MIN_AVAIL_MB="1500"   # 低于此值触发
MEM_CLEAN_LEVEL="2"       # 1=轻度 2=标准 3=深度
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

4. **扫描开销**
   已优化到单轮约 60 ms（941 进程）。原实现逐个 fork 子进程需 1159 ms，
   会让 1 秒轮询实际变成 15 秒一轮 —— v2.2 已修复。
   进程数特别多、或设备较弱时，可把扫描间隔调到 5~10 秒。

## 卸载

```bash
touch /data/adb/modules/hy_process_guardian/remove
# 重启
```

`uninstall.sh` 会自动撤销 Doze 白名单并清理 `/data/adb/hy_guardian/`。
