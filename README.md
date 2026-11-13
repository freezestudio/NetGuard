# NetGuard — 药店终端出网白名单

> 目标：**默认拒绝一切出网流量，只放行「指定程序 → 指定业务地址:端口」**。
> 纯 C/C++ + Win32（无需 .NET、无需内核驱动），支持 Windows 7 / 10 / 11。
>
> 📖 **第一次部署请先看图文教程：[docs/新手教程.md](docs/新手教程.md)**（Win7 实机逐步截图）
> · PDF 版：[docs/新手教程.pdf](docs/新手教程.pdf)
>
> 🧪 **2026-11-13 实测报告（Win7 + Win10 + Win11 核心目标 / 残余风险）**：
> [docs/实测报告-2026-11-13.md](docs/实测报告-2026-11-13.md)
>
> 🆓 **免费模式（无驱动 / 无证书）**：[docs/免费模式.md](docs/免费模式.md)
> —— Windows 防火墙出站白名单 + 程序目录 ACL，Win10/Win11 回归均 **22/22**。
>
> 🖥 **平台覆盖**：Win7 SP1 x64 / Win10 22H2 / Win11 24H2 用户态与驱动均已实测；
> Win11 驱动安装+拦截+卸载回归 **22/22**（`lab/win11-installer-driver-test.log`）。
> Win11 测试环境为 Secure Boot 关 + testsigning，生产需正式签名后再回归。
>
> 🛠 当前源码构建为**开发版**：`src/ng_trial.h` 中 `NG_TRIAL_ENABLED=0`，60 天试用门禁已临时关闭；
> 发布前改回 `1` 并重新构建。`NetGuard.exe trial` 会显示“试用门禁已临时禁用”。
>
> ⏳ 历史交付包为 **60 天试用版**：`NetGuard.exe trial` 查看剩余天数；到期后服务自动撤销管控并恢复联网。

---

## 一、为什么这样做

| 需求 | 机制 |
|---|---|
| 彻底断网，只放行业务 | WFP（Windows Filtering Platform）**ALE_AUTH_CONNECT** 层：默认 BLOCK + 白名单 PERMIT |
| 员工不能私自解除 | 员工是标准用户改不动；策略由 **SYSTEM 服务**持有会话，进程一停过滤器失效（失败即安全） |
| 木马不能借医保专线打服务器 | 白名单是 **进程 × 地址 × 端口 × 协议** 四元绑定，换一个进程访问同一地址照样被拦 |
| 专线与外网共用网卡 | 纯 L3/L4 目的地址过滤；放行 DHCP(68→67) 与回环，其余全拒 |
| 可审计/可检查 | 生效过滤器清单 `filters.txt` + `ng.log` + `NetGuard test` 自检报告 |
| 需要临时放行（更新程序） | `NetGuard temp 60` → 关闭默认拒绝 1 小时，到期后重新 `apply` |
| 不想买证书/装驱动 | **免费模式**：Windows 防火墙出站白名单 + 程序目录 ACL（见第五节） |

**关键实现点**

1. 会话级过滤器：服务常驻即等效持久化；进程退出 → 过滤器自动消失（不会留下"断网事故"）。
2. 白名单必须绑定进程（`FWPM_CONDITION_ALE_APP_ID` + 文件 SHA-256 校验）。
3. 默认拒绝必须覆盖 **IPv4 + IPv6** 两层，否则 IPv6 会绕过。
4. 放行 **127.0.0.0/8 + ::1**（本机 IPC）与 **UDP 68→67**（DHCP），否则机器拿不到地址、服务间通信断。
5. 策略必须带有效 **HMAC-SHA256**；密钥在首次安装时**随机生成**（升级保留）并存于
   `HKLM\SOFTWARE\NetGuard\PolicyKey`（键 DACL 仅 SYSTEM/Administrators）。
   服务与命令行对“密钥缺失/签名无效”一律拒绝下发（fail-closed）。
6. 网段/端口/协议格式校验失败时整条策略拒绝，**不会**静默降级成“全部端口”。
7. 看门狗不再只看内存计数：每 30 秒按 `filters.txt` 逐条查询实际过滤器，缺失即重建；
   期望条数取最近一次成功 apply 的结果（不再硬编码 4）。

