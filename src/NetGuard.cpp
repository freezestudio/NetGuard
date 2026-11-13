#include "ng_common.h"
#include "ng_policy.h"
#include "ng_wfp.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdio>
#include <clocale>

#pragma comment(lib, "ws2_32.lib")

#include "ng_ipc.h"
#include "ng_trial.h"
#include "ng_drv.h"

// 服务相关（ng_service.cpp）
int NgRunService();
int NgRunConsole();
int NgInstallService();
int NgUninstallService();

static std::wstring PolicyPath()
{
    return NgDataDir() + L"\\policy.ini";
}

static void Usage()
{
    wprintf(L"NetGuard - 药店终端出网白名单（Windows 7+）\n\n");
    wprintf(L"用法:\n");
    wprintf(L"  NetGuard apply             应用策略（默认拒绝 + 白名单）\n");
    wprintf(L"  NetGuard rollback          撤销全部策略（恢复联网）\n");
    wprintf(L"  NetGuard purge             清理旧版本遗留的持久化过滤器（升级/卸载前）\n");
    wprintf(L"  NetGuard status            显示当前策略与生效过滤器数量\n");
    wprintf(L"  NetGuard temp <分钟>       临时放行（默认拒绝关闭，到期自动恢复）\n");
    wprintf(L"  NetGuard test              端到端自测：应用→自检→回滚（同一进程，推荐）\n");
    wprintf(L"  NetGuard selftest          仅自检：尝试访问外网，应全部被拦截\n");
    wprintf(L"  NetGuard hash <文件>       计算 SHA-256（用于绑定业务程序）\n");
    wprintf(L"  NetGuard initpolicy        生成示例策略文件（含部署密钥）\n");
    wprintf(L"  NetGuard initkey           生成/检查部署密钥 HKLM\\SOFTWARE\\NetGuard（管理员）\n");
    wprintf(L"  NetGuard trial             查看 60 天试用期剩余天数\n");
    wprintf(L"  NetGuard sign [--key HEX]  校验并重新签名现有策略（--key 用于离线/测试）\n");
    wprintf(L"  NetGuard verify            校验策略签名并预演（不生效）\n");
    wprintf(L"\n策略文件: %s\n", PolicyPath().c_str());
}

static bool ConnectTest(const char* ip, int port, DWORD timeoutMs, int& errOut)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) { errOut = WSAGetLastError(); return false; }

    sockaddr_in sa = {};
    sa.sin_family = AF_INET;
    sa.sin_port = htons((u_short)port);
    inet_pton(AF_INET, ip, &sa.sin_addr);

    u_long nb = 1;
    ioctlsocket(s, FIONBIO, &nb);
    int rc = connect(s, (sockaddr*)&sa, sizeof(sa));

    bool connected = false;
    if (rc == 0) connected = true;
    else if (WSAGetLastError() == WSAEWOULDBLOCK) {
        fd_set wf, ef;
        FD_ZERO(&wf); FD_SET(s, &wf);
        FD_ZERO(&ef); FD_SET(s, &ef);
        timeval tv = { (long)(timeoutMs / 1000), (long)((timeoutMs % 1000) * 1000) };
        int sel = select(0, nullptr, &wf, &ef, &tv);
        if (sel > 0 && FD_ISSET(s, &wf)) {
            int soErr = 0, len = sizeof(soErr);
            getsockopt(s, SOL_SOCKET, SO_ERROR, (char*)&soErr, &len);
            errOut = soErr;
            connected = (soErr == 0);
        } else {
            errOut = WSAETIMEDOUT;
        }
    } else {
        errOut = WSAGetLastError();
    }
    closesocket(s);
    return connected;
}

