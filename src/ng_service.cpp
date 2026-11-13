#include "ng_common.h"
#include "ng_policy.h"
#include "ng_wfp.h"
#include "ng_ipc.h"
#include "ng_trial.h"
#include "ng_drv.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdio>
#include <mutex>
#include <map>

#pragma comment(lib, "ws2_32.lib")

static SERVICE_STATUS_HANDLE g_ssh = nullptr;
static SERVICE_STATUS        g_ss = {};
static HANDLE                g_stopEvent = nullptr;
static bool                  g_stop = false;
static volatile LONG         g_lastApplied = 0;
static NgSession             g_sess;
// 看门狗线程与 IPC 线程都会操作 WFP，必须串行化事务
static std::mutex            g_wfpMutex;

static std::wstring PolicyPath() { return NgDataDir() + L"\\policy.ini"; }
static std::wstring ResultPath() { return NgDataDir() + L"\\selftest.txt"; }

static bool TrialAllowsEnforcement(std::wstring* why);

// ---------------------------------------------------------------- 连通性探测
static bool TryConnect(const char* ip, int port, DWORD timeoutMs, int& wsaErr)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) { wsaErr = WSAGetLastError(); return false; }
    sockaddr_in sa = {};
    sa.sin_family = AF_INET;
    sa.sin_port = htons((u_short)port);
    inet_pton(AF_INET, ip, &sa.sin_addr);
    u_long nb = 1;
    ioctlsocket(s, FIONBIO, &nb);
    bool connected = false;
    wsaErr = 0;
    int rc = connect(s, (sockaddr*)&sa, sizeof(sa));
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
            wsaErr = soErr;
            connected = (soErr == 0);
        } else wsaErr = WSAETIMEDOUT;
    } else wsaErr = WSAGetLastError();
    closesocket(s);
    return connected;
}

// 自检：报告哪些外网目标仍可连接（0 = 都被拦住）
static int RunSelfTest(const wchar_t* tag, std::wstring* detail)
{
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    struct T { const char* ip; int port; const char* label; };
    T targets[] = {
        { "172.30.18.120", 3389, "Win10-RDP(local)" },
        { "8.8.8.8", 53, "GoogleDNS" },
        { "114.114.114.114", 53, "NS-China" },
        { "1.1.1.1", 443, "Cloudflare" },
        { "180.101.49.12", 443, "Baidu" },
    };
    int leaked = 0;
    std::wstring d;
    for (auto& t : targets) {
        int err = 0;
        bool ok = TryConnect(t.ip, t.port, 2000, err);
        wchar_t line[256];
        _snwprintf_s(line, _TRUNCATE, L"  %-16hs:%-5d %-12hs %s (err=%d)\r\n",
                     t.ip, t.port, t.label, ok ? L"CONNECTED" : L"blocked", err);
        d += line;
        if (ok) leaked++;
    }
    WSACleanup();

    std::wstring full;
    wchar_t head[128];
    _snwprintf_s(head, _TRUNCATE, L"[%s] leaked=%d\r\n", tag, leaked);
    full = head + d;

    // 追加写结果文件
    CreateDirectoryW(NgDataDir().c_str(), nullptr);
    HANDLE h = CreateFileW(ResultPath().c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h != INVALID_HANDLE_VALUE) {
        std::string u8 = NgWideToUtf8(full);
        DWORD w = 0;
        WriteFile(h, u8.data(), (DWORD)u8.size(), &w, nullptr);
        CloseHandle(h);
    }
    if (detail) *detail = full;
    NgLog(L"selftest[%s]: leaked=%d", tag, leaked);
    return leaked;
}

static bool TempActive(const NgPolicy& p) { return p.tempAllowUntil > NgUnixNow(); }

// ---------------------------------------------------------------- 审计日志
static void AuditLog(const std::wstring& ev)
{
    CreateDirectoryW(NgDataDir().c_str(), nullptr);
    std::wstring path = NgDataDir() + L"\\audit.log";
    HANDLE h = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME st; GetLocalTime(&st);
    wchar_t line[1024];
    _snwprintf_s(line, _TRUNCATE, L"%04d-%02d-%02d %02d:%02d:%02d  %s\r\n",
                 st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, ev.c_str());
    std::string u8 = NgWideToUtf8(line);
    DWORD w = 0;
    WriteFile(h, u8.data(), (DWORD)u8.size(), &w, nullptr);
    CloseHandle(h);
}