---

## 二、当前状态（2026-11-11）

### 已验证（两个平台都跑通）

> 下表为 2026-11-11 已完成的历史实测数据（对应“5 条过滤器”版本）。
> 之后新增了 IPv6 回环 `::1` 放行，**典型过滤器数变为 6 条**（默认拒绝×2 + 回环×2 + DHCP + 业务）；
> 服务/CLI 的签名与格式校验也已改为 fail-closed，密钥改为每机随机（HKLM）；
> 下表历史数据对应“固定密钥、5 条过滤器”版本，相关回归见“本轮修复”。

| 项目 | Windows 10 22H2 | Windows 7 SP1 x64 |
|---|---|---|
| 默认拒绝 + 白名单下发 | ✅ 5 条过滤器 | ✅ 5 条过滤器 |
| 基线（未下发）能连外网 | ✅ leaked=2 | ✅ leaked=3（含局域网目标） |
| 应用后全部拦截 | ✅ 4/4 BLOCK，0ms 立即拒绝 | ✅ **5/5 BLOCK，0ms** |
| 回滚后恢复联网 | ✅ | ✅ 3 个目标恢复 CONNECTED |
| `NetGuard test` 退出码 | ✅ 0 (PASS) | ✅ 0 (PASS) |
| 服务开机自启并下发（无需用户登录） | — | ✅ `apply(service-start): ok, filters=5` + `selftest: leaked=0` |
| 审计清单 `filters.txt` | — | ✅ 5 条过滤器 ID |
| 管理界面结构自检 | ✅ 窗口+5列×2+3复选框+3输入框+状态栏 | （同一二进制） |
| **命名管道 IPC** | — | — |
| 服务 DACL 加固 | ✅ `sc sdset` 仅 SYSTEM/Administrators，普通用户无法启停 | |
| 失败自动重启 | ✅ 5s / 15s / 60s，重置 86400s | |
| 策略目录 ACL | ✅ SYSTEM+Administrators 完全控制，Users 仅只读 | |

### 平台差异（重要）

- **Win7 的 `FwpmSubLayerAdd0` 必须关联已注册的 provider**，否则返回 `ERROR_INVALID_FUNCTION`。
  Win10 不强制。代码已统一：先 `FwpmProviderAdd0`，再挂 `sub.providerKey`。
- 用户态**不能**创建持久化 sublayer（`FWPM_SUBLAYER_FLAG_PERSISTENT` 会失败）→ 只能做**会话级过滤器**，
  靠常驻服务持有会话达到"开机即生效"；服务停止 → 过滤器自动消失（失败即安全）。

### 本体验证明细（Win10 22H2 客户机，2026-11-11）

**IPC（命名管道 `\\.\pipe\NetGuardControl`）**
```
ctl apply    -> OK filters=5
ctl status   -> filters=5 / filters_live=5 / default_deny=1 / endpoints=1 / programs=1 / temp_until=0 / key_ok=1 / hmac_ok=1
ctl rollback -> OK rolled-back
```

**哈希锁定 + 防替换（核心需求 R5）**
```
biz.exe 哈希 = 369DF34B…FFE6        （与 PowerShell Get-FileHash 计算值完全一致）
ctl apply → OK filters=5
把 biz.exe 换成 notepad.exe 后（看门狗 30s 内）：
  ng.log   hash: 哈希不匹配（文件被替换？）C:\NetGuard\biz.exe
  audit    ALERT hash-changed expected=369D… actual=DA58…
  audit    ACTION revoked-mismatched-programs and re-sign policy
  ng.log   apply ok: 策略已生效，过滤器 4 条      ← 5→4，该程序白名单被撤
  policy   Enable=0（自动改写并重签名，hmac_ok=1）
```

**安装包**（`install-netguard.ps1` / `uninstall-netguard.ps1`）
```
服务 SDDL : D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)
失败动作 : restart/5s, restart/15s, restart/60s, reset=86400
数据目录 : SYSTEM/Administrators Full；Users ReadAndExecute（不可写）
卸载     : 先 ctl rollback 再删服务（不会留下"断网"状态）
```

### 本轮修掉的平台 bug