static int CmdSelfTest()
{
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);

    struct Target { const char* ip; int port; const char* label; };
    Target targets[] = {
        { "172.30.18.120",   3389, "Win10-RDP(local)" },
        { "8.8.8.8",         53,  "Google DNS" },
        { "114.114.114.114", 53,  "NS-China" },
        { "1.1.1.1",         443, "Cloudflare" },
        { "180.101.49.12",   443, "Baidu" },
    };

    int leaked = 0;
    printf("selftest: all targets should be BLOCKED\n");
    for (auto& t : targets) {
        DWORD t0 = GetTickCount();
        int err = 0;
        bool ok = ConnectTest(t.ip, t.port, 2500, err);
        DWORD ms = GetTickCount() - t0;
        if (ok) {
            leaked++;
            printf("  [LEAK ] %-16s:%-5d %-12s CONNECTED (%lums)\n", t.ip, t.port, t.label, ms);
        } else {
            printf("  [BLOCK] %-16s:%-5d %-12s err=%d (%lums)\n", t.ip, t.port, t.label, err, ms);
        }
    }
    WSACleanup();

    if (leaked == 0) { printf("RESULT: all blocked = PASS\n"); return 0; }
    printf("RESULT: %d target(s) still reachable = FAIL\n", leaked);
    return 2;
}

static int LoadPolicyOrDie(NgPolicy& p, bool requireSignature)
{
    if (!p.Load(PolicyPath())) {
        wprintf(L"[x] 无法读取策略文件: %s\n", PolicyPath().c_str());
        wprintf(L"    先运行 NetGuard initpolicy 生成示例，或用管理界面保存策略。\n");
        return 1;
    }
    if (requireSignature) {
        std::wstring key, kerr;
        if (!NgPolicyKeyRead(key, &kerr)) {
            wprintf(L"[x] %s\n", kerr.c_str());
            wprintf(L"    请管理员运行 NetGuard initkey 生成部署密钥；迁移旧策略用 NetGuard sign。\n");
            return 3;
        }
        if (p.hmac.empty()) {
            wprintf(L"[x] 策略没有签名（PolicyHmac 为空），已按 fail-closed 拒绝。\n");
            wprintf(L"    请用管理界面保存策略，或管理员确认内容后运行 NetGuard sign 重新签名。\n");
            return 3;
        }
        if (!p.VerifyHmac(key)) {
            wprintf(L"[x] 策略签名校验失败：文件被篡改、来自其他环境，或密钥已更换。\n");
            wprintf(L"    请用管理界面重新保存策略（会重新签名）。\n");
            return 3;
        }
    }
    std::wstring err;
    if (!p.Validate(err)) { wprintf(L"[x] 策略无效: %s\n", err.c_str()); return 4; }
    return 0;
}

static bool TempAllowActive(const NgPolicy& p)
{
    return p.tempAllowUntil > NgUnixNow();
}

static int CmdApply()
{
    NgLog(L"apply: enter");
    if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限运行。\n"); return 5; }

    NgPolicy p;
    int rc = LoadPolicyOrDie(p, true);
    NgLog(L"apply: load rc=%d eps=%d procs=%d tempUntil=%llu", rc, (int)p.eps.size(), (int)p.procs.size(), (unsigned long long)p.tempAllowUntil);
    if (rc) return rc;

    if (TempAllowActive(p)) {
        uint64_t left = p.tempAllowUntil - NgUnixNow();
        wprintf(L"[!] 临时放行中（剩余 %llu 分钟），本次不下发拒绝策略\n",
                (unsigned long long)(left / 60));
        NgPolicy relaxed = p;
        relaxed.defaultDeny = false;
        NgSession sess;
        if (!NgWfpOpen(sess)) { wprintf(L"[x] 无法打开 WFP 会话\n"); return 1; }
        NgResult r = NgWfpApply(sess, relaxed);
        NgWfpClose(sess);
        if (r.ok) NgDrvClearWhitelist();
        wprintf(L"%s %s\n", r.ok ? L"[ok]" : L"[x]", r.msg.c_str());
        return r.ok ? 0 : 1;
    }

    NgSession sess;
    if (!NgWfpOpen(sess)) { wprintf(L"[x] 无法打开 WFP 会话（需管理员）\n"); return 1; }
    NgResult r = NgWfpApply(sess, p);
    NgWfpClose(sess);
    if (r.ok) { if (p.defaultDeny) NgDrvSendWhitelist(p); else NgDrvClearWhitelist(); }
    wprintf(L"%s %s\n", r.ok ? L"[ok]" : L"[x]", r.msg.c_str());
    wprintf(L"    业务地址 %d 条 / 业务程序 %d 条 / 已下发过滤器 %d 条\n",
            (int)p.eps.size(), (int)p.procs.size(), r.filters);
    wprintf(L"    注意：命令行 apply 是会话级的，进程退出后过滤器即消失；\n");
    wprintf(L"    正式使用请由常驻服务（NetGuard.exe install）持有会话。\n");
    return r.ok ? 0 : 1;
}