// ---------------------------------------------------------------- 哈希运行时校验
// 每 5 秒做一次“元数据快检”（大小/修改时间）；每 30 秒做一次完整 SHA-256。
// 这样替换后通常 5 秒内就能发现，同时避免每 5 秒读整个大文件。
struct NgHashCache {
    ULONGLONG size = 0;
    FILETIME mtime = {};
    std::wstring expected;
    bool ok = false;
};
static std::map<std::wstring, NgHashCache> g_hashCache;

static bool VerifyHashes(bool force)
{
    NgPolicy p;
    if (!p.Load(PolicyPath())) return false;

    std::wstring key, kerr;
    if (!NgPolicyKeyRead(key, &kerr)) {
        NgLog(L"hash: %s，跳过校验（不改写、不重签）", kerr.c_str());
        AuditLog(L"ALERT hash-skip-key-unavailable");
        return false;
    }
    // 绝不能对未签名/签名无效的策略做“改写 + 重签名”，否则等于替篡改后的内容背书
    if (p.hmac.empty() || !p.VerifyHmac(key)) {
        NgLog(L"hash: 策略签名缺失/无效，跳过校验（不改写、不重签）");
        AuditLog(L"ALERT hash-skip-invalid-signature");
        return false;
    }

    bool changed = false;
    for (auto& e : p.procs) {
        if (!e.enabled) continue;
        if (e.path == L"*" || e.sha256.empty()) continue;

        WIN32_FILE_ATTRIBUTE_DATA fad = {};
        if (!GetFileAttributesExW(e.path.c_str(), GetFileExInfoStandard, &fad)) {
            NgLog(L"hash: 文件不存在/不可读 %s", e.path.c_str());
            AuditLog(L"ALERT program-missing " + e.path);
            e.enabled = false; changed = true;
            g_hashCache.erase(e.path);
            continue;
        }

        ULONGLONG size = ((ULONGLONG)fad.nFileSizeHigh << 32) | fad.nFileSizeLow;
        auto it = g_hashCache.find(e.path);
        bool cacheHit = it != g_hashCache.end()
                        && it->second.size == size
                        && CompareFileTime(&it->second.mtime, &fad.ftLastWriteTime) == 0
                        && NgIEquals(it->second.expected, e.sha256)
                        && it->second.ok;
        if (!force && cacheHit) continue;   // 元数据没变，且上次哈希匹配

        std::wstring h;
        if (!NgSha256File(e.path, h)) {
            NgLog(L"hash: 文件不存在/不可读 %s", e.path.c_str());
            AuditLog(L"ALERT program-missing " + e.path);
            e.enabled = false; changed = true;
            g_hashCache.erase(e.path);
            continue;
        }
        bool ok = NgIEquals(h, e.sha256);
        NgHashCache c;
        c.size = size;
        c.mtime = fad.ftLastWriteTime;
        c.expected = e.sha256;
        c.ok = ok;
        g_hashCache[e.path] = c;

        if (!ok) {
            NgLog(L"hash: 哈希不匹配（文件被替换？）%s", e.path.c_str());
            AuditLog(L"ALERT hash-changed " + e.path + L" expected=" + e.sha256 + L" actual=" + h);
            e.enabled = false; changed = true;
        }
    }
    if (changed) {
        if (!p.Save(PolicyPath())) {
            // 不能带着“未写回”的旧策略重新 apply，否则会把被替换的程序又放回来
            NgLog(L"hash: 策略写回失败，保持现有过滤器（未重新下发）");
            AuditLog(L"ALERT policy-save-failed after hash revoke");
            return false;
        }
        AuditLog(L"ACTION revoked-mismatched-programs and re-sign policy");
    }
    return changed;
}

