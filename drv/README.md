# NetGuard WFP Callout 驱动（ngdrv.sys）

> 目标：在 **连接发起瞬间** 校验白名单程序的 SHA-256，解决用户态 NetGuard
> “程序被替换后最多几秒窗口”的 P0 问题。
>
> 状态：**驱动 + 用户态服务 IOCTL 下发 + 完整路径白名单已在
> Windows 7 SP1 x64、Windows 10 22H2、Windows 11 24H2 实机跑通**
> （测试签名 + testsigning）。
> Win7 需要 SHA-1 测试签名和 `SUBSYSTEM:NATIVE,6.01`；生产版仍需 EV/WHQL 正式签名，
> 并在 Secure Boot + HVCI 开启的环境再回归一次。
>
> 💡 **不想买证书/装驱动？** 用免费模式：Windows 防火墙出站白名单 + 程序目录 ACL，
> Win10/Win11 均 **22/22** 通过，见 `docs/免费模式.md`。
> 驱动是“付费增强项”：它提供连接时哈希门禁，免费模式没有。

---

## 一、架构

```text
用户态 NetGuard 服务
  ├─ 加载 policy.ini（程序路径 + SHA-256）
  ├─ ApplyOnce() 成功
  │    └─ NgDrvSendWhitelist(policy)
  │         └─ DeviceIoControl(\\.\NgDrv, IOCTL_NGDRV_SET_WHITELIST)
  │              ├─ 路径: C:\NetGuard\biz.exe
  │              └─ 服务侧 QueryDosDevice 转成 NT 路径
  │                   \Device\HarddiskVolumeX\NetGuard\biz.exe
  └─ rollback/temp/service-stop
       └─ IOCTL_NGDRV_CLEAR_WHITELIST

内核驱动 ngdrv.sys
  ├─ 进程创建 PsSetCreateProcessNotifyRoutine
  │    ├─ SeLocateProcessImageName 取 NT 完整路径
  │    ├─ 与白名单做 RtlEqualUnicodeString(..., TRUE)
  │    ├─ 先以 Verified=FALSE 入表（fail-closed）
  │    ├─ ZwReadFile + BCrypt SHA-256
  │    └─ 哈希匹配 → Verified=TRUE
  └─ ALE_AUTH_CONNECT_V4/V6 callout
       ├─ 取 FWPS_METADATA_FIELD_PROCESS_ID
       ├─ 查进程表
       │    ├─ 找到且未验证 → FWP_ACTION_BLOCK
       │    ├─ 找到且已验证 → FWP_ACTION_CONTINUE
       │    └─ 未找到（非白名单）→ FWP_ACTION_CONTINUE
```

关键点：

- 白名单是**完整 NT 路径 + SHA-256**，服务最多下发 64 条；
- 路径比较用 `RtlEqualUnicodeString(..., TRUE)`（大小写不敏感）；
- 哈希在进程创建时做，不在 WFP classify 里做文件 I/O；
- 先入表（未验证）再哈希，哈希期间连接会被拦，避免“还没算完就放行”；
- 驱动 filter 权重 `0x7000`，高于用户态业务 permit（`0x2000`），
  因此驱动 block 能覆盖用户态 permit；
- 驱动只 gate 白名单路径；其他进程 `CONTINUE`，仍由用户态策略处理
  （默认拒绝、回环、DHCP、DNS 例外不受影响）。

> 本环境 `PsSetCreateProcessNotifyRoutineEx` 返回 `STATUS_ACCESS_DENIED (0xC0000022)`，
> 因此使用通知型 `PsSetCreateProcessNotifyRoutine` + 失败即拦的进程缓存。
> 生产签名后可改用 `...Ex` 的 `CreationStatus` 直接拒绝进程创建，或配合 minifilter。

---

## 二、IOCTL 接口

共享头文件：`src/ngdrv_ioctl.h`（用户态/内核共用）。

```text
设备:   \Device\NgDrv      （用户态 \\.\NgDrv）
DACL:   D:P(A;;GA;;;SY)(A;;GA;;;BA)   ← 仅 SYSTEM / Administrators

IOCTL_NGDRV_SET_WHITELIST    输入 NGDRV_WL_BUFFER
IOCTL_NGDRV_CLEAR_WHITELIST  无输入
IOCTL_NGDRV_GET_STATUS       输出 NGDRV_STATUS
```

`NGDRV_WL_ENTRY`：

```c
WCHAR Path[520];   // 服务转换后的 NT 路径
WCHAR Hash[65];    // SHA-256
```

用户态实现：`src/ng_drv.cpp`

- `NgDrvSendWhitelist(policy)`：把启用的 `proc`（非 `*`、64 位哈希）下发；
- `DosPathToNt()` 用 `QueryDosDeviceW("C:")` 把 `C:\...` 转成
  `\Device\HarddiskVolumeX\...`；
- `NgDrvClearWhitelist()`：回滚/临时放行/服务停止时清空。

服务集成点（`src/ng_service.cpp`）：

- `ApplyOnce` 成功后：默认拒绝 → 下发白名单；临时放行 → 清空；
- `rollback` / `temp` / 试用到期 / 放行模式 / 服务停止：清空；
- 看门狗每 30 秒幂等重发一次（驱动可能比服务晚启动）。