// 端到端自测：同一进程内 应用 → 自检 → 回滚
static int CmdTest()
{
    if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限运行。\n"); return 5; }
    NgPolicy p;
    int rc = LoadPolicyOrDie(p, true);
    if (rc) return rc;

    NgSession sess;
    if (!NgWfpOpen(sess)) { wprintf(L"[x] 无法打开 WFP 会话\n"); return 1; }

    wprintf(L"== 1) 基线自检（应能连出去）==\n");
    int before = CmdSelfTest();

    wprintf(L"\n== 2) 下发策略 ==\n");
    NgResult r = NgWfpApply(sess, p);
    if (r.ok) { if (p.defaultDeny) NgDrvSendWhitelist(p); else NgDrvClearWhitelist(); }
    wprintf(L"%s %s（过滤器 %d 条）\n", r.ok ? L"[ok]" : L"[x]", r.msg.c_str(), r.filters);
    if (!r.ok) { NgWfpClose(sess); return 1; }

    wprintf(L"\n== 3) 应用后自检（应全部拦截）==\n");
    int after = CmdSelfTest();

    wprintf(L"\n== 4) 回滚 ==\n");
    NgResult rr = NgWfpRollback(sess);
    if (rr.ok) NgDrvClearWhitelist();
    wprintf(L"%s %s\n", rr.ok ? L"[ok]" : L"[x]", rr.msg.c_str());

    wprintf(L"\n== 5) 回滚后自检（应恢复连接）==\n");
    int restored = CmdSelfTest();

    NgWfpClose(sess);

    wprintf(L"\n==== 结果 ====\n");
    wprintf(L"  基线: %s\n", before > 0 ? L"能连出去 (OK)" : L"已拦截 (异常)");
    wprintf(L"  应用后: %s\n", after == 0 ? L"全部拦截 (PASS)" : L"仍有泄漏 (FAIL)");
    wprintf(L"  回滚后: %s\n", restored > 0 ? L"恢复连接 (OK)" : L"仍被拦截 (异常)");
    return (before > 0 && after == 0 && restored > 0) ? 0 : 2;
}