static bool ApplyOnce(const char* why)
{
    NgPolicy p;
    if (!p.Load(PolicyPath())) { NgLog(L"apply(%hs): 无策略文件", why); return false; }

    std::wstring key, kerr;
    if (!NgPolicyKeyRead(key, &kerr)) {
        NgLog(L"apply(%hs): %s，拒绝下发", why, kerr.c_str());
        AuditLog(std::wstring(L"ALERT policy-key-unavailable source=") + NgUtf8ToWide(why));
        return false;
    }
    if (p.hmac.empty() || !p.VerifyHmac(key)) {
        const wchar_t* reason = p.hmac.empty() ? L"缺失" : L"无效";
        NgLog(L"apply(%hs): 策略签名%s，拒绝下发", why, reason);
        AuditLog(std::wstring(L"ALERT policy-signature-") +
                 (p.hmac.empty() ? L"missing" : L"invalid") +
                 L" source=" + NgUtf8ToWide(why));
        return false;
    }
    std::wstring err;
    if (!p.Validate(err)) { NgLog(L"apply(%hs): 策略无效: %s", why, err.c_str()); return false; }

    NgPolicy use = p;
    if (TempActive(p)) use.defaultDeny = false;

    // 先更新驱动门禁，再下发用户态 WFP 过滤器：避免“用户态已 permit、
    // 驱动还没收到新哈希”的毫秒级窗口。失败时驱动保持旧/新列表，均为 fail-safe。
    if (use.defaultDeny) NgDrvSendWhitelist(use);
    else                 NgDrvClearWhitelist();

    NgResult r;
    {
        std::lock_guard<std::mutex> lk(g_wfpMutex);
        r = NgWfpApply(g_sess, use);
    }
    if (r.ok) {
        InterlockedExchange(&g_lastApplied, (LONG)NgUnixNow());
        NgLog(L"apply(%hs): ok, filters=%d, temp=%d", why, r.filters, TempActive(p) ? 1 : 0);
        return true;
    }
    NgLog(L"apply(%hs): 失败 %s", why, r.msg.c_str());
    return false;
}

// ---------------------------------------------------------------- 看门狗
static void WatchdogLoop()
{
    int tick = 0;
    for (;;) {
        if (WaitForSingleObject(g_stopEvent, 5000) == WAIT_OBJECT_0) break;
        tick++;
        bool deep = (tick % 6 == 0);   // 每 30 秒做一次完整检查

        // 试用到期：立即撤销管控，保持终端联网（不要让试用过期变成断网事故）
        if (!TrialAllowsEnforcement(nullptr)) {
            if (NgWfpLastCount() != 0) {
                NgLog(L"watchdog: 试用已到期/无效，撤销过滤器并保持联网");
                std::lock_guard<std::mutex> lk(g_wfpMutex);
                NgWfpRollback(g_sess);
                NgDrvClearWhitelist();
                AuditLog(L"ACTION trial-expired-rollback");
            }
            continue;
        }

        NgPolicy p;
        p.Load(PolicyPath());

        if (!p.defaultDeny || TempActive(p)) {
            // 放行模式：确认没有残留的拒绝过滤器
            if (NgWfpLastCount() != 0) {
                NgLog(L"watchdog: 放行模式，撤销过滤器");
                std::lock_guard<std::mutex> lk(g_wfpMutex);
                NgWfpRollback(g_sess);
            }
            NgDrvClearWhitelist();
            continue;
        }

        // 过滤器存活检查每 30 秒；哈希检查每 5 秒（元数据快检）+ 30 秒完整校验。
        if (deep) {
            int expected = NgWfpLastCount();
            int live = 0;
            {
                std::lock_guard<std::mutex> lk(g_wfpMutex);
                live = NgWfpLiveCount(g_sess);
            }
            if (expected == 0 || live < expected) {
                NgLog(L"watchdog: 过滤器缺失（实际 %d / 期望 %d），重新下发", live, expected);
                AuditLog(L"ALERT filters-removed count=" + std::to_wstring(live) +
                         L" expected=" + std::to_wstring(expected));
                ApplyOnce("watchdog-reapply");
            }
            // 驱动可能比服务晚启动；每 30 秒重新下发一次白名单（幂等）。
            NgDrvSendWhitelist(p);
        }

        // 快速哈希检查：文件大小/修改时间变化时立即重新计算；每 30 秒强制完整校验。
        if (VerifyHashes(deep)) {
            NgLog(L"watchdog: 哈希变更，重新下发策略");
            ApplyOnce("hash-reapply");
        }
    }
}