---

## 三、构建

依赖：Windows 11 SDK/WDK **10.0.26100**。

```bat
cd C:\src\NetGuard\drv
build-ngdrv.bat
```

产物：

```text
C:\src\NetGuard\drv\out\ngdrv.sys
```

构建脚本要点：

- `cl /kernel /utf-8`，WDK `km` 头文件；
- `NDIS60 / NDIS_SUPPORT_NDIS6`（`fwpsk.h` 需要 `NET_BUFFER_LIST`）；
- `INITGUID` + `guiddef.h`；链接 SDK `um\x64\uuid.lib` 提供 WFP 层 GUID；
- 链接 `fwpkclnt.lib cng.lib ksecdd.lib ntstrsafe.lib wdmsec.lib BufferOverflowK.lib`；
- `IoCreateDeviceSecure` 用 `wdmsec.lib` 设置设备 DACL。

用户态构建：`build.bat` 已包含 `src/ng_drv.cpp`。

---

## 四、测试签名与部署

测试证书（**不能用于生产**）：

```powershell
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=NetGuardTest' `
        -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy Exportable -HashAlgorithm sha256
Export-Certificate -Cert $cert -FilePath C:\src\NetGuard\lab\NetGuardTest.cer
signtool sign /fd sha256 /sm /s My /sha1 $cert.Thumbprint C:\src\NetGuard\drv\out\ngdrv.sys
```

客户机：

```cmd
certutil -addstore -f Root             C:\NetGuard\drv\NetGuardTest.cer
certutil -addstore -f TrustedPublisher C:\NetGuard\drv\NetGuardTest.cer
bcdedit /set testsigning on

sc create ngdrv type= kernel start= demand binPath= C:\NetGuard\drv\ngdrv.sys
sc start ngdrv
```

正式安装可直接用：

```powershell
powershell -ExecutionPolicy Bypass -File install-netguard.ps1 -InstallDriver
```

> `-InstallDriver` 会创建/启动 `ngdrv`（`start= auto`）；如果驱动未签名或
> testsigning 未开，会提示“驱动未运行”，但用户态管控继续工作。
> 生产环境只应安装 EV/WHQL 签名的驱动，并关闭 testsigning。

---

## 五、实测结果（Win10 22H2 x64）

脚本：`C:\src\NetGuard\lab\ngdrv-test.ps1`
日志：`C:\src\NetGuard\lab\ngdrv-test.log`

流程：

1. 部署新用户态构建，启动 `NetGuard` 服务和 `ngdrv.sys`；
2. 用户态策略允许 `C:\NetGuard\ngblock.exe → 8.8.8.8:53/TCP`（哈希 H1）；
3. `ctl apply` → 服务通过 IOCTL 下发 H1；
4. 运行 `ngblock.exe` → 放行；
5. 在 `ngblock.exe` 末尾追加字节（哈希 H2），立即运行 → 驱动拦截。

结果：

```text
service ready=True
ngdrv: RUNNING
netguard apply: OK filters=6
driver status: LastStep=ok LastStatus=0
ng.log: drv: 已下发 1 条白名单

correct hash:   curl exit=35   ← 驱动 CONTINUE + 用户态 permit 放行
tampered hash:  curl exit=7    ← 驱动 BLOCK，覆盖用户态 permit
cleanup: OK filters=0
```

这证明：

- 服务→驱动 IOCTL 下发链路可用；
- 完整 NT 路径匹配可用；
- 连接时（严格说是进程创建时）哈希校验能拦截“被替换后的新进程”，
  即使该路径仍在用户态白名单里；
- 回滚后驱动白名单被清空，不会残留断网/误拦。

---

## 五·补充、Windows 7 SP1 x64 实测

Win7 对驱动签名/子系统版本更敏感，已验证的配置：

- 测试证书 **SHA-1**（`CN=NetGuardWin7Test`），`certutil -addstore` 到
  Root / TrustedPublisher；
- 驱动用 `signtool sign /fd sha1` 签名；
- 编译：
  - `_WIN32_WINNT=0x0601`、`NTDDI_VERSION=0x06010000`；
  - 链接 `/SUBSYSTEM:NATIVE,6.01`；
- `bcdedit /set testsigning on` + `nointegritychecks on`。

结果：

```text
testsigning             Yes
ngdrv                   RUNNING
driver LastStep=ok

正确哈希 ngblock.exe selftest:
  [LEAK ] 8.8.8.8:53          CONNECTED (219ms)   ← 用户态 permit 放行
  [BLOCK] 114.114.114.114:53  0ms                 ← 默认拒绝
  [BLOCK] 1.1.1.1:443         0ms
  [BLOCK] 180.101.49.12:443   0ms

追加字节篡改后:
  [BLOCK] 8.8.8.8:53          0ms                 ← 驱动按 H2 != H1 拦截
  RESULT: all blocked = PASS
