# 更新日志

## v2.1 — 2026-11-08

### 修复
- **WebUI 无法执行命令**：原用 `cgi-bin/*.sh` + `fetch` 的方案完全不可行 ——
  KernelSU 的 WebUI 基于 `WebViewAssetLoader`（静态文件服务），
  不会执行任何脚本，页面直接把 shell 脚本当文本渲染出来了。
  改用 `kernelsu-alt` 的 JS 桥（`ksu.exec`），整份内联免打包。

### 新增
- **应用列表带显示名**：用 `ksu.getPackagesInfo` 拿到应用中文名，
  不再只显示包名末段。
- **实时状态面板**：显示每个受保护进程的 pid、当前 `oom_score_adj`、冻结状态。
- **模块自动更新**：`update.json` 支持 KernelSU 管理器一键更新。

### 改进
- 扫描间隔默认 1 秒（原 5 秒）。实测系统会把 `oom_score_adj`
  从 `-1000` 抬到 `900`，5 秒周期太慢，1 秒才能覆盖。

## v2.0 — 2026-11-08

### 新增
- 白名单机制：`/data/adb/hy_guardian/list.conf`，每行一个包名
- 多层防护：`oom_score_adj` + cgroup 解冻 + Doze 白名单 + appops 放行
- WebUI（后续证明该版实现有误，见 v2.1）

## v1.0 — 2026-11-08

### 新增
- 初版：单目标 `oom_score_adj` 守护