// ---------------------------------------------------------------- 服务入口
static void WINAPI Handler(DWORD ctrl)
{
    if (ctrl == SERVICE_CONTROL_STOP || ctrl == SERVICE_CONTROL_SHUTDOWN) {
        g_stop = true;
        if (g_stopEvent) SetEvent(g_stopEvent);
        g_ss.dwCurrentState = SERVICE_STOP_PENDING;
        g_ss.dwWaitHint = 5000;
        SetServiceStatus(g_ssh, &g_ss);
    }
}

// ---------------------------------------------------------------- IPC 命令处理
static bool TrialAllowsEnforcement(std::wstring* why)
{
    NgTrialInfo ti;
    if (!NgTrialEnsure(ti, true)) {
        if (why) *why = ti.error.empty() ? L"试用信息不可读" : ti.error;
        return false;
    }
    if (ti.expired) {
        if (why) *why = L"试用已到期";
        return false;
    }
    return true;
}

static std::wstring ServiceHandler(const std::wstring& cmd)
{
    std::wstring c = NgLower(NgTrim(cmd));
    NgLog(L"ipc: cmd=%s", c.c_str());

    if (c == L"apply" || c == L"reload") {
        if (!TrialAllowsEnforcement(nullptr)) {
            AuditLog(L"ALERT trial-expired ipc-apply");
            return L"ERR trial-expired";
        }
        bool ok = ApplyOnce("ipc-apply");
        AuditLog(L"ACTION ipc-apply ok=" + std::to_wstring(ok ? 1 : 0) + L" filters=" + std::to_wstring(NgWfpLastCount()));
        return ok ? (L"OK filters=" + std::to_wstring(NgWfpLastCount())) : L"ERR apply-failed(see ng.log)";
    }
    if (c == L"rollback") {
        NgResult r;
        {
            std::lock_guard<std::mutex> lk(g_wfpMutex);
            r = NgWfpRollback(g_sess);
        }
        NgDrvClearWhitelist();
        AuditLog(L"ACTION ipc-rollback");
        return r.ok ? L"OK rolled-back" : (L"ERR " + r.msg);
    }
    if (c == L"status") {
        NgPolicy p;
        p.Load(PolicyPath());
        int live = 0;
        {
            std::lock_guard<std::mutex> lk(g_wfpMutex);
            live = NgWfpLiveCount(g_sess);
        }
        std::wstring key, kerr;
        bool keyOk = NgPolicyKeyRead(key, &kerr);
        std::wstring s;
        s += L"filters=" + std::to_wstring(NgWfpLastCount()) + L"\n";
        s += L"filters_live=" + std::to_wstring(live) + L"\n";
        s += L"default_deny=" + std::to_wstring(p.defaultDeny ? 1 : 0) + L"\n";
        s += L"endpoints=" + std::to_wstring((int)p.eps.size()) + L"\n";
        s += L"programs=" + std::to_wstring((int)p.procs.size()) + L"\n";
        s += L"temp_until=" + std::to_wstring((unsigned long long)p.tempAllowUntil) + L"\n";
        s += L"key_ok=" + std::to_wstring(keyOk ? 1 : 0) + L"\n";
        s += L"hmac_ok=" + std::to_wstring(keyOk && !p.hmac.empty() && p.VerifyHmac(key) ? 1 : 0) + L"\n";
        {
            NgTrialInfo ti;
            bool tok = NgTrialEnsure(ti, true);
            s += L"trial_valid=" + std::to_wstring(tok ? 1 : 0) + L"\n";
            s += L"trial_expired=" + std::to_wstring((tok && ti.expired) ? 1 : 0) + L"\n";
            s += L"trial_disabled=" + std::to_wstring((tok && ti.disabled) ? 1 : 0) + L"\n";
            s += L"trial_days=" + std::to_wstring(tok ? ti.daysLeft : 0) + L"\n";
        }
        return s;
    }
    if (c.rfind(L"temp ", 0) == 0) {
        if (!TrialAllowsEnforcement(nullptr)) {
            AuditLog(L"ALERT trial-expired ipc-temp");
            return L"ERR trial-expired";
        }
        int m = _wtoi(c.c_str() + 5);
        if (m <= 0) m = 60;
        NgPolicy p;
        if (!p.Load(PolicyPath())) return L"ERR no policy";
        std::wstring key, kerr;
        if (!NgPolicyKeyRead(key, &kerr) || p.hmac.empty() || !p.VerifyHmac(key)) {
            AuditLog(L"ALERT temp-rejected-invalid-signature");
            return L"ERR policy-not-signed";
        }
        p.tempAllowUntil = NgUnixNow() + (unsigned long long)m * 60ULL;
        if (!p.Save(PolicyPath())) return L"ERR save-failed";
        {
            std::lock_guard<std::mutex> lk(g_wfpMutex);
            NgWfpRollback(g_sess);
        }
        NgDrvClearWhitelist();
        AuditLog(L"ACTION ipc-temp " + std::to_wstring(m) + L"min");
        return L"OK temp=" + std::to_wstring(m) + L"min";
    }
    if (c == L"report") {
        AuditLog(L"ACTION ipc-report");
        return L"OK audit=" + NgDataDir() + L"\\audit.log";
    }
    return L"ERR unknown-command";
}