```

日志：`lab/win7-drv-result.txt`、`lab/win7-drv-test.log`。

> 重要修正：驱动 filter 必须使用 **`FWP_ACTION_CALLOUT_UNKNOWN`**。
> 早期用 `FWP_ACTION_CALLOUT_TERMINATING` 时，已验证进程返回 `CONTINUE`
> 会被当成最终动作，导致已验证进程绕过用户态默认拒绝（Win7 实测
> `114.114.114.114:53` 泄漏）。改成 UNKNOWN 后，已验证 → CONTINUE，
> 未验证 → BLOCK，其余目标仍由用户态默认拒绝处理。

## 五·补充 2、安装/卸载回归（Win10）

脚本：`C:\src\NetGuard\lab\installer-driver-test.ps1`
日志：`C:\src\NetGuard\lab\installer-driver-test.log`

```text
install-netguard.ps1 -InstallDriver
  → NetGuard Running
  → ngdrv Running
  → filters=6
  → 程序目录 Users 只读
  → 驱动白名单已下发（ng.log: drv:）
  → 正确哈希放行 / 其他目标被默认拒绝 / 篡改后驱动拦截

uninstall-netguard.ps1
  → NetGuard 服务删除
  → ngdrv 驱动删除
  → filters.txt 0 行
  → 网络恢复

total checks=22 failed=0
```

> 安装顺序修正：服务可能先于驱动启动，启动时的白名单下发会失败；
> `install-netguard.ps1` 在驱动启动后补一次 `ctl apply`，确保驱动立即拿到白名单。

## 五·补充 3、Windows 11 24H2 实测

环境：Windows 11 Enterprise Evaluation 24H2（`10.0.26100`），Gen2 + vTPM，
**Secure Boot 关**、`testsigning on` + `nointegritychecks on`、VBS/HVCI 未启用。
脚本：`lab\installer-driver-test.ps1 -VmName 'Win11-Test'`
（包装脚本 `lab\win11-driver-test.ps1`）；
日志：`lab\win11-installer-driver-test.log`。

```text
install-netguard.ps1 -InstallDriver
  → NetGuard Running
  → ngdrv Running
  → filters=6
  → 正确哈希 curl exit=35（放行到 8.8.8.8:53）
  → 其它目标 curl exit=7（用户态默认拒绝）
  → 篡改二进制 curl exit=7（驱动 BLOCK）

uninstall-netguard.ps1
  → NetGuard 服务删除
  → ngdrv 驱动删除
  → filters.txt 0 行
  → Test-NetConnection 恢复 True

total checks=22 failed=0
```

结论：24H2 上驱动加载、IOCTL 下发、连接校验、卸载清理均正常，
**不需要为 Win11 单独改代码**（与 Win10 同一构建）。

> 局限：这是 testsigning 环境，**没有验证 Secure Boot + HVCI 开启时的生产加载路径**。
> 正式发布前必须用 EV/WHQL 签名驱动，在 Secure Boot 开、HVCI 开、`testsigning off`
> 的 Win11 上再跑同一套 22 项回归。

## 六、当前限制

| 限制 | 说明 | 下一步 |
|---|---|---|
| 测试签名 | `CN=NetGuardTest` | 生产 EV/WHQL 签名；关闭 testsigning |
| 通知型创建回调 | 不能拒绝进程创建 | 生产签名后改 `...Ex` 的 `CreationStatus`，或 minifilter/WDAC |
| 哈希期间首连被拦 | fail-closed；应用可能看到一次失败 | 应用重试，或 exec 前 minifilter 校验 |
| 最多 64 条 | 原型上限 | 需要时扩大/动态分块 |
| Win7 | 已实测通过（SHA-1 测试签名 + testsigning + `6.01` 子系统） | 生产仍需正式签名 |
| Win11 | 已实测通过（24H2、Secure Boot 关 + testsigning、22/22） | Secure Boot + HVCI 开启环境需正式签名后再回归 |
| 安装流程 | 已加 `-InstallDriver` / 卸载删除 `ngdrv`，Win10 与 Win11 回归均 22/22 | 正式签名后启用；测试签名仅限实验环境 |
| 驱动调试日志 | 写到 `HKLM\SOFTWARE\NetGuard\DriverTest` | 生产收紧 ACL 或改为 ETW |

---

## 七、文件

| 文件 | 作用 |
|---|---|
| `drv/ngdrv.c` | WFP callout + 进程哈希门禁驱动 |
| `drv/build-ngdrv.bat` | 驱动构建脚本 |
| `src/ngdrv_ioctl.h` | 用户态/内核共享 IOCTL 结构 |
| `src/ng_drv.cpp` / `.h` | 服务侧白名单下发、DOS→NT 路径转换 |
| `lab/ngdrv-test.ps1` | 端到端测试（证书、签名、部署、正确/篡改哈希） |
| `lab/ngdrv-test.log` | Win10 实测日志 |
| `lab/win7-drv-test.log` / `lab/win7-drv-result.txt` | Win7 实测日志 |
| `lab/win11-driver-test.ps1` / `lab/win11-installer-driver-test.log` | Win11 安装+驱动回归（22/22） |
| `drv/out/ngdrv.sys` | 测试签名驱动产物 |
| `drv/hello.c` / `build-drv.bat` | 最小驱动加载验证 |