static int CmdStatus()
{
    NgLog(L"status: enter");
    NgPolicy p;
    p.Load(PolicyPath());
    wprintf(L"策略文件: %s\n", PolicyPath().c_str());
    wprintf(L"  默认拒绝: %s\n", p.defaultDeny ? L"开启" : L"关闭");
    wprintf(L"  DHCP 放行: %s   回环放行: %s\n",
            p.allowDhcp ? L"是" : L"否", p.allowLoopback ? L"是" : L"否");
    if (!p.lanAllow.empty()) wprintf(L"  内网放行: %s\n", p.lanAllow.c_str());
    if (!p.allowDnsServer.empty()) wprintf(L"  DNS 放行: %s\n", p.allowDnsServer.c_str());
    std::wstring key, kerr;
    bool keyOk = NgPolicyKeyRead(key, &kerr);
    wprintf(L"  签名: %s\n", p.hmac.empty() ? L"(无)" :
            !keyOk ? L"(密钥缺失/不可读)" :
            p.VerifyHmac(key) ? L"有效" :
            p.VerifyHmac(NgLegacyPolicyKey()) ? L"旧版签名（需 NetGuard sign 迁移）" : L"无效!");
    if (!keyOk) wprintf(L"  策略密钥: %s\n", kerr.c_str());
    {
        NgTrialInfo ti;
        if (NgTrialEnsure(ti, false)) {
            if (ti.disabled)
                wprintf(L"  试用: 开发版（60 天试用门禁已禁用）\n");
            else if (ti.expired)
                wprintf(L"  试用: 已到期（%s），管控已停止\n", NgTrialTimeText(ti.end).c_str());
            else
                wprintf(L"  试用剩余: %d 天（到 %s）\n", ti.daysLeft, NgTrialTimeText(ti.end).c_str());
        } else {
            wprintf(L"  试用: %s\n", ti.error.empty() ? L"未登记" : ti.error.c_str());
        }
    }
    if (TempAllowActive(p))
        wprintf(L"  临时放行: 剩余 %llu 分钟\n", (unsigned long long)((p.tempAllowUntil - NgUnixNow()) / 60));
    wprintf(L"  业务地址: %d 条\n", (int)p.eps.size());
    for (auto& e : p.eps)
        wprintf(L"    - %-16s %-18s %-12s %-4s %s\n", e.name.c_str(), e.cidr.c_str(),
                e.ports.c_str(), e.proto.c_str(), e.enabled ? L"" : L"(停用)");
    wprintf(L"  业务程序: %d 条\n", (int)p.procs.size());
    for (auto& x : p.procs)
        wprintf(L"    - %-20s -> %-14s %s\n", x.name.c_str(), x.endpoint.c_str(),
                x.enabled ? L"" : L"(停用)");
    // 过滤器数量按 filters.txt 逐条查询；需要管理员权限打开 WFP 引擎
    int live = -1;
    if (NgIsAdmin()) {
        NgSession sess;
        if (NgWfpOpen(sess)) {
            live = NgWfpLiveCount(sess);
            NgWfpClose(sess);
        }
    }
    if (live >= 0) wprintf(L"  当前生效过滤器: %d 条\n", live);
    else          wprintf(L"  当前生效过滤器: 无法读取（需管理员权限）\n");
    return 0;
}

static int CmdTemp(int minutes)
{
    if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限运行。\n"); return 5; }
    NgPolicy p;
    int rc = LoadPolicyOrDie(p, true);
    if (rc) return rc;
    p.tempAllowUntil = NgUnixNow() + (uint64_t)minutes * 60ULL;
    if (!p.Save(PolicyPath())) { wprintf(L"[x] 写策略失败\n"); return 1; }

    // 立即撤销现有拒绝过滤器：必须把 defaultDeny 置为 false，
    // 否则会把“临时放行”执行成“重新下发拒绝”。
    NgPolicy relaxed = p;
    relaxed.defaultDeny = false;

    NgSession sess;
    if (!NgWfpOpen(sess)) { wprintf(L"[x] 无法打开 WFP 会话\n"); return 1; }
    NgResult r = NgWfpApply(sess, relaxed);
    NgWfpClose(sess);
    if (!r.ok) { wprintf(L"[x] %s\n", r.msg.c_str()); return 1; }
    NgDrvClearWhitelist();

    wprintf(L"[ok] 临时放行 %d 分钟（到 %llu），已撤销拒绝策略。\n", minutes,
            (unsigned long long)p.tempAllowUntil);
    wprintf(L"     到期后服务看门狗会自动恢复；无服务时请执行 NetGuard apply。\n");
    return 0;
}

