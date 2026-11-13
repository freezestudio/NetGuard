# 驱动开发虚拟机（Win7 + Win10 22H2 + Win11 24H2）

> 本目录就是全部内容。日常只需要看本文档。

---

## 一、三台虚拟机

| | **Win7-Pro-x64** | **Win10-Pro-22H2** | **Win11-Test** |
|---|---|---|---|
| 系统 | Windows 7 专业版 SP1（7601） | Windows 10 专业版 **22H2**（10.0.19045.6456） | Windows 11 企业版评估版 **24H2**（10.0.26100） |
| 虚拟机代数 | Gen 1（BIOS） | Gen 2（UEFI，Secure Boot 关） | Gen 2（UEFI + vTPM，**Secure Boot 关**） |
| vCPU / 内存 | 2 核 / 3 GB（固定） | 4 核 / 6 GB（动态 3–8 GB） | 4 核 / 6 GB（固定） |
| 磁盘 | 60 GB 动态 VHDX | 80 GB 动态 VHDX | 80 GB 动态 VHDX |
| 网卡 | Legacy 网卡（DEC 21140）+ NAT | 合成网卡 + NAT | 合成网卡 + NAT |
| 客户机 IP | 固定 `172.20.192.50/20`（2026-11-13 配置；网关 `172.20.192.1`） | 固定 `172.20.192.51/20`（2026-11-13 配置；网关 `172.20.192.1`） | DHCP（Default Switch，约 `172.20.192.x`） |
| 登录账户 | `freeze` / `1`（本地管理员，**已配置自动登录**） | `freeze` / `1`（本地管理员，**已配置自动登录**） | `freeze` / `1`（本地管理员，**已配置自动登录**） |
| 远程桌面 | 已开通 3389（NLA 关闭，便于 Win7 客户端） | 已开通 3389 | 未开通 3389（用 **PowerShell Direct** 自动化） |
| 剪贴板 | **RDP 剪贴板重定向**（Win7 不支持增强会话） | **增强会话** 或 RDP 剪贴板（两种都已配置） | VMConnect 增强会话（需客户机内开启） |
| 测试签名 | 已开（`testsigning on` + `nointegritychecks`） | 已开（`testsigning on`） | 已开（`testsigning on` + `nointegritychecks`） |
| 内核调试 | 已开（串口 COM1 → 命名管道 `\\.\pipe\win7dbg`） | 已开（串口 COM1 → 命名管道 `\\.\pipe\win10dbg`） | 未配置 |
| 补丁状态 | KB3020369 / KB4490628 / KB4474419(SHA-2) / KB3125574(便利汇总) / KB3140245(TLS1.2) 全部安装，TLS 1.2 已启用 | 出厂 22H2 自带累积更新 | 24H2 评估版（约 90 天有效期，到期需更换/授权） |

> **Win11-Test 的定位**：验证 NetGuard 驱动在 Win11 24H2 上的兼容性（安装/拦截/卸载）。
> 因为它需要加载测试签名驱动，所以 **Secure Boot 关闭**、`testsigning on`，
> 且 Device Guard / VBS 状态为 0（未启用 HVCI）。这**不等于**生产环境验证：
> 生产环境需要在 Secure Boot 开启 + HVCI 开启、驱动有 EV/WHQL 正式签名时再回归一次。

## 二、日常使用（推荐）

### A. 只需要控制台（VMConnect）

1. 双击 **`启动Win10.cmd`**、**`启动Win7.cmd`** 或 **`启动Win11.cmd`**
   - 自动开机并只弹 **一个** VMConnect 窗口，**不需要 UAC**
   - 会自动登录 `freeze`（密码 `1`），正常情况下不需要再输密码
   - 启动器会先把**其它虚拟机保存/关闭**，并关闭已有的 VMConnect/RDP 窗口，
     保证“同一时间只运行一台、只保留一个连接”
2. 用完在虚拟机内部用 Windows 自己的「关机」关闭（不要在宿主强杀）
3. 搞坏了就回滚快照（见下文）