- **`FwpmSubLayerAdd0` 已存在时返回 `FWP_E_ALREADY_EXISTS (0x80320009)`**，而代码只把 `183` 当"已存在"
  → 第二次以后每次 apply 都失败。已改为三者都算成功。
- **`BCryptCreateHash` 的哈希对象缓冲区必须与句柄同生命周期**；之前放在块作用域里提前释放，
  导致 `BCryptHashData` 返回 `0xC0000008 (STATUS_INVALID_HANDLE)`，`hash` 命令对所有文件都失败。
- 客户机内运行 .ps1 仍需 **UTF-8 BOM**（PowerShell 5.1 按 GBK 解析）。

### 本轮修复（2026-11-11 后续）

- **UI 口令对话框**：补上遗漏的 `g_pIn` 赋值；回车/Esc 显式映射到确定/取消，
  已用测试程序实测“输入 + 回车 → IDOK → 读取口令”成功。
- **部署级随机密钥**：首次安装或密钥缺失时生成 32 字节随机密钥，存
  `HKLM\SOFTWARE\NetGuard\PolicyKey`，键 DACL 收紧为仅 SYSTEM/Administrators；
  升级/重装保留密钥（轮换见“使用”中的 reg delete + sign）。普通用户无法预置或读取密钥。
- **策略签名 fail-closed**：服务、`apply/test/verify`、IPC `temp` 对“密钥缺失/签名无效”一律拒绝；
  新增 `initkey`（生成/检查密钥）与 `sign`（迁移旧策略）；安装脚本在停服务前先 `initkey` + `verify`。
- **字段格式 fail-closed**：CIDR/端口/协议/程序绑定地址非法时整条策略拒绝，
  不再把错误端口静默解释成 `0-65535`。
- **IPv6 回环**：新增 `::1/128` 放行，避免默认拒绝 V6 后误伤 `localhost`。
- **看门狗实测**：按 `filters.txt` 逐条查询实际过滤器；期望值取最近一次成功 apply 的条数，
  并修正“关闭默认拒绝后计数未归零”的问题。
- **CLI**：`temp` 真正执行放行（不再反过来下发拒绝）；`status` 查询实际生效条数。
- **并发保护**：服务内 WFP 操作加互斥锁，避免看门狗与 IPC 同时开启事务。
- **加固**：`admin.dat` 仅 SYSTEM/Administrators 可读写；UI 嵌入 UAC 清单（双击自动提权）
  与 comctl32 v6；安装脚本增加 `install.log` 与失败时尽量拉起服务的恢复逻辑；新增 `sign-build.ps1`。
- **失败回滚清单**：apply/rollback 事务失败时恢复 `filters.txt` 旧 ID，避免“过滤器仍在但清单丢失”。
- **lab 回归适配**：新增 `lab/ng-lab-common.ps1`；PS Direct 脚本在部署策略后自动 `sign`；
  Win7 离线脚本用随机离线密钥签名（`sign --key`）或登录时 `sign`。

### 2026-11-12 真实 OS 回归（提权后实测）

| 环境 | 结果 |
|---|---|
| **Win10 22H2 客户机** | 全新安装：随机密钥生成、`service-start filters=6`、`key_ok=1 / hmac_ok=1`；基线 3 个目标可连 → apply 后 **5/5 目标 0ms 拦截** → rollback 后 3 个恢复；哈希替换 **6→5**、`Enable=0`、审计留痕；`temp 1` 到期：`filters_live` **5→0→5** 并自动恢复；卸载后 service/process 均不存在、`filters.txt` **0 行** |
| **Win7 SP1 x64 客户机** | 离线随机密钥 + 主机侧预签名；无登录开机：`filters=6`、`selftest leaked=0`、IPC 启动；主界面截图正常（1028×742） |
| **Windows 11 宿主** | `DefaultDeny=0` 安全安装：服务 RUNNING、`filters=0`、`key_ok=1 / hmac_ok=1`；数据目录 Users 只读、密钥 ACL 仅 SY/BA；UI **输入口令 + 回车 → 主界面**；卸载/数据/密钥清理干净 |