static int CmdInitPolicy()
{
    if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限（用于生成部署密钥）。\n"); return 5; }

    std::wstring key, kerr;
    bool created = false;
    if (!NgPolicyKeyEnsure(key, &kerr, &created)) { wprintf(L"[x] %s\n", kerr.c_str()); return 1; }

    CreateDirectoryW(NgDataDir().c_str(), nullptr);
    NgPolicy p;
    p.defaultDeny = true;
    p.allowDhcp = true;
    p.allowLoopback = true;
    // 不再默认放行整个 LAN（任意进程）；需要时请在界面显式填写并确认。
    p.lanAllow.clear();
    p.allowLanAnyProcess = false;
    p.strictHash = true;

    NgEndpoint ep;
    ep.name = L"医保前置";
    ep.cidr = L"10.10.10.10/32";
    ep.ports = L"8000-8005";
    ep.proto = L"TCP";
    p.eps.push_back(ep);

    NgEndpoint lan;
    lan.name = L"门店打印机";
    lan.cidr = L"192.168.1.50/32";
    lan.ports = L"9100";
    lan.proto = L"TCP";
    p.eps.push_back(lan);

    // 示例程序用 NetGuard.exe 自身占位（存在、可计算哈希），
    // 避免 StrictHash=1 时生成一条空哈希的无效策略；部署时请在界面替换为医保客户端。
    NgProcEntry pe;
    pe.name = L"示例程序（请替换为医保客户端）";
    pe.path = NgExeDir() + L"\\NetGuard.exe";
    pe.sha256.clear();
    pe.endpoint = L"医保前置";
    pe.enabled = false;
    if (!NgSha256File(pe.path, pe.sha256)) pe.sha256.clear();
    pe.enabled = !pe.sha256.empty();
    p.procs.push_back(pe);

    if (!p.Save(PolicyPath())) { wprintf(L"[x] 写入失败: %s\n", PolicyPath().c_str()); return 1; }
    wprintf(L"[ok] 已生成示例策略: %s\n", PolicyPath().c_str());
    wprintf(L"     StrictHash=1：示例程序已绑定 NetGuard.exe 的 SHA-256，请用管理界面替换为医保客户端。\n");
    wprintf(L"     LanAllow 默认留空（任意进程放行整个网段风险较高），需要时请显式确认。\n");
    wprintf(created ? L"[ok] 已生成新的部署密钥: HKLM\\SOFTWARE\\NetGuard\\PolicyKey\n"
                    : L"[i] 使用现有部署密钥: HKLM\\SOFTWARE\\NetGuard\\PolicyKey\n");
    {
        NgTrialInfo ti;
        if (NgTrialEnsure(ti, true)) {
            if (ti.disabled) wprintf(L"[i] 开发版：60 天试用门禁已禁用\n");
            else wprintf(L"[ok] 60 天试用期已登记（到 %s，剩余 %d 天）\n",
                         NgTrialTimeText(ti.end).c_str(), ti.daysLeft);
        } else {
            wprintf(L"[!] 试用期登记失败: %s\n", ti.error.c_str());
        }
    }
    wprintf(L"     请用管理界面修改（示例里的路径/地址都是占位值）。\n");
    return 0;
}

// 校验并重新签名现有策略（用于把旧版本/手工部署的无签名策略纳入 fail-closed）
static int CmdSignPolicy(int argc, wchar_t** argv)
{
    std::wstring overrideKey;
    if (argc >= 3) {
        if (argc < 4 || !NgIEquals(argv[2], L"--key")) {
            wprintf(L"用法: NetGuard sign [--key <32-256 位十六进制>]\n");
            wprintf(L"      --key 仅用于离线/测试签名，不会读写本机注册表密钥。\n");
            return 1;
        }
        overrideKey = NgTrim(argv[3]);
        if (!NgPolicyKeyIsValid(overrideKey)) {
            wprintf(L"[x] --key 格式无效（应为 32-256 个十六进制字符）。\n");
            return 1;
        }
    }

    // 默认签名使用本机部署密钥，必须管理员；--key 是离线签名，不需要提权
    if (overrideKey.empty() && !NgIsAdmin()) { wprintf(L"[x] 需要管理员权限运行。\n"); return 5; }

    std::wstring key, kerr;
    bool created = false;
    if (overrideKey.empty()) {
        if (!NgPolicyKeyEnsure(key, &kerr, &created)) { wprintf(L"[x] %s\n", kerr.c_str()); return 1; }
    } else {
        key = overrideKey;
    }

    NgPolicy p;
    if (!p.Load(PolicyPath())) { wprintf(L"[x] 无法读取策略文件: %s\n", PolicyPath().c_str()); return 1; }

    bool legacy = !p.hmac.empty() && p.VerifyHmac(NgLegacyPolicyKey());

    std::wstring err;
    if (!p.Validate(err)) { wprintf(L"[x] 策略无效，未签名: %s\n", err.c_str()); return 4; }

    bool ok = overrideKey.empty() ? p.Save(PolicyPath()) : p.SaveWithKey(PolicyPath(), overrideKey);
    if (!ok) { wprintf(L"[x] 写策略失败: %s\n", PolicyPath().c_str()); return 1; }

    wprintf(L"[ok] 策略已重新签名: %s\n", PolicyPath().c_str());
    if (created)       wprintf(L"[ok] 已生成新的部署密钥: HKLM\\SOFTWARE\\NetGuard\\PolicyKey\n");
    if (!overrideKey.empty()) wprintf(L"[i] 使用 --key 指定密钥（离线/测试模式）\n");
    if (legacy)        wprintf(L"[i] 检测到旧版固定密钥签名，已迁移到部署密钥。\n");
    wprintf(L"     注意：sign 会为当前文件内容重新签名，请先确认内容未被篡改；\n");
    wprintf(L"           保存会按规范格式重写文件（注释会丢失）。\n");
    return 0;
}