> `启动Win11.cmd` 直接调用 `infra\vms\launch\start-win11.ps1`（Hyper-V 管理员权限）。
> 之前尝试创建 `VM-Start-Win11` 计划任务时因宿主账户密码未知而失败，已放弃计划任务方案，
> 直接双击即可。**注意：不存在 `VM-Start-Win11` 计划任务。**

### B. 需要和宿主机共享剪贴板

- **Win10**：双击 **`连接Win10-剪贴板.cmd`**（RDP，剪贴板已启用）。
  也可以直接用 `启动Win10.cmd` 进入增强会话（Enhanced Session），
  VMConnect 的增强会话默认支持剪贴板。
- **Win7**：双击 **`连接Win7-剪贴板.cmd`**（RDP，剪贴板已启用）。
  Win7 **不支持** Hyper-V 增强会话，所以剪贴板必须走 RDP；
  首次连接如果弹出“未知发布者/证书”安全警告，请勾选 **剪贴板** 后点“连接”。
- 两个剪贴板启动器都会先确保只开目标这一台，并关闭旧的 VMConnect/RDP 窗口。
- 首次连接可能要求确认远程计算机证书：勾选“不再询问”并点“是”即可，之后不再提示。
- **Win11**：没有专门的 RDP 剪贴板启动器；用 `启动Win11.cmd` 进 VMConnect，
  客户机内已启用增强会话时剪贴板可用（未验证项，当前主要用途是驱动测试）。

> 内存只有 16 GB：**一次只开一台**（Win10/Win11 各 6 GB，Win7 3 GB，同时开会把宿主挤爆）。
> 启动器已经强制单 VM；请不要手工 `Start-VM` 另一台。

## 三、快照（最重要的保命手段）

每台都留有基线快照：

| 虚拟机 | 可用快照 | 含义 |
|---|---|---|
| Win7-Pro-x64 | `patched` | 补丁打完的干净基线 |
| Win10-Pro-22H2 | `clean-testsigning` | 22H2 干净基线 |
| Win11-Test | `clean-win11-testsigning` | 24H2 + 测试签名已开 + 无 NetGuard 的干净基线 |

回滚方法（任选其一）：

- **Hyper-V 管理器**（`virtmgmt.msc`）→ 选中虚拟机 → 检查点 → 右键目标快照 → **应用**（Apply）
- 命令行（管理员 PowerShell）：`Restore-VMSnapshot -VMName 'Win11-Test' -Name 'clean-win11-testsigning' -Confirm:$false`

新建快照（改注册表/装驱动前先做）：
```powershell
Checkpoint-VM -VMName 'Win10-Pro-22H2' -SnapshotName ('before-' + (Get-Date -Format 'MMdd-HHmm'))
```

⚠️ 快照会生成 `*.avhdx` 链，层数多了会变慢。定期在 Hyper-V 管理器里删除多余快照即可（会自动合并）。

## 四、连接内核调试器

```powershell
# 先开虚拟机、再连调试器（或反过来，调试器会等待 reconnect）
windbg -k com:pipe,port=\\.\pipe\win10dbg,resets=0,reconnect
windbg -k com:pipe,port=\\.\pipe\win7dbg,resets=0,reconnect
```
Windows 10 还支持网络调试（KDNET），但串口管道更省事，Win7/Win10 保持一致。

WinDbg 没装的话：`winget install Microsoft.WinDbg`（商店版，命令名 `windbgx`）。

## 五、目录结构

```
infra\vms\
├─ README.md                    ← 本文档
├─ 启动Win10.cmd / 启动Win7.cmd / 启动Win11.cmd  ← 控制台入口（单 VM + 单 VMConnect）
├─ 连接Win10-剪贴板.cmd          ← RDP 入口（剪贴板）
├─ 连接Win7-剪贴板.cmd           ← RDP 入口（剪贴板）
├─ docs\
│   ├─ 01-搭建过程记录.md        ← 这次的完整过程、踩坑与解法
│   ├─ 02-新手教程.md            ← 从零开始的保姆级教程
│   └─ 03-日常配置.md            ← 自动登录 / 剪贴板 / 单 VM 配置说明
├─ launch\
│   ├─ vm-common.ps1             ← 单 VM + 单连接公共逻辑
│   ├─ start-win10.ps1 / start-win7.ps1 / start-win11.ps1
│   ├─ connect-rdp.ps1           ← RDP 剪贴板启动器
│   ├─ accept-rdp.ps1            ← 自动勾选剪贴板并点“连接”
│   ├─ configure-vms.ps1         ← 一键重新配置（管理员）
│   └─ launcher.log              ← 启动器日志
├─ Win10-Pro-22H2\disk.vhdx     ← 虚拟机磁盘（不要手工删改）
├─ Win7-Pro-x64\disk.vhdx
└─ Win11-Test\disk.vhdx         ← Win11 24H2（评估版，含 vTPM）
```