> 说明：Win10 基线/回滚时 `1.1.1.1:443`、百度 443 超时属于宿主网络限制；能连的 3 个目标
> （RDP、8.8.8.8:53、114.114.114.114:53）在 apply 后全部 0ms 拦截、rollback 后全部恢复。
> 回归中 Win10 客户机 NAT 出现一次故障（ping 网关“一般故障”），重启 VM 后恢复；与 NetGuard 无关。
> Win7 的 VMConnect 自动输入存在焦点问题，主界面截图已通过；**真实桌面上的“口令+回车→主界面”在宿主 Win11 上实测通过**。

### 本轮真实回归发现并修复

- **卸载竞态**：服务刚启动（selftest/IPC 未就绪）时立即 `ctl rollback` 会失败，旧脚本
  `| Out-Null` 吞掉错误并 3 秒后 `sc delete`。现在会等待 Running、重试 rollback、等待 Stopped、
  删除后清理残留 `NetGuard.exe`；实测 `service/process=False`、`filters.txt=0`。
- **安装脚本部署顺序**：数据目录 ACL 改为在 `initkey/verify/安装` 之前收紧，并对已存在的
  `policy.ini`/日志去掉旧继承；即使安装中途失败，Users 也不能写数据目录。
- **测试脚本自身问题**：`installer-test.ps1` 原来用管理员会话执行 `sc stop`（会把待测服务停掉），
  已改为只检查 SDDL；`win7-final2.ps1` 原来不投放新 UI，已改为复制当前 `build\NetGuardUI.exe`。

### 2026-11-12 教程采集时修复

- **管理界面新增/编辑规则落空**：`NgEntryWnd` 在 `IDOK` 里先 `DestroyWindow`，返回后才
  `GetWindowTextW` 读子控件，读到的永远是空；复选框状态同理。已改为点“确定”时先把 4 个字段和
  “启用”状态存进对话框结构体，再关窗。修复后界面添加地址/程序可正常保存并下发（实测 filters 6→7）。
- **Win7 cmd 中文输出变 `???`/空白**：`wprintf` 使用 C locale 转换宽字符。已在 `wmain` 里
  `_wsetlocale(LC_ALL, L"")`，按系统 ANSI 代码页输出；同时无参数在控制台运行时不再打印
  “不是以服务方式启动（1063）”，直接显示帮助。
- **安装脚本兼容 Win7 自带 PowerShell 2.0**：`Get-ChildItem -File` 和 `Get-Content -Tail`
  在 PS2 不存在，会触发 trap 走“安装失败”兜底。已换成 `Where-Object { -not $_.PSIsContainer }`
  和 `Select-Object -Last`，Win7 上可完整走正常安装流程。
- **新增图文教程**：[`docs/新手教程.md`](docs/新手教程.md)，21 张 Win7 实机截图（安装、界面配置、
  拦截验证、临时放行、审计、卸载），并提供同版 PDF（`docs/新手教程.pdf`）。
- **60 天试用期**：新增 `ng_trial`，首次 `initkey/initpolicy` 登记 `TrialStart/TrialSig`（HMAC 防手改）。
  `status` / `trial` / 主界面状态栏显示剩余天数；到期后服务在 30 秒内自动撤销过滤器并恢复联网，
  `apply/temp/selftest` 拒绝执行，避免“试用到期变成门店断网事故”。

### 2026-11-12 干净重装 + 全功能回归（Win10 22H2）

先彻底清空旧应用（服务、`C:\NetGuard`、`%ProgramData%\NetGuard`、`HKLM\SOFTWARE\NetGuard`、快捷方式），
再部署当前构建；`lab/deploy-and-test-win10.ps1` 的 **79 项检查全部通过**。过程中发现并修掉两个真实缺陷：

- **服务停止后仍然断网**：`FwpmEngineOpen0` 没设 `FWPM_SESSION_FLAG_DYNAMIC`。非动态会话的过滤器
  在进程退出后依然生效（直到重启），与“进程退出 → 过滤器消失”的失败即安全设计不符。
  已改为动态会话；实测 `sc stop` 后 `filters_live=0`，curl 立即恢复联网。