static void WINAPI ServiceMain(DWORD, LPWSTR*)
{
    g_ssh = RegisterServiceCtrlHandlerW(L"NetGuard", Handler);
    if (!g_ssh) return;

    g_ss.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_ss.dwCurrentState = SERVICE_START_PENDING;
    g_ss.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    g_ss.dwWaitHint = 10000;
    SetServiceStatus(g_ssh, &g_ss);

    NgLogInit(NgDataDir());
    NgLog(L"service: starting");
    g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!NgWfpOpen(g_sess)) NgLog(L"service: WFP 会话打开失败");

    // 测试模式：存在 TESTONCE.flag 时跑一次 前/后 对比并回滚
    {
        std::wstring flag = L"C:\\NetGuard\\TESTONCE.flag";
        if (GetFileAttributesW(flag.c_str()) != INVALID_FILE_ATTRIBUTES) {
            NgLog(L"service: TEST MODE");
            // 等网络就绪（最多 60 秒），否则基线自检没有意义
            {
                bool ready = false;
                for (int i = 0; i < 30; i++) {
                    int e = 0;
                    if (TryConnect("114.114.114.114", 53, 1500, e)) { ready = true; break; }
                    Sleep(2000);
                }
                NgLog(L"service: network ready=%d", ready ? 1 : 0);
            }
            RunSelfTest(L"before-apply", nullptr);
            ApplyOnce("test-apply");
            RunSelfTest(L"after-apply", nullptr);
            Sleep(3000);
            NgResult rr;
            {
                std::lock_guard<std::mutex> lk(g_wfpMutex);
                rr = NgWfpRollback(g_sess);
            }
            NgLog(L"test: rollback %s", rr.msg.c_str());
            NgDrvClearWhitelist();
            RunSelfTest(L"after-rollback", nullptr);
            DeleteFileW(flag.c_str());
            g_ss.dwCurrentState = SERVICE_RUNNING;
            SetServiceStatus(g_ssh, &g_ss);
            NgLog(L"service: TEST DONE");
            return;   // 服务结束（保持运行中的过滤器已撤销）
        }
    }

    // 1) 试用期检查：到期/无效则不下发，保持联网（避免试用过期导致门店断网）
    std::wstring twhy;
    bool trialOk = TrialAllowsEnforcement(&twhy);
    if (!trialOk) {
        NgLog(L"service: 试用不可用（%s），不下发管控", twhy.c_str());
        AuditLog(L"ALERT trial-blocked service-start " + twhy);
    } else {
        ApplyOnce("service-start");
        RunSelfTest(L"after-apply", nullptr);
    }
    // 3) 开管道，供 UI/命令行下发指令（仅 Administrators 与 SYSTEM 可连）
    NgIpcStartServer(ServiceHandler, L"D:(A;;GA;;;BA)(A;;GA;;;SY)");
    AuditLog(L"ACTION service-start filters=" + std::to_wstring(NgWfpLastCount()));

    g_ss.dwCurrentState = SERVICE_RUNNING;
    g_ss.dwWaitHint = 0;
    SetServiceStatus(g_ssh, &g_ss);

    WatchdogLoop();

    NgIpcStopServer();
    NgDrvClearWhitelist();
    NgLog(L"service: stopping (过滤器保留)");
    if (g_stopEvent) CloseHandle(g_stopEvent);
    g_ss.dwCurrentState = SERVICE_STOPPED;
    SetServiceStatus(g_ssh, &g_ss);
}