// 只初始化/读取部署密钥，不改写策略（安装脚本在 verify 之前调用）
static int CmdInitKey()
{
    if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限运行。\n"); return 5; }

    std::wstring key, err;
    bool created = false;
    if (!NgPolicyKeyEnsure(key, &err, &created)) { wprintf(L"[x] %s\n", err.c_str()); return 1; }

    wprintf(created ? L"[ok] 已生成新的策略密钥: HKLM\\SOFTWARE\\NetGuard\\PolicyKey\n"
                    : L"[ok] 策略密钥已存在: HKLM\\SOFTWARE\\NetGuard\\PolicyKey\n");
    {
        NgTrialInfo ti;
        if (NgTrialEnsure(ti, true)) {
            if (ti.disabled) wprintf(L"[i] 开发版：60 天试用门禁已禁用\n");
            else wprintf(L"[ok] 60 天试用期: 到 %s（剩余 %d 天）\n",
                         NgTrialTimeText(ti.end).c_str(), ti.daysLeft);
        } else {
            wprintf(L"[!] 试用期登记失败: %s\n", ti.error.c_str());
        }
    }
    return 0;
}

static int CmdTrial()
{
    NgTrialInfo ti;
    if (!NgTrialEnsure(ti, NgIsAdmin())) {
        wprintf(L"[x] 无法读取试用信息: %s\n", ti.error.c_str());
        return 3;
    }
    if (ti.disabled) {
        wprintf(L"版本: 开发版（60 天试用门禁已临时禁用）\n");
        wprintf(L"[ok] 试用检查已关闭，可直接开发/回归。\n");
        return 0;
    }
    wprintf(L"版本: 60 天试用版\n");
    wprintf(L"试用开始: %s\n", NgTrialTimeText(ti.start).c_str());
    wprintf(L"试用到期: %s\n", NgTrialTimeText(ti.end).c_str());
    if (ti.expired) {
        wprintf(L"[x] 已到期：管控已停止，终端保持联网。\n");
        return 6;
    }
    wprintf(L"[ok] 试用有效，剩余 %d 天。\n", ti.daysLeft);
    return 0;
}

static int TrialGate(const wchar_t* action)
{
    NgTrialInfo ti;
    bool ok = NgTrialEnsure(ti, NgIsAdmin());
    if (ok && ti.disabled) return 0;
    if (ok && !ti.expired) return 0;
    if (!ti.error.empty()) wprintf(L"[x] 试用校验失败: %s\n", ti.error.c_str());
    if (ti.valid && ti.expired)
        wprintf(L"[x] 60 天试用已到期（%s）。\n", NgTrialTimeText(ti.end).c_str());
    else if (!ok)
        wprintf(L"[x] 试用信息未登记或不可读。\n");
    wprintf(L"    %s已停止；已生效的管控会在 30 秒内自动撤销并恢复联网。\n", action);
    wprintf(L"    如需继续使用，请购买正式授权。\n");
    return 6;
}