- **旧版本遗留过滤器无法清理**：新增 `NetGuard.exe purge`，按 sublayer / 显示名识别并删除
  NetGuard 名下全部过滤器（含没有 providerKey 的老持久化过滤器），再删 sublayer/provider。
  `install-netguard.ps1`（停旧服务后）与 `uninstall-netguard.ps1`（删服务后）都会调用它。
  注意：purge 必须用**非动态**会话打开引擎，否则删除其他会话的对象会返回
  `FWP_E_DYNAMIC_SESSION_IN_PROGRESS (0x8032000B)`。

回归覆盖：基线→部署→拦截矩阵（进程×地址×端口，2 组独立绑定互不串用）→回环/DHCP 放行→DNS 封锁→
哈希替换（7→6 条、`Enable=0`、审计 `hash-changed`）→`temp 1` 到期自动恢复（约 65s，含 30s 看门狗粒度）→
手工删过滤器后看门狗自愈→篡改策略 fail-closed→`NetGuard test`→UI 结构自检→卸载（联网恢复、策略/密钥保留）→重装。
UI 像素级截图仍需在交互桌面执行（PowerShell Direct 属 session 0，GDI 截图会是空白）。

### 2026-11-13 加固开发（按实测建议）

- **开发版试用门禁**：`src/ng_trial.h` 设 `NG_TRIAL_ENABLED=0`，暂时关闭 60 天试用；
  `trial`/UI 显示“开发版：试用门禁已临时禁用”。发布前改回 `1` 并重新构建。
- **程序目录 ACL（P0）**：`install-netguard.ps1` 现在把程序目录也收紧为
  SYSTEM/Administrators 完全控制、Users 只读，并清理已有文件的旧继承。
  实测受限令牌无法写入 `C:\NetGuard`。
- **哈希巡检加速（P0 缓解）**：看门狗改为每 5 秒做一次大小/修改时间快检，
  每 30 秒做一次完整 SHA-256；文件被替换后实测约 **3 秒**撤销白名单（原 30 秒）。
- **StrictHash（P2）**：默认 `StrictHash=1`，启用的程序必须有 64 位 SHA-256，
  且禁止 `Path=*`；空哈希/任意进程策略在 `sign`/`validate` 阶段直接拒绝。
- **LanAllow 显式 opt-in（P1）**：`LanAllow` 不再默认生成；如确需，必须同时写
  `AllowLanAnyProcess=1`，否则策略校验失败。UI 填写 LAN 时会自动记录该 opt-in，
  并在报告里标注“任意进程/任意端口，不推荐”。
- **IPv6 业务白名单（P3）**：`Cidr` 支持 IPv6（如 `2001:db8::10/128`），
  在 `ALE_AUTH_CONNECT_V6` 上生成对应的进程×地址×端口 permit。
- **示例策略**：`initpolicy` 不再带 `LanAllow=192.168.1.0/24`；
  示例程序改为 `NetGuard.exe` 自身并自动计算 SHA-256（可被界面替换），
  保证 `StrictHash=1` 下示例策略仍然有效。
- **WFP callout 驱动 + 服务 IOCTL（P0 根治方向）**：安装 WDK 10.0.26100 后新增
  `drv\ngdrv.sys`；用户态服务通过 `\\.\NgDrv` 下发**完整 NT 路径 + SHA-256**
  （最多 64 条，设备 DACL 仅 SYSTEM/Administrators）。进程创建时校验哈希，
  `ALE_AUTH_CONNECT_V4/V6` callout 连接时查表；不匹配的进程即使被用户态
  NetGuard 放行也会被驱动 block。Win10 22H2 实测：正确哈希 `curl exit=35`
  （放行），文件追加字节后 `curl exit=7`（驱动拦截）；Win7 SP1 x64
  实测：正确哈希只放行 8.8.8.8，篡改后全部 BLOCK（驱动 RUNNING、`LastStep=ok`）。
  Win11 24H2 实机（`Win11-Test`，Secure Boot 关 + testsigning）：
  同一构建无需改动，安装后 `ngdrv Running`、`filters=6`，
  正确哈希 `curl exit=35`、其它目标 `exit=7`、篡改后 `exit=7`。
  安装/卸载回归 `lab/installer-driver-test.ps1` 在 **Win10 22/22、Win11 22/22**
  （`-InstallDriver` 自动启动驱动、下发白名单；卸载删除服务和驱动、恢复联网）。
  详见 `drv/README.md`、`src/ngdrv_ioctl.h`、`src/ng_drv.cpp`。
