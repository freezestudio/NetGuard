# VM 实验室

本目录是 NetGuard 的 Hyper-V 实验室资料，位于仓库的 `infra/vms`：

```text
infra\vms\
├─ README.md              三台 VM 的说明、登录、快照、启动器
├─ docs\                  搭建记录、新手教程、日常配置
├─ launch\                单 VM 启动器 / RDP 剪贴板脚本
├─ Win7-Pro-x64\          Win7 SP1 磁盘（git 忽略）
├─ Win10-Pro-22H2\        Win10 22H2 磁盘（git 忽略）
├─ Win11-Test\            Win11 24H2 磁盘（git 忽略）
└─ iso-rebuild\           安装 ISO/应答文件/构建脚本（ISO 忽略）
```

- 虚拟机磁盘、ISO、截图、日志默认不入库；文档和脚本入库。
- 重建虚拟机：见 `vms/docs/01-搭建过程记录.md` 与 `vms/docs/02-新手教程.md`。

日常入口（双击 `infra\vms` 下的启动器）：

```text
infra\vms\启动Win10.cmd
infra\vms\启动Win7.cmd
infra\vms\启动Win11.cmd
```
