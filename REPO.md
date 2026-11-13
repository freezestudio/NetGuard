# 仓库整合说明（本机）

本项目已整合到：

```text
C:\Users\freez\source\repo
```

## 一、目录

```text
repo\
├─ README.md               NetGuard 项目说明
├─ src\ drv\ lab\ docs\    源码、驱动、测试脚本、文档
├─ install-netguard.ps1    安装（-InstallDriver / -FreeMode）
├─ uninstall-netguard.ps1  卸载
├─ free-mode.ps1           免费模式（防火墙出站白名单）
└─ infra\
   ├─ README.md            VM 实验室说明
   └─ vms\                原 C:\VMs 的全部内容（文档 + 虚拟机磁盘）
```

## 二、兼容联接

为避免破坏 Hyper-V 配置和旧脚本，以下目录是 **junction（目录联接）**：

| 旧路径 | 实际位置 |
|---|---|
| `C:\VMs` | `C:\Users\freez\source\repo\infra\vms` |
| `C:\src\NetGuard` | `C:\Users\freez\source\repo`（重启后自动创建） |

Hyper-V 的虚拟机配置仍写 `C:\VMs\...`，通过联接解析到仓库内，**不需要改 VM 配置**。

## 三、哪些内容不进 Git

`infra\vms` 里的虚拟机磁盘/ISO 体积约 60 GB，已在 `.gitignore` 中排除：

- `*.vhdx` / `*.avhdx` / `*.vhd`
- `*.iso` / `*.vfd`
- `build/` / `dist/` / `drv/out/` 与二进制
- 大部分运行日志/截图（保留 4 份关键回归日志）

从 GitHub 克隆后不会包含虚拟机镜像；需要时按 `infra/vms/docs` 重建。

## 四、重启后

登录后 `C:\src\NetGuard` 会自动变成指向本仓库的联接（RunOnce：
`post-reboot-consolidate.ps1`，日志见 `infra\post-reboot.log`）。

```powershell
cd C:\Users\freez\source\repo
git status
git log --oneline -5
```

## 五、远程仓库

本机 `git` 已配置，且 **GitHub SSH 已验证通过**（`freezestudio`）：

```text
ssh -T git@github.com  ->  Hi freezestudio! You've successfully authenticated...
```

远端已设为（仓库尚未在 GitHub 上创建）：

```text
origin  git@github.com:freezestudio/NetGuard.git
```

下一步：

1. 在 github.com 新建**空仓库** `freezestudio/NetGuard`（不要勾选初始化 README）。
2. 在仓库目录执行：

```powershell
cd C:\Users\freez\source\repo
git push -u origin main
```

之后日常：

```powershell
git status
git add -A
git commit -m "说明"
git push
```

> 本机未安装 `gh`（当前网络无法下载 GitHub Release）；SSH 推送不依赖 `gh`。
> 如需 `gh`，网络恢复后执行 `winget install --id GitHub.cli -e` 或从官网下载 MSI。