- **免费模式（无驱动/无证书）**：新增 `free-mode.ps1`，用 Windows 防火墙出站默认阻止 +
  按策略生成“程序 × 地址 × 端口”放行规则，并关闭系统自带出站规则；程序目录 ACL 防替换。
  `install-netguard.ps1 -FreeMode` 一键启用，状态写入 `freemode-state.json`，卸载完整恢复。
  实测 Win10 22H2 **22/22**、Win11 24H2 **22/22**
  （`lab/free-mode-test-win10.log` / `lab/free-mode-test-win11.log`）。
  局限：对本地管理员无效、无连接瞬间哈希、会断开系统更新/商店；AppLocker 为实验性开关。
- **回归**：Win10 全功能回归 **78/78**；新增 `lab/hardening-test.ps1` **13/13**
  （程序目录 ACL、试用禁用、StrictHash、LanAllow opt-in、IPv6、3 秒哈希撤销）。
- **Windows 11 真实强制拦截**：宿主 Win11 上以 `DefaultDeny=1` 应用策略，
  只放行 opencode 自身（IPv4 `0.0.0.0/0` + IPv6 `::/0`，SHA-256 绑定）；
  实测 `curl`/`ping`/`Test-NetConnection` 全部被拦，opencode 的 IPv4/IPv6 连接保持，
  回滚后网络恢复。日志：`lab/win11-enforcement.log`；测试后已删除宿主服务。

> 策略格式从 `v1` 升到 `v2`（Canonical 增加 StrictHash/AllowLanAnyProcess）。
> 升级旧策略后需要管理员执行一次 `NetGuard.exe sign` 重新签名。

### 尚未完成

1. **Win7 交互自动化**：已改为“启动文件夹 + 客人机内键盘输入”，可完整无人值守跑完；VMConnect 直接注入按键仍不稳定。
2. **代码签名**：已提供 `sign-build.ps1`，仍需实际代码签名证书（否则被 SmartScreen / 应用控制策略拦）。
3. **安装包**：已加 `install.log` 转录与失败时尽量拉起服务的恢复逻辑；批量部署仍建议在外层再归档日志。
4. **WFP callout 驱动生产化**：`drv/ngdrv.sys` 已在 Win7/Win10/Win11 验证，
   服务 IOCTL 下发完整路径 + SHA-256 已跑通；还需 EV/WHQL 签名，
   在 **Secure Boot 开 + HVCI 开 + testsigning 关** 的生产环境再回归一次，
   以及用 `...Ex`/minifilter/WDAC 消除“哈希期间首连被拦”的窗口。

---

## 三、构建

```bat
build.bat
```
- MSVC（VS2022/2026 均可），`/MT` 静态 CRT，`/utf-8`，`_WIN32_WINNT=0x0601`（Win7 目标）
- 依赖库：`fwpuclnt.lib ws2_32.lib bcrypt.lib`（全部系统自带）
- UI 清单：链接时用 `/MANIFESTUAC` + `/MANIFESTDEPENDENCY` 嵌入（UAC 管理员 + comctl32 v6）
- 产物：`build\NetGuard.exe`（约 470 KB）、`build\NetGuardUI.exe`（约 425 KB）
- 代码签名：`powershell -File sign-build.ps1 -Thumbprint <证书指纹>`

## 四、使用

```powershell
# 生成示例策略（C:\ProgramData\NetGuard\policy.ini）
NetGuard.exe initpolicy

# 生成/检查本机随机部署密钥（管理员；密钥在 HKLM\SOFTWARE\NetGuard）
NetGuard.exe initkey

# 校验并重新签名现有策略（管理员确认内容未被篡改后，用于迁移旧策略）
NetGuard.exe sign

# 离线签名（测试/预置用；不读写本机注册表密钥）
NetGuard.exe sign --key <32-256 位十六进制>

# 轮换本机密钥（旧策略必须重新 sign；会短暂导致签名校验失败）
# reg delete HKLM\SOFTWARE\NetGuard /f
# NetGuard.exe sign
# NetGuard.exe ctl apply

# 端到端自测（推荐先跑：会临时断网几秒再恢复）
NetGuard.exe test

# 安装为服务（先完成 initpolicy/initkey；推荐用 install-netguard.ps1）
NetGuard.exe install
Start-Service NetGuard

# 安装服务 + WFP callout 驱动（驱动 drv\ngdrv.sys 必须已签名）
powershell -ExecutionPolicy Bypass -File install-netguard.ps1 -InstallDriver

# 查看状态 / 生效过滤器数
NetGuard.exe status

# 临时放行 60 分钟（给更新程序用）
NetGuard.exe temp 60
NetGuard.exe apply        # 到期后恢复

# 完全撤销（恢复联网）
NetGuard.exe rollback

# 清理旧版本/旧服务遗留的所有过滤器（含持久化），再删 sublayer/provider
NetGuard.exe purge
```

