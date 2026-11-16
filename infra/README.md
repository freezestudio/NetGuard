# VM 实验室

Hyper-V 实验室的**全部内容（虚拟机磁盘 + ISO + 搭建设计文档 + 启动脚本）已整体移出仓库，位于 `C:\VMs`**。
仓库里已不再包含 `infra\vms` 目录，不再入库（git 历史里仍可查到 2026-11-13 之前的版本）。

```text
C:\VMs\
├─ README.md              三台 VM 的说明、登录、快照、启动器（先看这个）
├─ docs\                  01-搭建过程记录 / 02-新手教程 / 03-日常配置
├─ launch\                单 VM 启动器 / RDP 剪贴板脚本 / configure-vms.ps1
├─ Win7-Pro-x64\          Win7 SP1 磁盘（60 GB 动态 VHDX）
├─ Win10-Pro-22H2\        Win10 22H2 磁盘（80 GB）+ 检查点 avhdx
├─ Win11-Test\            Win11 24H2 磁盘（80 GB）+ 检查点 avhdx
└─ iso-rebuild\           安装 ISO / 应答文件 / 构建脚本
```

- 三台 VM 已注册在 Hyper-V 中，磁盘路径已指向 `C:\VMs\<VM名>\`；
  虚拟机**配置 XML / 检查点元数据**仍在 Hyper-V 标准位置
  `C:\ProgramData\Microsoft\Windows\Hyper-V`（未迁移，改动需管理员）。
- 日常入口（双击 `C:\VMs` 下的启动器）：

```text
C:\VMs\启动Win10.cmd
C:\VMs\启动Win7.cmd
C:\VMs\启动Win11.cmd
```

- 启动器内部用 `%~dp0` / `$PSScriptRoot` 定位，整个 `C:\VMs` 目录可以随意搬家（搬完记得重指虚拟磁盘路径）。
- 重建虚拟机：见 `C:\VMs\docs\01-搭建过程记录.md` 与 `C:\VMs\docs\02-新手教程.md`。