int wmain(int argc, wchar_t** argv)
{
    // 让 wprintf 按系统 ANSI 代码页转换，否则中文在 cmd 控制台显示为 ?/空白
    _wsetlocale(LC_ALL, L"");
    NgLogInit(NgDataDir());
    if (argc < 2) {
        // 在控制台里手动运行：直接打印用法。
        // 无控制台（由 SCM 启动）才尝试服务分发。
        if (GetConsoleWindow() == nullptr && NgRunService() == 0) return 0;
        Usage();
        return 0;
    }

    std::wstring cmd = NgLower(argv[1]);
    if (cmd == L"--service" || cmd == L"service")   return NgRunService();
    if (cmd == L"--console" || cmd == L"console")   return NgRunConsole();
    if (cmd == L"install")   return NgInstallService();
    if (cmd == L"uninstall") return NgUninstallService();
    if (cmd == L"trial")     return CmdTrial();
    if (cmd == L"apply") {
        int g = TrialGate(L"策略下发");
        if (g) return g;
        return CmdApply();
    }
    if (cmd == L"rollback") {
        if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限运行。\n"); return 5; }
        NgSession sess;
        if (!NgWfpOpen(sess)) { wprintf(L"[x] 无法打开 WFP 会话\n"); return 1; }
        NgResult r = NgWfpRollback(sess);
        NgWfpClose(sess);
        if (r.ok) NgDrvClearWhitelist();
        wprintf(L"%s %s\n", r.ok ? L"[ok]" : L"[x]", r.msg.c_str());
        return r.ok ? 0 : 1;
    }
    if (cmd == L"purge") {
        if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限运行。\n"); return 5; }
        NgResult r = NgWfpPurge();
        wprintf(L"%s %s\n", r.ok ? L"[ok]" : L"[x]", r.msg.c_str());
        return r.ok ? 0 : 1;
    }
    if (cmd == L"ctl") {
        if (argc < 3) { wprintf(L"用法: NetGuard ctl <apply|rollback|status|temp N|report>\n"); return 1; }
        std::wstring sub;
        for (int i = 2; i < argc; i++) { if (i > 2) sub += L" "; sub += argv[i]; }
        std::wstring subLow = NgLower(sub);
        if (subLow.rfind(L"apply", 0) == 0 || subLow.rfind(L"temp", 0) == 0 || subLow.rfind(L"report", 0) == 0) {
            int g = TrialGate(L"该操作");
            if (g) return g;
        }
        DWORD err = 0;
        std::wstring resp = NgIpcSend(sub, 8000, &err);
        if (resp.empty()) { printf("ctl failed: service not running? (err=%lu)\n", err); return 1; }
        printf("%s\n", NgWideToUtf8(resp).c_str());
        return 0;
    }
    if (cmd == L"status")     return CmdStatus();
    if (cmd == L"selftest") {
        int g = TrialGate(L"自检");
        if (g) return g;
        return CmdSelfTest();
    }
    if (cmd == L"test") {
        int g = TrialGate(L"端到端自测");
        if (g) return g;
        return CmdTest();
    }
    if (cmd == L"initpolicy") return CmdInitPolicy();
    if (cmd == L"initkey")    return CmdInitKey();
    if (cmd == L"sign")       return CmdSignPolicy(argc, argv);
    if (cmd == L"temp") {
        int g = TrialGate(L"临时放行");
        if (g) return g;
        int m = (argc >= 3) ? _wtoi(argv[2]) : 60;
        if (m <= 0) m = 60;
        return CmdTemp(m);
    }
    if (cmd == L"hash") {
        if (argc < 3) { wprintf(L"用法: NetGuard hash <文件路径>\n"); return 1; }
        std::wstring h;
        if (!NgSha256File(argv[2], h)) { wprintf(L"[x] 无法读取文件\n"); return 1; }
        wprintf(L"%s\n", h.c_str());
        return 0;
    }
    if (cmd == L"verify") {
        NgPolicy p;
        int rc = LoadPolicyOrDie(p, true);
        if (rc) return rc;
        wprintf(L"[ok] 策略有效，签名通过（未下发）\n");
        for (auto& x : p.procs) {
            if (x.path == L"*") continue;
            std::wstring h;
            if (!NgSha256File(x.path, h)) { wprintf(L"  [!] 程序不存在: %s\n", x.path.c_str()); continue; }
            wprintf(L"  %s  %s\n", (NgIEquals(h, x.sha256) ? L"[哈希匹配]" : L"[哈希不符!]"), x.path.c_str());
        }
        return 0;
    }
    Usage();
    return 0;
}