int NgRunService()
{
    SERVICE_TABLE_ENTRYW table[] = {
        { (LPWSTR)L"NetGuard", (LPSERVICE_MAIN_FUNCTIONW)ServiceMain },
        { nullptr, nullptr }
    };
    if (!StartServiceCtrlDispatcherW(table)) {
        // 不是由 SCM 启动（手动运行）
        wprintf(L"[i] 不是以服务方式启动（错误 %lu）。用 --console 直接在前台运行。\n", GetLastError());
        return 1;
    }
    return 0;
}

// 前台模式（调试用）
static BOOL WINAPI ConsoleCtrl(DWORD)
{
    g_stop = true;
    if (g_stopEvent) SetEvent(g_stopEvent);
    return TRUE;
}

int NgRunConsole()
{
    NgLogInit(NgDataDir());
    NgLog(L"console: starting");
    g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    SetConsoleCtrlHandler(ConsoleCtrl, TRUE);
    ApplyOnce("console");
    RunSelfTest(L"console-after-apply", nullptr);
    wprintf(L"策略已下发，自检结果见 %s\n按 Ctrl+C 退出（过滤器保留）...\n", ResultPath().c_str());
    for (;;) {
        if (WaitForSingleObject(g_stopEvent, 1000) == WAIT_OBJECT_0) break;
        static int tick = 0;
        if (++tick % 30 == 0) {
            NgPolicy p; p.Load(PolicyPath());
            if (p.defaultDeny && !TempActive(p) && NgWfpLastCount() < 4) ApplyOnce("console-watchdog");
        }
    }
    return 0;
}

// ---------------------------------------------------------------- 安装/卸载
int NgInstallService()
{
    if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限。\n"); return 5; }

    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);

    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CREATE_SERVICE);
    if (!scm) { wprintf(L"[x] OpenSCManager 失败: %s\n", NgWin32Error(GetLastError()).c_str()); return 1; }

    SC_HANDLE svc = CreateServiceW(scm, L"NetGuard", L"NetGuard Egress Control",
                                   SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START,
                                   SERVICE_ERROR_NORMAL, exe, nullptr, nullptr, nullptr, L"LocalSystem", nullptr);
    if (!svc) {
        DWORD e = GetLastError();
        if (e == ERROR_SERVICE_EXISTS) {
            wprintf(L"[i] 服务已存在，更新启动类型为自动。\n");
            svc = OpenServiceW(scm, L"NetGuard", SERVICE_ALL_ACCESS);
            if (svc) ChangeServiceConfigW(svc, SERVICE_NO_CHANGE, SERVICE_AUTO_START, SERVICE_NO_CHANGE,
                                          exe, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
        } else {
            wprintf(L"[x] CreateService 失败: %s\n", NgWin32Error(e).c_str());
            CloseServiceHandle(scm);
            return 1;
        }
    }
    if (svc) {
        SERVICE_DESCRIPTIONW desc = { (LPWSTR)L"药店终端出网白名单：默认拒绝，仅放行业务地址/程序" };
        ChangeServiceConfig2W(svc, SERVICE_CONFIG_DESCRIPTION, &desc);
        wprintf(L"[ok] 服务已安装（自动启动）。\n");
        CloseServiceHandle(svc);
    }
    CloseServiceHandle(scm);
    return 0;
}

int NgUninstallService()
{
    if (!NgIsAdmin()) { wprintf(L"[x] 需要管理员权限。\n"); return 5; }
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!scm) { wprintf(L"[x] OpenSCManager 失败\n"); return 1; }
    SC_HANDLE svc = OpenServiceW(scm, L"NetGuard", DELETE | SERVICE_STOP);
    if (!svc) { wprintf(L"[x] 打开服务失败: %s\n", NgWin32Error(GetLastError()).c_str()); CloseServiceHandle(scm); return 1; }
    SERVICE_STATUS st;
    ControlService(svc, SERVICE_CONTROL_STOP, &st);
    DeleteService(svc);
    CloseServiceHandle(svc);
    CloseServiceHandle(scm);
    // 过滤器是会话级的：服务进程退出后自动消失，不需要在卸载进程里再操作 WFP
    wprintf(L"[ok] 服务已删除（会话级过滤器随服务进程退出自动消失）\n");
    return 0;
}
