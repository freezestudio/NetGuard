#include "ng_ipc.h"
#include <sddl.h>

#pragma comment(lib, "advapi32.lib")

static const wchar_t* PIPE_NAME = L"\\\\.\\pipe\\NetGuardControl";
static HANDLE          g_stop = nullptr;
static HANDLE          g_thread = nullptr;
static NgIpcHandler    g_handler = nullptr;
static PSECURITY_DESCRIPTOR g_sd = nullptr;

// ---------------------------------------------------------------- 读写辅助
static bool ReadAll(HANDLE h, std::string& out)
{
    char buf[1024];
    DWORD r = 0;
    out.clear();
    while (ReadFile(h, buf, sizeof(buf) - 1, &r, nullptr) && r > 0) {
        out.append(buf, r);
        if (out.size() > 64 * 1024) break;
        if (r < sizeof(buf) - 1) break;
    }
    return !out.empty();
}

static void WriteAll(HANDLE h, const std::wstring& text)
{
    std::string u8 = NgWideToUtf8(text);
    DWORD w = 0;
    WriteFile(h, u8.data(), (DWORD)u8.size(), &w, nullptr);
    FlushFileBuffers(h);
}

// ---------------------------------------------------------------- 服务端
static DWORD WINAPI ServerThread(LPVOID)
{
    while (WaitForSingleObject(g_stop, 0) != WAIT_OBJECT_0) {
        SECURITY_ATTRIBUTES sa = { sizeof(sa), g_sd, FALSE };
        HANDLE pipe = CreateNamedPipeW(PIPE_NAME,
                                       PIPE_ACCESS_DUPLEX,
                                       PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
                                       PIPE_UNLIMITED_INSTANCES,
                                       4096, 4096, 1000,
                                       g_sd ? &sa : nullptr);
        if (pipe == INVALID_HANDLE_VALUE) {
            NgLog(L"ipc: CreateNamedPipe 失败 %lu", GetLastError());
            Sleep(2000);
            continue;
        }

        // 等待连接（可被 g_stop 打断）
        BOOL connected = ConnectNamedPipe(pipe, nullptr);
        if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = TRUE;
        if (!connected) { CloseHandle(pipe); continue; }

        std::string req;
        if (ReadAll(pipe, req)) {
            std::wstring cmd = NgTrim(NgUtf8ToWide(req));
            std::wstring resp;
            if (g_handler) resp = g_handler(cmd);
            else resp = L"ERR no handler";
            if (resp.empty()) resp = L"OK";
            WriteAll(pipe, resp);
        }
        FlushFileBuffers(pipe);
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
    }
    return 0;
}

bool NgIpcStartServer(NgIpcHandler handler, const wchar_t* clientSddl)
{
    if (g_thread) return true;
    g_handler = handler;
    if (clientSddl && *clientSddl) {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                clientSddl, SDDL_REVISION_1, &g_sd, nullptr)) {
            NgLog(L"ipc: SDDL 解析失败 %lu", GetLastError());
            g_sd = nullptr;
        }
    }
    g_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_thread = CreateThread(nullptr, 0, ServerThread, nullptr, 0, nullptr);
    NgLog(L"ipc: server started (%s)", g_thread ? L"ok" : L"failed");
    return g_thread != nullptr;
}

void NgIpcStopServer()
{
    if (g_stop) SetEvent(g_stop);
    // 唤醒阻塞中的 ConnectNamedPipe
    HANDLE h = CreateFileW(PIPE_NAME, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    if (g_thread) { WaitForSingleObject(g_thread, 3000); CloseHandle(g_thread); g_thread = nullptr; }
    if (g_stop) { CloseHandle(g_stop); g_stop = nullptr; }
    if (g_sd) { LocalFree(g_sd); g_sd = nullptr; }
}

// ---------------------------------------------------------------- 客户端
std::wstring NgIpcSend(const std::wstring& cmd, DWORD timeoutMs, DWORD* errOut)
{
    DWORD err = 0;
    HANDLE pipe = INVALID_HANDLE_VALUE;
    DWORD t0 = GetTickCount();
    for (;;) {
        pipe = CreateFileW(PIPE_NAME, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (pipe != INVALID_HANDLE_VALUE) break;
        err = GetLastError();
        if (err != ERROR_PIPE_BUSY || GetTickCount() - t0 > timeoutMs) break;
        WaitNamedPipeW(PIPE_NAME, 500);
    }
    if (pipe == INVALID_HANDLE_VALUE) {
        if (errOut) *errOut = err;
        return L"";
    }
    DWORD mode = PIPE_READMODE_MESSAGE;
    SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);

    WriteAll(pipe, cmd);
    std::string resp;
    ReadAll(pipe, resp);
    CloseHandle(pipe);
    if (errOut) *errOut = 0;
    return NgTrim(NgUtf8ToWide(resp));
}