策略文件格式（`C:\ProgramData\NetGuard\policy.ini`，带 HMAC 签名；手工改内容后签名失效，`apply`/服务会拒绝）：

```ini
[general]
DefaultDeny=1
AllowDhcp=1
AllowLoopback=1
; LanAllow 是“任意进程/任意端口”放行；默认不要写。
; 如确需，必须同时 AllowLanAnyProcess=1（策略文件会记录该 opt-in）。
; LanAllow=192.168.1.0/24
AllowLanAnyProcess=0
AllowDnsServer=                  ; 留空=完全禁止 DNS（业务用固定 IP）
StrictHash=1                     ; 启用的程序必须有 64 位 SHA-256，且禁止 Path=*
PolicyHmac=XXXX                  ; 由程序生成

[ep.1]
Name=医保前置
Cidr=10.10.10.10/32
Ports=8000-8005
Proto=TCP
Enable=1

; IPv6 业务地址也可以直接写：
; [ep.2]
; Name=医保前置v6
; Cidr=2001:db8::10/128
; Ports=8000-8005
; Proto=TCP
; Enable=1

[proc.1]
Name=医保客户端
Path=C:\Program Files\YB\YbClient.exe
Sha256=A1B2C3...                 ; 必须 64 位；界面选择 exe 会自动计算
Endpoint=医保前置
Enable=1
```

## 五、免费模式（无驱动 / 无证书）

不买 EV、不装驱动时的落地方案，详见 **[docs/免费模式.md](docs/免费模式.md)**。

```powershell
# 安装服务 + 免费模式（Windows 防火墙出站白名单）
powershell -ExecutionPolicy Bypass -File install-netguard.ps1 -FreeMode

# 查看 / 紧急关闭
powershell -ExecutionPolicy Bypass -File free-mode.ps1 -Action Status
powershell -ExecutionPolicy Bypass -File free-mode.ps1 -Action Disable
```

做了什么：

- Windows 防火墙出站**默认阻止**，按 `policy.ini` 的“程序 × 地址 × 端口 × 协议”生成放行规则；
- 关闭 Windows 自带出站放行规则（避免更新/商店等漏网）；
- 自动放行 DHCP；DNS 默认禁止，可按 `AllowDnsServer` 显式放行；
- 保留用户态 WFP 策略和 3 秒哈希巡检；程序目录 ACL 防止标准用户替换；
- 所有改动记录在 `%ProgramData%\NetGuard\freemode-state.json`，卸载时完整恢复。

实测：Win10 22H2 **22/22**、Win11 24H2 **22/22**
（`lab/free-mode-test-win10.log` / `win11.log`）。

> 修改 `policy.ini` 并 `ctl apply` 后，记得再跑一次
> `powershell -File free-mode.ps1 -Action Enable`，否则防火墙仍是旧规则。

局限：对本地管理员无效；没有连接瞬间哈希；会断开系统更新/商店/时间同步；
AppLocker 为实验性开关（部分 Win10 本地策略会 fail-open），默认关闭。

## 六、目录