## 六、本次配置汇总（2026-11-13）

### 1. 自动登录（三台都已配置）

| 项目 | Win7 | Win10 | Win11 |
|---|---|---|---|
| 账户 | `freeze` / `1`（本地管理员） | `freeze` / `1`（本地管理员） | `freeze` / `1`（本地管理员） |
| 自动登录 | `AutoAdminLogon=1`、`DefaultPassword=1`、`ForceAutoLogon=1` | 同上，`DefaultDomainName=DESKTOP-D7QNE9M` | 安装时由 `autounattend.xml` 写入，`LogonCount=999` |
| 附加 | `EnableLUA=0`、`DisableCAD=1` | `DisableCAD=1` | OOBE 已跳过联网账户，纯本地账户 |

注册表位置（客户机内）：

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon
  AutoAdminLogon   = 1
  DefaultUserName  = freeze
  DefaultPassword  = 1
  DefaultDomainName= <计算机名>
  ForceAutoLogon   = 1
```

> 如果以后改了 `freeze` 的密码，记得同步改这里的 `DefaultPassword`，否则会自动登录失败。

### 2. 固定 IP（Default Switch NAT）

| 虚拟机 | IP | 掩码 | 网关 | DNS |
|---|---|---|---|---|
| Win7-Pro-x64 | `172.20.192.50` | `255.255.240.0`（/20） | `172.20.192.1` | `8.8.8.8` |
| Win10-Pro-22H2 | `172.20.192.51` | `255.255.240.0`（/20） | `172.20.192.1` | `8.8.8.8` |
| Win11-Test | DHCP（不固定） | — | `172.20.192.1` | 自动 |

> 这些地址依赖宿主 `vEthernet (Default Switch)` 的 `172.20.192.1/20` 网段。
> 如果宿主重置了 Default Switch 网段，需要改
> `infra\vms\launch\configure-vms.ps1` 里的地址，并重新运行一次配置。

### 3. 剪贴板

- **Win10**：宿主机已开启 Hyper-V 增强会话（`EnableEnhancedSessionMode=True`）。
  - 方式 A：`启动Win10.cmd` → VMConnect 增强会话（默认支持剪贴板）。
  - 方式 B：`连接Win10-剪贴板.cmd` → RDP，`.rdp` 文件里 `redirectclipboard:i:1`。
- **Win7**：Hyper-V 增强会话不支持 Win7，使用 **RDP**。
  - `连接Win7-剪贴板.cmd` → `mstsc` + `redirectclipboard:i:1`。
  - `launch\accept-rdp.ps1` 会自动在安全警告里勾选 **剪贴板** 并点 **连接**。
- 凭据已用 `cmdkey` 保存为 `TERMSRV/172.20.192.50`、`TERMSRV/172.20.192.51`，正常不需要再输密码。
- 已验证两个 RDP 入口都能连上（`rdp-Win7 - 172.20.192.50`、`rdp-Win10 - 172.20.192.51`）。

### 4. 单 VM / 单连接规则

`infra\vms\launch\vm-common.ps1` 是公共逻辑，`启动Win7.cmd`、`启动Win10.cmd`、`启动Win11.cmd`、
`连接Win7-剪贴板.cmd`、`连接Win10-剪贴板.cmd` 都走它：

1. 先关闭所有已有的 `vmconnect.exe` / `mstsc.exe` 窗口；
2. 把**其它所有**虚拟机 `Stop-VM -Save`（保存状态；失败才强制关机）；
3. 启动目标虚拟机；
4. 只打开**一个**连接窗口（VMConnect 或 RDP）。

日志：`infra\vms\launch\launcher.log`。

### 5. Win11-Test 专项说明

| 项目 | 值 |
|---|---|
| 镜像 | `Win11-EnterpriseEval-24H2-unattend.iso`（微软官方评估版 + `autounattend.xml`） |
| 版本 | Windows 11 Enterprise Evaluation 24H2，`10.0.26100` |
| 硬件 | Gen 2、4 vCPU、6 GB 固定内存、80 GB VHDX、vTPM、合成网卡 |
| Secure Boot | **关**（为了加载测试签名驱动；vTPM 模板已锁定，只能在关机状态切换 Secure Boot 开关） |
| 测试签名 | `testsigning Yes`、`nointegritychecks Yes` |
| Device Guard / VBS | `VirtualizationBasedSecurityStatus = 0`（**未启用 HVCI**） |
| 远程管理 | **PowerShell Direct**（`New-PSSession -VMName 'Win11-Test'`），未开 RDP |
| 快照 | `clean-win11-testsigning` |
| 启动器 | `infra\vms\启动Win11.cmd` → `infra\vms\launch\start-win11.ps1` |

已验证：

- 安装 `install-netguard.ps1 -InstallDriver` → NetGuard 服务与 `ngdrv` 驱动均 `Running`；
- 驱动拦截：正确哈希的程序只放行指定目标，换目标被拦（`curl exit=7`），篡改二进制被拦；
- 卸载 `uninstall-netguard.ps1` → 服务/驱动/过滤规则全部移除，网络恢复；
- `lab\installer-driver-test.ps1 -VmName 'Win11-Test'`：**22/22 全通过**，
  日志 `lab\win11-installer-driver-test.log`。

⚠️ 局限：当前 Win11 是 **Secure Boot 关 + 测试签名** 状态，只能证明驱动功能兼容，
**不能**证明“开启 HVCI/Secure Boot 的生产环境”可用；后者需要 EV/WHQL 正式签名后再测。
评估版约 90 天到期，到期前需更换正式授权或重建。

### 6. 重新配置 / 排障

- 重新运行配置脚本（需要管理员；会停止所有 VM、改注册表/静态 IP/RDP 防火墙，然后重启验证）：
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File infra\vms\launch\configure-vms.ps1
  ```