```
C:\src\NetGuard\
├─ build.bat              构建脚本（MSVC）
├─ sign-build.ps1         构建产物代码签名/验签
├─ install-netguard.ps1   安装服务（-InstallDriver / -FreeMode）
├─ uninstall-netguard.ps1 卸载（先回滚，再删服务/驱动，最后关免费模式）
├─ free-mode.ps1          免费模式：防火墙出站白名单（可选 AppLocker）
├─ docs\
│  ├─ 新手教程.md/.pdf    部署教程
│  ├─ 实测报告-2026-11-13.md
│  └─ 免费模式.md          无驱动/无证书方案、局限、排障
├─ src\
│  ├─ ng_common.h/.cpp    日志、SHA-256/HMAC、字符串/路径
│  ├─ ng_policy.h/.cpp    策略模型、INI 解析、字段格式校验、签名校验
│  ├─ ng_wfp.h/.cpp       WFP 引擎封装（默认拒绝 + 白名单 + 实测计数）
│  ├─ ng_ipc.h/.cpp       命名管道 IPC（服务端/客户端）
│  ├─ ng_trial.h/.cpp     60 天试用期登记、签名校验、到期判断
│  ├─ ng_drv.h/.cpp       驱动白名单下发（DeviceIoControl）、DOS→NT 路径
│  ├─ ngdrv_ioctl.h       用户态/内核共享 IOCTL 结构
│  ├─ ng_service.cpp      服务模式、看门狗、自检、安装/卸载
│  ├─ NetGuard.cpp        CLI 入口
│  └─ ui_main.cpp         管理界面（Win32，无 MFC；链接时嵌入 UAC + comctl32 v6 清单）
├─ drv\                   WFP callout 驱动（ngdrv.sys）
│  ├─ ngdrv.c             进程哈希门禁 + ALE_AUTH_CONNECT callout
│  ├─ build-ngdrv.bat     驱动构建（WDK 10.0.26100）
│  └─ README.md           原理/构建/签名/部署/限制
└─ lab\                   自动化测试脚本（宿主侧驱动虚拟机做验证）
   ├─ ng-lab-common.ps1   随机密钥、离线签名、PS Direct 签名助手
   └─ free-mode-test.ps1  免费模式 22 项回归（Win10/Win11）
```

> 注意：`lab` 中早期生成的 `policy-*.ini` 夹具没有 `PolicyHmac`。主流回归脚本已自动处理：
> PS Direct 脚本在部署后调用 `NetGuard.exe sign`；Win7 离线脚本用 `sign --key` 预签名。
> 手工部署旧夹具时，仍需在客户机以管理员执行 `NetGuard.exe sign`。
> 另外，默认 `StrictHash=1` 会拒绝“启用的程序 + 空 Sha256”；旧夹具需要补哈希，
> 或显式 `StrictHash=0`（仅测试，不要用于生产）。
>
> 当前主要回归脚本：Win10 `run-tests.ps1` / `test-win10.ps1` / `hash-test.ps1` /
> `ipc-test4.ps1` / `installer-test.ps1` / `demo-setup.ps1`；Win7 `svc-test.ps1` /
> `w7test4.ps1` / `w7test-final.ps1` / `run-test-win7.ps1`。
> 早期的 `test-win10b.ps1` / `ipc-test3.ps1` / `w7test3.ps1` 含历史损坏路径，已由上述脚本取代。

## 七、踩过的坑（供后续参考）

| 现象 | 原因 | 解决 |
|---|---|---|
| `FWP_E_LIFETIME_MISMATCH (0x80320016)` | 持久化过滤器要求持久化 sublayer，而用户态建持久化 sublayer 返回 `ERROR_INVALID_FUNCTION` | 改为**会话级**过滤器，由常驻服务持有会话 |
| `status` 命令堆损坏崩溃 | INI 解析器用 `std::vector` 存 section，`AddSection` 返回的指针在 `push_back` 后悬空 | 改用 `std::map`（引用稳定） |
| `FwpmFilterEnum0` 释放后堆损坏 | 枚举器返回数组的释放语义易错 | 完全放弃枚举：自己记录过滤器 ID 到 `filters.txt` |
| 命令输出中文全变问号 | 宽字符重定向到文件时按 ANSI 转换 | 自检/日志改用 ASCII 或写 UTF-8 日志文件 |
| 策略改了不生效 | 程序读的是 `C:\ProgramData\NetGuard\policy.ini`，不是 exe 目录 | 部署时注意路径 |
| `NetGuard.exe` 在宿主机被拦 | 宿主启用了 Smart App Control（应用控制策略），未签名 exe 被拒 | 只在虚拟机/目标机运行；交付前做代码签名 |