- 检查 RDP：
  ```powershell
  Test-NetConnection 172.20.192.50 -Port 3389
  Test-NetConnection 172.20.192.51 -Port 3389
  ```
- 检查 VM 状态 / 邻居表：
  ```powershell
  Get-VM | Select Name,State
  Get-NetNeighbor -InterfaceAlias 'vEthernet (Default Switch)' |
    Where-Object IPAddress -like '172.20.*'
  ```
- 如果 RDP 提示“已与远程计算机建立了另一个连接”：说明客户机控制台还在自动登录/恢复中，
  等 30–60 秒再运行 `连接Win7-剪贴板.cmd`；启动器会等待 3389。
- 如果客户机桌面没有任务栏：这是 Win7 客户机内 Explorer 的状态问题，与剪贴板配置无关；
  重新登录/重启客户机即可。RDP 仍可连接。
- Win11 自动化：`New-PSSession -VMName 'Win11-Test' -Credential (Get-Credential freeze)`
  需要客户机内 `vmicvmsession` 服务正常，且宿主机以管理员运行。

## 七、注意事项

1. **不要用资源管理器删除/移动 VHDX、avhdx**，会毁掉虚拟机和快照链。
2. **不要同时开多台**（内存不够；启动器已强制单 VM）。
3. 宿主不要改 `Default Switch` 的网段，客户机 NAT 依赖它。
4. Win7 没装集成服务，所以宿主看不到它的 IP；用 VMConnect 窗口里 `ipconfig` 查。
5. 三台都已开 `testsigning`，装**未签名/测试签名**驱动可直接加载；装正式签名驱动也没问题。
6. Win11 的 Secure Boot 只能在虚拟机关机时切换；启用过 vTPM 后安全启动模板 ID 锁定，不能再改模板。
7. Win11 是评估版，约 90 天到期；到期后需更换授权或重建虚拟机。
8. 需要其它系统（Server 2022、Ubuntu 等）时，另建虚拟机即可，Hyper-V 已启用。
