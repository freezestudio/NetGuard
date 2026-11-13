// NetGuardUI - Win32 管理界面（无 .NET / 无 MFC）
#include "ng_common.h"
#include "ng_policy.h"
#include "ng_ipc.h"
#include "ng_trial.h"
#include <commctrl.h>
#include <windowsx.h>
#include <commdlg.h>
#include <shellapi.h>
#include <aclapi.h>
#include <sddl.h>
#include <cstdio>
#include <sstream>
#include <commctrl.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "advapi32.lib")

static NgPolicy g_pol;
static HWND g_main, g_listEp, g_listPr;
static HFONT g_font = nullptr;
static std::wstring g_shotPath;
static std::wstring g_passArg;   // --password <pw>：仅供自动化测试
static int g_dpi = 96;

// Win32 坐标是物理像素；进程声明 DPI 感知后必须自己按系统 DPI 缩放，
// 否则 125%/150% 下固定像素高度的对话框会把底部按钮切掉。
static int Dpi(int v) { return MulDiv(v, g_dpi, 96); }

// 主窗口布局最多按 150% 放大，避免 200% 缩放时右侧面板把左侧列表挤没。
static int Ui(int v)
{
    int s = g_dpi > 144 ? 144 : g_dpi;
    return MulDiv(v, s, 96);
}

static void InitDpi()
{
    HDC dc = GetDC(nullptr);
    int dpi = dc ? GetDeviceCaps(dc, LOGPIXELSY) : 96;
    if (dc) ReleaseDC(nullptr, dc);
    if (dpi < 96) dpi = 96;
    if (dpi > 480) dpi = 96;
    g_dpi = dpi;
}

static void CenterTopmost(HWND hwnd, int w, int h, HWND owner)
{
    // 用自身分辨率计算居中，并强制置顶（不依赖未初始化的 RECT / 多显示器信息）
    HMONITOR mon = owner ? MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST)
                         : MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = { sizeof(mi) };
    RECT wa = { 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) };
    if (GetMonitorInfoW(mon, &mi)) wa = mi.rcWork;
    int availW = wa.right - wa.left;
    int availH = wa.bottom - wa.top;
    if (w > availW) w = availW;
    if (h > availH) h = availH;
    int cx = wa.left + (availW - w) / 2;
    int cy = wa.top + (availH - h) / 2;
    if (cx < wa.left) cx = wa.left;
    if (cy < wa.top) cy = wa.top;
    SetWindowPos(hwnd, HWND_TOPMOST, cx, cy, w, h, SWP_SHOWWINDOW);
    NgLog(L"dialog: workarea=%ld,%ld,%ld,%ld  dpi=%d  dlg=%dx%d  pos=%d,%d",
          wa.left, wa.top, wa.right, wa.bottom, g_dpi, w, h, cx, cy);
}

static void SetFontAll(HWND parent)
{
    if (!g_font) return;
    EnumChildWindows(parent, [](HWND c, LPARAM lp) -> BOOL {
        SendMessageW(c, WM_SETFONT, (WPARAM)lp, TRUE);
        return TRUE;
    }, (LPARAM)g_font);
}

static HWND g_chkDeny, g_chkDhcp, g_chkLoop, g_edtLan, g_edtDns, g_edtTemp, g_stStatus;
static std::wstring g_policyPath;
static bool g_selftest = false;

static std::wstring PolicyPath() { return NgDataDir() + L"\\policy.ini"; }
static std::wstring AdminPath()  { return NgDataDir() + L"\\admin.dat"; }

// admin.dat 里有盐和口令哈希；收紧为仅 SYSTEM / Administrators 可读写，
// 避免数据目录的 Users:(RX) 让普通用户拿到离线爆破材料。
static void HardenAdminFileAcl()
{
    std::wstring path = AdminPath();
    if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) return;

    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;FA;;;SY)(A;;FA;;;BA)", SDDL_REVISION_1, &sd, nullptr))
        return;

    BOOL present = FALSE, defaulted = FALSE;
    PACL dacl = nullptr;
    if (GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted) && present && dacl) {
        SetNamedSecurityInfoW((LPWSTR)path.c_str(), SE_FILE_OBJECT,
                              DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                              nullptr, nullptr, dacl, nullptr);
    }
    LocalFree(sd);
}

// ---------------------------------------------------------------- 管理员口令
static bool SaveAdminPassword(const std::wstring& pass)
{
    CreateDirectoryW(NgDataDir().c_str(), nullptr);
    std::wstring salt = NgRandomHex(16);
    std::wstring hash;
    if (!NgHmacSha256Hex(NgWideToUtf8(salt), NgWideToUtf8(pass), hash)) return false;
    std::wstring text = salt + L"\r\n" + hash + L"\r\n";
    HANDLE h = CreateFileW(AdminPath().c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_HIDDEN, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    std::string u8 = NgWideToUtf8(text);
    DWORD w = 0;
    WriteFile(h, u8.data(), (DWORD)u8.size(), &w, nullptr);
    CloseHandle(h);
    HardenAdminFileAcl();
    return true;
}

static bool CheckAdminPassword(const std::wstring& pass)
{
    HANDLE h = CreateFileW(AdminPath().c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    std::string buf;
    char tmp[4096];
    DWORD r = 0;
    while (ReadFile(h, tmp, sizeof(tmp), &r, nullptr) && r > 0) buf.append(tmp, r);
    CloseHandle(h);
    std::wstring text = NgUtf8ToWide(buf);
    auto nl = text.find(L'\n');
    std::wstring salt = NgTrim(text.substr(0, nl));
    std::wstring hash = NgTrim(text.substr(nl + 1));
    std::wstring calc;
    if (!NgHmacSha256Hex(NgWideToUtf8(salt), NgWideToUtf8(pass), calc)) return false;
    return NgIEquals(NgTrim(hash), calc);
}

// ---------------------------------------------------------------- 通用输入对话框
struct InputDlg {
    const wchar_t* title;
    const wchar_t* label;
    std::wstring value;
    bool password;
    bool ok;
    HWND hEdit;
};

static InputDlg* g_pIn = nullptr;

// 自定义模态窗口不是真正的 Dialog，IsDialogMessage 不会替我们处理回车/Esc。
// 这里显式映射到默认按钮，否则“确定”按钮只能点、按回车无效。
static void PumpModal(HWND h)
{
    MSG msg;
    while (IsWindow(h) && GetMessageW(&msg, nullptr, 0, 0)) {
        if (msg.message == WM_KEYDOWN && msg.wParam == VK_RETURN) {
            SendMessageW(h, WM_COMMAND, MAKEWPARAM(IDOK, 0), 0);
            continue;
        }
        if (msg.message == WM_KEYDOWN && msg.wParam == VK_ESCAPE) {
            SendMessageW(h, WM_COMMAND, MAKEWPARAM(IDCANCEL, 0), 0);
            continue;
        }
        if (!IsDialogMessageW(h, &msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    }
}

static LRESULT CALLBACK InputWndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    InputDlg* d = g_pIn;
    if (!d) return DefWindowProcW(h, m, w, l);
    switch (m) {
    case WM_COMMAND:
        if (LOWORD(w) == IDOK) {
            NgLog(L"ask: IDOK hEdit=%p", (void*)d->hEdit);
            wchar_t b[512] = {};
            GetWindowTextW(d->hEdit, b, 512);
            NgLog(L"ask: text len=%d", (int)wcslen(b));
            d->value = b; d->ok = true;
            DestroyWindow(h);
            NgLog(L"ask: destroyed");
            return 0;
        }
        if (LOWORD(w) == IDCANCEL) { d->ok = false; DestroyWindow(h); return 0; }
        break;
    case WM_CLOSE: d->ok = false; DestroyWindow(h); return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

static bool AskText(HWND parent, const wchar_t* title, const wchar_t* label, std::wstring& value, bool password = false)
{
    static bool reg = false;
    if (!reg) {
        WNDCLASSW wc = {};
        wc.lpfnWndProc = InputWndProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"NgInputWnd";
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
        RegisterClassW(&wc);
        reg = true;
    }
    InputDlg d = { title, label, value, password, false, nullptr };
    g_pIn = &d;                     // 窗口过程通过它访问输入框（此前漏赋值导致按钮无响应）

    // 先确定“客户区”尺寸，再用 AdjustWindowRectEx 反推外框。
    // 直接给 CreateWindow 传 440x180 时，标题栏和边框会吃掉客户区高度，
    // 在高 DPI 下底部按钮就会被裁掉。
    const int clientW = Dpi(480);
    const int clientH = Dpi(220);
    RECT rc = { 0, 0, clientW, clientH };
    DWORD style = WS_POPUP | WS_CAPTION | WS_SYSMENU;
    DWORD exStyle = WS_EX_DLGMODALFRAME | WS_EX_TOPMOST;
    AdjustWindowRectEx(&rc, style, FALSE, exStyle);
    const int winW = rc.right - rc.left;
    const int winH = rc.bottom - rc.top;

    HWND h = CreateWindowExW(exStyle, L"NgInputWnd", title, style,
                             0, 0, winW, winH,
                             parent, nullptr, GetModuleHandleW(nullptr), nullptr);

    const int margin = Dpi(20);
    const int editH = Dpi(28);
    const int btnH = Dpi(30);
    const int btnW = Dpi(96);
    const int btnGap = Dpi(12);

    CreateWindowW(L"STATIC", label, WS_CHILD | WS_VISIBLE | SS_LEFT,
                  margin, Dpi(16), clientW - margin * 2, Dpi(46), h, nullptr, nullptr, nullptr);
    // 只用一种边框：WS_EX_CLIENTEDGE；再叠加 WS_BORDER 会出现“双层虚线框”。
    DWORD es = WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL;
    if (password) es |= ES_PASSWORD;
    d.hEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", value.c_str(), es,
                              margin, Dpi(68), clientW - margin * 2, editH, h, (HMENU)100, nullptr, nullptr);
    SendMessageW(d.hEdit, EM_SETLIMITTEXT, 255, 0);

    const int by = clientH - margin - btnH;
    const int okX = clientW - margin - btnW * 2 - btnGap;
    CreateWindowW(L"BUTTON", L"确定", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                  okX, by, btnW, btnH, h, (HMENU)IDOK, nullptr, nullptr);
    CreateWindowW(L"BUTTON", L"取消", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                  okX + btnW + btnGap, by, btnW, btnH, h, (HMENU)IDCANCEL, nullptr, nullptr);
    if (g_font) SetFontAll(h);
    CenterTopmost(h, winW, winH, parent);
    SetFocus(d.hEdit);
    SendMessageW(d.hEdit, EM_SETSEL, 0, -1);
    NgLog(L"ask: shown, hEdit=%p client=%dx%d win=%dx%d", (void*)d.hEdit, clientW, clientH, winW, winH);
    EnableWindow(parent, FALSE);
    PumpModal(h);
    g_pIn = nullptr;
    NgLog(L"ask: loop end ok=%d", d.ok ? 1 : 0);
    EnableWindow(parent, TRUE);
    SetForegroundWindow(parent);
    if (d.ok) value = d.value;
    NgLog(L"ask: return %d", d.ok ? 1 : 0);
    return d.ok;
}

// ---------------------------------------------------------------- 列表刷新
static void RefreshLists()
{
    ListView_DeleteAllItems(g_listEp);
    for (size_t i = 0; i < g_pol.eps.size(); i++) {
        const auto& e = g_pol.eps[i];
        LVITEMW it = {};
        it.mask = LVIF_TEXT;
        it.iItem = (int)i;
        it.pszText = (LPWSTR)e.name.c_str();
        ListView_InsertItem(g_listEp, &it);
        ListView_SetItemText(g_listEp, (int)i, 1, (LPWSTR)e.cidr.c_str());
        ListView_SetItemText(g_listEp, (int)i, 2, (LPWSTR)e.ports.c_str());
        ListView_SetItemText(g_listEp, (int)i, 3, (LPWSTR)e.proto.c_str());
        ListView_SetItemText(g_listEp, (int)i, 4, (LPWSTR)(e.enabled ? L"启用" : L"停用"));
    }
    ListView_DeleteAllItems(g_listPr);
    for (size_t i = 0; i < g_pol.procs.size(); i++) {
        const auto& p = g_pol.procs[i];
        LVITEMW it = {};
        it.mask = LVIF_TEXT;
        it.iItem = (int)i;
        it.pszText = (LPWSTR)p.name.c_str();
        ListView_InsertItem(g_listPr, &it);
        ListView_SetItemText(g_listPr, (int)i, 1, (LPWSTR)p.path.c_str());
        std::wstring hashShort = p.sha256.empty() ? L"(未锁定)" : p.sha256.substr(0, 16) + L"…";
        ListView_SetItemText(g_listPr, (int)i, 2, (LPWSTR)hashShort.c_str());
        ListView_SetItemText(g_listPr, (int)i, 3, (LPWSTR)p.endpoint.c_str());
        ListView_SetItemText(g_listPr, (int)i, 4, (LPWSTR)(p.enabled ? L"启用" : L"停用"));
    }
}

static void RefreshControls()
{
    Button_SetCheck(g_chkDeny, g_pol.defaultDeny ? BST_CHECKED : BST_UNCHECKED);
    Button_SetCheck(g_chkDhcp, g_pol.allowDhcp ? BST_CHECKED : BST_UNCHECKED);
    Button_SetCheck(g_chkLoop, g_pol.allowLoopback ? BST_CHECKED : BST_UNCHECKED);
    SetWindowTextW(g_edtLan, g_pol.lanAllow.c_str());
    SetWindowTextW(g_edtDns, g_pol.allowDnsServer.c_str());
}

static void SyncFromControls()
{
    g_pol.defaultDeny = Button_GetCheck(g_chkDeny) == BST_CHECKED;
    g_pol.allowDhcp = Button_GetCheck(g_chkDhcp) == BST_CHECKED;
    g_pol.allowLoopback = Button_GetCheck(g_chkLoop) == BST_CHECKED;
    wchar_t b[512];
    GetWindowTextW(g_edtLan, b, 512); g_pol.lanAllow = NgTrim(b);
    // 界面里填写 LanAllow 即视为显式 opt-in（策略文件会记录 AllowLanAnyProcess=1）。
    // 该放行是任意进程/任意端口，界面/报告里会标注“不推荐”。
    g_pol.allowLanAnyProcess = !g_pol.lanAllow.empty();
    GetWindowTextW(g_edtDns, b, 512); g_pol.allowDnsServer = NgTrim(b);
}

static void SetStatus(const wchar_t* msg) { SetWindowTextW(g_stStatus, msg); }

// ---------------------------------------------------------------- 运行子命令
static void RunCmd(const std::wstring& args, const wchar_t* doneMsg)
{
    std::wstring exe = NgExeDir() + L"\\NetGuard.exe";
    std::wstring cmd = L"\"" + exe + L"\" " + args;
    STARTUPINFOW si = { sizeof(si) };
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {};
    std::vector<wchar_t> buf(cmd.begin(), cmd.end());
    buf.push_back(0);
    if (CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        WaitForSingleObject(pi.hProcess, 120000);
        DWORD code = 0;
        GetExitCodeProcess(pi.hProcess, &code);
        CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
        wchar_t m[256];
        _snwprintf_s(m, _TRUNCATE, L"%s（exit=%lu）", doneMsg, code);
        SetStatus(m);
    } else {
        SetStatus(L"无法启动 NetGuard.exe（是否与 NetGuardUI 同目录？）");
    }
}

// ---------------------------------------------------------------- 模态编辑器（地址/程序）
struct EntryDlg {
    bool isProc;
    int index;            // -1 = 新增
    bool ok;
    HWND h[6];            // 6 个编辑/控件
    HWND hComboProto, hChkEnabled, hBtnPick;
    std::wstring path, sha;
    std::wstring text[4]; // 点“确定”时先保存字段值（窗口销毁后无法再读控件）
    bool enabled;
};

static EntryDlg* g_pEntry = nullptr;

static LRESULT CALLBACK EntryWndProc(HWND hwnd, UINT m, WPARAM w, LPARAM l)
{
    EntryDlg* d = g_pEntry;
    if (!d) return DefWindowProcW(hwnd, m, w, l);
    switch (m) {
    case WM_COMMAND:
        switch (LOWORD(w)) {
        case IDOK:
            // 必须在 DestroyWindow 之前读取，否则子控件已销毁、读到的全是空
            for (int i = 0; i < 4; i++) {
                wchar_t b[512] = {};
                GetWindowTextW(d->h[i], b, 512);
                d->text[i] = b;
            }
            d->enabled = (Button_GetCheck(d->hChkEnabled) == BST_CHECKED);
            d->ok = true;
            DestroyWindow(hwnd);
            return 0;
        case IDCANCEL: d->ok = false; DestroyWindow(hwnd); return 0;
        case 2000: {   // 选择 exe
            wchar_t file[MAX_PATH] = {};
            OPENFILENAMEW ofn = { sizeof(ofn) };
            ofn.hwndOwner = hwnd;
            ofn.lpstrFilter = L"可执行文件\0*.exe\0所有文件\0*.*\0";
            ofn.lpstrFile = file;
            ofn.nMaxFile = MAX_PATH;
            ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
            if (GetOpenFileNameW(&ofn)) {
                SetWindowTextW(d->h[1], file);
                std::wstring hx;
                if (NgSha256File(file, hx)) {
                    SetWindowTextW(d->h[2], hx.c_str());
                    SetStatus(L"已自动计算文件 SHA-256");
                }
            }
            return 0;
        }
        }
        break;
    case WM_CLOSE: d->ok = false; DestroyWindow(hwnd); return 0;
    }
    return DefWindowProcW(hwnd, m, w, l);
}

static void EditEntry(HWND parent, bool isProc, int index)
{
    static bool reg = false;
    if (!reg) {
        WNDCLASSW wc = {};
        wc.lpfnWndProc = EntryWndProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"NgEntryWnd";
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
        RegisterClassW(&wc);
        reg = true;
    }
    const wchar_t* labels[4];
    // 地址项也是 4 个字段。原先写成 5 会多出一行空白输入框，
    // 并且“启用”复选框正好压在“协议”输入框上。
    int nf = 4;
    if (isProc) { labels[0] = L"名称"; labels[1] = L"程序路径"; labels[2] = L"SHA-256"; labels[3] = L"绑定地址(名称,*=全部)"; }
    else        { labels[0] = L"名称"; labels[1] = L"目标地址(CIDR)"; labels[2] = L"端口(如 8000-8005)"; labels[3] = L"协议(TCP/UDP/ANY)"; }

    EntryDlg d = {};
    d.isProc = isProc;
    d.index = index;

    const int margin = Dpi(18);
    const int labelW = Dpi(180);
    const int gap = Dpi(12);
    const int rowY0 = Dpi(18);
    const int rowH = Dpi(46);
    const int editH = Dpi(30);
    const int chkW = Dpi(160);
    const int chkH = Dpi(26);
    const int btnW = Dpi(100);
    const int btnH = Dpi(32);
    const int btnGap = Dpi(12);
    const int clientW = Dpi(700);
    const int editX = margin + labelW;
    const int editW = clientW - editX - margin;
    const int chkY = rowY0 + nf * rowH + Dpi(4);
    const int btnY = chkY + chkH + Dpi(18);
    const int clientH = btnY + btnH + margin;

    RECT rc = { 0, 0, clientW, clientH };
    DWORD style = WS_POPUP | WS_CAPTION | WS_SYSMENU;
    DWORD exStyle = WS_EX_DLGMODALFRAME | WS_EX_TOPMOST;
    AdjustWindowRectEx(&rc, style, FALSE, exStyle);
    const int winW = rc.right - rc.left;
    const int winH = rc.bottom - rc.top;

    HWND hwnd = CreateWindowExW(exStyle, L"NgEntryWnd",
                                isProc ? L"业务程序" : L"业务地址",
                                style, 0, 0, winW, winH,
                                parent, nullptr, GetModuleHandleW(nullptr), nullptr);
    g_pEntry = &d;

    const int browseW = Dpi(110);
    for (int i = 0; i < nf; i++) {
        int y = rowY0 + i * rowH;
        CreateWindowW(L"STATIC", labels[i], WS_CHILD | WS_VISIBLE | SS_LEFT,
                      margin, y + Dpi(5), labelW, Dpi(24), hwnd, nullptr, nullptr, nullptr);
        int w = (isProc && i == 1) ? editW - browseW - Dpi(8) : editW;
        d.h[i] = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                 WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
                                 editX, y, w, editH, hwnd, (HMENU)(INT_PTR)(100 + i), nullptr, nullptr);
        SendMessageW(d.h[i], EM_SETLIMITTEXT, 1024, 0);
    }
    if (isProc) {
        CreateWindowW(L"BUTTON", L"浏览(&B)…", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                      editX + editW - browseW, rowY0 + rowH, browseW, editH,
                      hwnd, (HMENU)2000, nullptr, nullptr);
        SetWindowTextW(d.h[0], index >= 0 ? g_pol.procs[index].name.c_str() : L"医保客户端");
        if (index >= 0) {
            SetWindowTextW(d.h[1], g_pol.procs[index].path.c_str());
            SetWindowTextW(d.h[2], g_pol.procs[index].sha256.c_str());
            SetWindowTextW(d.h[3], g_pol.procs[index].endpoint.c_str());
        } else {
            SetWindowTextW(d.h[3], L"*");
        }
    } else {
        SetWindowTextW(d.h[0], index >= 0 ? g_pol.eps[index].name.c_str() : L"医保前置");
        if (index >= 0) {
            SetWindowTextW(d.h[1], g_pol.eps[index].cidr.c_str());
            SetWindowTextW(d.h[2], g_pol.eps[index].ports.c_str());
            SetWindowTextW(d.h[3], g_pol.eps[index].proto.c_str());
        } else {
            SetWindowTextW(d.h[1], L"10.0.0.1/32");
            SetWindowTextW(d.h[2], L"8000-8005");
            SetWindowTextW(d.h[3], L"TCP");
        }
    }
    d.hChkEnabled = CreateWindowW(L"BUTTON", L"启用这条规则", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX,
                                  editX, chkY, chkW, chkH, hwnd, nullptr, nullptr, nullptr);
    bool en = true;
    if (index >= 0) en = isProc ? g_pol.procs[index].enabled : g_pol.eps[index].enabled;
    Button_SetCheck(d.hChkEnabled, en ? BST_CHECKED : BST_UNCHECKED);

    const int okX = clientW - margin - btnW * 2 - btnGap;
    CreateWindowW(L"BUTTON", L"确定", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                  okX, btnY, btnW, btnH, hwnd, (HMENU)IDOK, nullptr, nullptr);
    CreateWindowW(L"BUTTON", L"取消", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                  okX + btnW + btnGap, btnY, btnW, btnH, hwnd, (HMENU)IDCANCEL, nullptr, nullptr);

    SetFontAll(hwnd);
    CenterTopmost(hwnd, winW, winH, parent);
    SetFocus(d.h[0]);
    NgLog(L"entry: shown client=%dx%d win=%dx%d", clientW, clientH, winW, winH);
    EnableWindow(parent, FALSE);
    PumpModal(hwnd);
    g_pEntry = nullptr;
    EnableWindow(parent, TRUE);
    if (!d.ok) return;

    std::wstring v[4];
    for (int i = 0; i < nf && i < 4; i++) v[i] = d.text[i];
    bool enabled = d.enabled;

    if (isProc) {
        NgProcEntry p;
        p.name = NgTrim(v[0]);
        p.path = NgTrim(v[1]);
        p.sha256 = NgTrim(v[2]);
        p.endpoint = NgTrim(v[3]).empty() ? L"*" : NgTrim(v[3]);
        p.enabled = enabled;
        if (index >= 0) g_pol.procs[index] = p; else g_pol.procs.push_back(p);
    } else {
        NgEndpoint e;
        e.name = NgTrim(v[0]);
        e.cidr = NgTrim(v[1]);
        e.ports = NgTrim(v[2]).empty() ? L"0-65535" : NgTrim(v[2]);
        e.proto = NgTrim(v[3]).empty() ? L"ANY" : NgTrim(v[3]);
        e.enabled = enabled;
        if (index >= 0) g_pol.eps[index] = e; else g_pol.eps.push_back(e);
    }
    RefreshLists();
}

// ---------------------------------------------------------------- 主窗口
#define ID_ADDBTN   1001
#define ID_EDITBTN  1002
#define ID_DELBTN   1003
#define ID_ADD2     1004
#define ID_EDIT2    1005
#define ID_DEL2     1006
#define ID_SAVE     1010
#define ID_APPLY    1011
#define ID_SELFTEST 1012
#define ID_ROLLBACK 1013
#define ID_TEMP     1014
#define ID_LOGFILE  1015
#define ID_REPORT   1016
#define ID_EXIT     1017

// 按权重把列宽自适应列表宽度（避免水平滚动条把列挤出可视区）
static void FitColumns(HWND lv, const int* weights, int n)
{
    if (!lv) return;
    RECT rc;
    if (!GetClientRect(lv, &rc)) return;
    int avail = rc.right - GetSystemMetrics(SM_CXVSCROLL) - 2;
    if (avail < 200) return;
    int total = 0;
    for (int i = 0; i < n; i++) total += weights[i];
    int used = 0;
    for (int i = 0; i < n; i++) {
        int w = (i == n - 1) ? (avail - used) : (int)((long long)avail * weights[i] / total);
        if (w < 44) w = 44;
        ListView_SetColumnWidth(lv, i, w);
        used += w;
    }
}

static const int kEpWeights[]  = { 130, 170, 120, 60, 60 };
static const int kPrWeights[]  = { 120, 250, 100, 90, 60 };

static void LayoutControls(HWND h)
{
    RECT rc; GetClientRect(h, &rc);
    int W = rc.right, H = rc.bottom;
    auto S = [](int v) { return Ui(v); };
    const int M = S(12);      // 外边距
    const int BH = S(28);     // 按钮高
    const int GAP = S(8);
    const int rightW = S(400);

    int leftW = W - rightW - M * 3;
    if (leftW < S(460)) leftW = S(460);
    int rx = M + leftW + M;

    int availH = H - M - S(46);              // 底部留状态栏
    int groupH = (availH - GAP) / 2;
    int listH = groupH - S(22) - GAP - BH - S(8);
    if (listH < S(120)) listH = S(120);

    // 业务地址组
    int g1y = M;
    MoveWindow(GetDlgItem(h, 4001), M, g1y, leftW, groupH, TRUE);
    MoveWindow(g_listEp, M + S(8), g1y + S(22), leftW - S(16), listH, TRUE);
    int by = g1y + S(22) + listH + GAP;
    MoveWindow(GetDlgItem(h, ID_ADDBTN), M + S(8), by, S(92), BH, TRUE);
    MoveWindow(GetDlgItem(h, ID_EDITBTN), M + S(108), by, S(92), BH, TRUE);
    MoveWindow(GetDlgItem(h, ID_DELBTN), M + S(208), by, S(92), BH, TRUE);

    // 业务程序组
    int g2y = g1y + groupH + GAP;
    MoveWindow(GetDlgItem(h, 4002), M, g2y, leftW, groupH, TRUE);
    MoveWindow(g_listPr, M + S(8), g2y + S(22), leftW - S(16), listH, TRUE);
    int by2 = g2y + S(22) + listH + GAP;
    MoveWindow(GetDlgItem(h, ID_ADD2), M + S(8), by2, S(92), BH, TRUE);
    MoveWindow(GetDlgItem(h, ID_EDIT2), M + S(108), by2, S(92), BH, TRUE);
    MoveWindow(GetDlgItem(h, ID_DEL2), M + S(208), by2, S(92), BH, TRUE);

    // 策略组
    const int g3h = S(330);
    MoveWindow(GetDlgItem(h, 4003), rx, M, rightW, g3h, TRUE);
    int iw = rightW - S(24);
    int y = M + S(26);
    MoveWindow(g_chkDeny, rx + S(10), y, iw, S(24), TRUE); y += S(30);
    MoveWindow(g_chkDhcp, rx + S(10), y, iw, S(24), TRUE); y += S(30);
    MoveWindow(g_chkLoop, rx + S(10), y, iw, S(24), TRUE); y += S(36);
    MoveWindow(GetDlgItem(h, 3000), rx + S(10), y, iw, S(20), TRUE); y += S(22);
    MoveWindow(g_edtLan, rx + S(10), y, iw, S(26), TRUE); y += S(34);
    MoveWindow(GetDlgItem(h, 3001), rx + S(10), y, iw, S(20), TRUE); y += S(22);
    MoveWindow(g_edtDns, rx + S(10), y, iw, S(26), TRUE); y += S(34);
    MoveWindow(GetDlgItem(h, 3002), rx + S(10), y, S(180), S(20), TRUE);
    MoveWindow(g_edtTemp, rx + S(10), y + S(22), S(90), S(26), TRUE);
    MoveWindow(GetDlgItem(h, ID_TEMP), rx + S(110), y + S(22), S(130), BH, TRUE);

    // 右侧动作按钮
    int ay = M + g3h + GAP;
    MoveWindow(GetDlgItem(h, ID_APPLY), rx, ay, rightW, S(32), TRUE);        ay += S(40);
    MoveWindow(GetDlgItem(h, ID_SAVE), rx, ay, rightW, BH, TRUE);            ay += S(36);
    MoveWindow(GetDlgItem(h, ID_SELFTEST), rx, ay, rightW / 2 - S(4), BH, TRUE);
    MoveWindow(GetDlgItem(h, ID_ROLLBACK), rx + rightW / 2 + S(4), ay, rightW / 2 - S(4), BH, TRUE); ay += S(36);
    MoveWindow(GetDlgItem(h, ID_LOGFILE), rx, ay, rightW / 2 - S(4), BH, TRUE);
    MoveWindow(GetDlgItem(h, ID_REPORT), rx + rightW / 2 + S(4), ay, rightW / 2 - S(4), BH, TRUE);

    // 状态栏 + 退出
    MoveWindow(g_stStatus, M, H - S(34), W - M * 2 - S(120), S(24), TRUE);
    MoveWindow(GetDlgItem(h, ID_EXIT), W - M - S(108), H - S(35), S(108), BH, TRUE);

    // 列宽自适应（跟随面板宽度）
    FitColumns(g_listEp, kEpWeights, 5);
    FitColumns(g_listPr, kPrWeights, 5);
}

// ---------------------------------------------------------------- 窗口截图（用于自动化验收）
static bool SaveWindowBmp(HWND hwnd, const std::wstring& path)
{
    RECT rc;
    if (!GetClientRect(hwnd, &rc)) return false;
    int w = rc.right, h = rc.bottom;
    if (w <= 0 || h <= 0) return false;

    HDC hdcWin = GetDC(hwnd);
    HDC hdcMem = CreateCompatibleDC(hdcWin);
    HBITMAP bmp = CreateCompatibleBitmap(hdcWin, w, h);
    HGDIOBJ old = SelectObject(hdcMem, bmp);
    bool ok = PrintWindow(hwnd, hdcMem, 1 /*PW_CLIENTONLY*/) != FALSE;
    if (!ok) BitBlt(hdcMem, 0, 0, w, h, hdcWin, 0, 0, SRCCOPY);

    BITMAPINFOHEADER bi = {};
    bi.biSize = sizeof(bi);
    bi.biWidth = w;
    bi.biHeight = -h;          // top-down
    bi.biPlanes = 1;
    bi.biBitCount = 32;
    bi.biCompression = BI_RGB;
    std::vector<BYTE> buf((size_t)w * h * 4);
    GetDIBits(hdcMem, bmp, 0, h, buf.data(), (BITMAPINFO*)&bi, DIB_RGB_COLORS);

    SelectObject(hdcMem, old);
    DeleteObject(bmp);
    DeleteDC(hdcMem);
    ReleaseDC(hwnd, hdcWin);

    BITMAPFILEHEADER fh = {};
    fh.bfType = 0x4D42;
    fh.bfOffBits = (DWORD)(sizeof(fh) + sizeof(bi));
    fh.bfSize = fh.bfOffBits + (DWORD)buf.size();

    HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) { NgLog(L"shot: open failed %lu", GetLastError()); return false; }
    DWORD wr = 0;
    WriteFile(f, &fh, sizeof(fh), &wr, nullptr);
    WriteFile(f, &bi, sizeof(bi), &wr, nullptr);
    WriteFile(f, buf.data(), (DWORD)buf.size(), &wr, nullptr);
    CloseHandle(f);
    NgLog(L"shot: saved %s (%dx%d) printwindow=%d", path.c_str(), w, h, ok ? 1 : 0);
    return true;
}


static LRESULT CALLBACK MainProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_CREATE: {
        g_main = h;
        auto mk = [&](const wchar_t* cls, const wchar_t* txt, DWORD st, int x, int y, int cx, int cy, int id, DWORD ex = 0) {
            return CreateWindowExW(ex, cls, txt, WS_CHILD | WS_VISIBLE | st, x, y, cx, cy, h, (HMENU)(INT_PTR)id, nullptr, nullptr);
        };
        mk(L"BUTTON", L"业务地址", BS_GROUPBOX, 8, 8, 560, 232, 4001);
        mk(L"BUTTON", L"业务程序", BS_GROUPBOX, 8, 248, 560, 232, 4002);
        mk(L"BUTTON", L"策略", BS_GROUPBOX, 576, 8, 408, 340, 4003);

        // 只保留 WS_EX_CLIENTEDGE。再叠加 WS_BORDER 会出现难看的“双层框”。
        g_listEp = mk(WC_LISTVIEWW, L"", LVS_REPORT | LVS_SINGLESEL | WS_TABSTOP, 12, 28, 460, 170, 1100, WS_EX_CLIENTEDGE);
        g_listPr = mk(WC_LISTVIEWW, L"", LVS_REPORT | LVS_SINGLESEL | WS_TABSTOP, 12, 248, 460, 170, 1101, WS_EX_CLIENTEDGE);
        ListView_SetExtendedListViewStyle(g_listEp, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
        ListView_SetExtendedListViewStyle(g_listPr, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);

        const wchar_t* colsEp[] = { L"名称", L"目标地址", L"端口", L"协议", L"状态" };
        const int wEp[] = { 130, 170, 120, 60, 60 };
        for (int i = 0; i < 5; i++) {
            LVCOLUMNW c = {};
            c.mask = LVCF_TEXT | LVCF_WIDTH;
            c.pszText = (LPWSTR)colsEp[i];
            c.cx = wEp[i];
            ListView_InsertColumn(g_listEp, i, &c);
        }
        const wchar_t* colsPr[] = { L"名称", L"程序路径", L"SHA-256", L"绑定地址", L"状态" };
        const int wPr[] = { 120, 250, 100, 90, 60 };
        for (int i = 0; i < 5; i++) {
            LVCOLUMNW c = {};
            c.mask = LVCF_TEXT | LVCF_WIDTH;
            c.pszText = (LPWSTR)colsPr[i];
            c.cx = wPr[i];
            ListView_InsertColumn(g_listPr, i, &c);
        }

        mk(L"BUTTON", L"添加地址", BS_PUSHBUTTON, 12, 200, 90, 26, ID_ADDBTN);
        mk(L"BUTTON", L"编辑", BS_PUSHBUTTON, 108, 200, 90, 26, ID_EDITBTN);
        mk(L"BUTTON", L"删除", BS_PUSHBUTTON, 204, 200, 90, 26, ID_DELBTN);
        mk(L"BUTTON", L"添加程序", BS_PUSHBUTTON, 12, 420, 90, 26, ID_ADD2);
        mk(L"BUTTON", L"编辑", BS_PUSHBUTTON, 108, 420, 90, 26, ID_EDIT2);
        mk(L"BUTTON", L"删除", BS_PUSHBUTTON, 204, 420, 90, 26, ID_DEL2);

        g_chkDeny = mk(L"BUTTON", L"默认拒绝一切出网（核心）", BS_AUTOCHECKBOX, 492, 28, 340, 24, 2001);
        g_chkDhcp = mk(L"BUTTON", L"放行 DHCP（共用网卡必需）", BS_AUTOCHECKBOX, 492, 54, 340, 24, 2002);
        g_chkLoop = mk(L"BUTTON", L"放行本机回环 127.0.0.0/8", BS_AUTOCHECKBOX, 492, 80, 340, 24, 2003);
        mk(L"STATIC", L"内网放行（共享打印机等，逗号分隔 CIDR）", SS_LEFT, 492, 116, 340, 18, 3000);
        g_edtLan = mk(L"EDIT", L"", ES_AUTOHSCROLL, 492, 136, 340, 24, 2004, WS_EX_CLIENTEDGE);
        mk(L"STATIC", L"DNS 服务器（留空=完全禁止 DNS）", SS_LEFT, 492, 168, 340, 18, 3001);
        g_edtDns = mk(L"EDIT", L"", ES_AUTOHSCROLL, 492, 188, 340, 24, 2005, WS_EX_CLIENTEDGE);
        mk(L"STATIC", L"临时放行（分钟）", SS_LEFT, 492, 220, 200, 18, 3002);
        g_edtTemp = mk(L"EDIT", L"60", ES_NUMBER, 492, 240, 80, 24, 2006, WS_EX_CLIENTEDGE);
        mk(L"BUTTON", L"临时放行", BS_PUSHBUTTON, 582, 240, 120, 26, ID_TEMP);

        mk(L"BUTTON", L"保存并应用（下发到服务）", BS_DEFPUSHBUTTON, 492, 290, 340, 30, ID_APPLY);
        mk(L"BUTTON", L"仅保存策略", BS_PUSHBUTTON, 492, 326, 340, 28, ID_SAVE);
        mk(L"BUTTON", L"端到端自检", BS_PUSHBUTTON, 492, 362, 165, 30, ID_SELFTEST);
        mk(L"BUTTON", L"紧急回滚（恢复联网）", BS_PUSHBUTTON, 667, 362, 165, 30, ID_ROLLBACK);
        mk(L"BUTTON", L"打开日志", BS_PUSHBUTTON, 492, 400, 165, 30, ID_LOGFILE);
        mk(L"BUTTON", L"导出检查报告", BS_PUSHBUTTON, 667, 400, 165, 30, ID_REPORT);

        g_stStatus = mk(L"STATIC", L"就绪", SS_LEFT | SS_SUNKEN, 0, 0, 10, 10, 3004);
        mk(L"BUTTON", L"退出", BS_PUSHBUTTON, 0, 0, 10, 10, ID_EXIT);

        // 统一系统字体（解决“文字发黑/过粗/被截断”）并一次性布局
        {
            NONCLIENTMETRICSW ncm = { sizeof(ncm) };
            if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0))
                g_font = CreateFontIndirectW(&ncm.lfMessageFont);
            if (!g_font) g_font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
            EnumChildWindows(h, [](HWND c, LPARAM lp) -> BOOL {
                SendMessageW(c, WM_SETFONT, (WPARAM)lp, TRUE);
                return TRUE;
            }, (LPARAM)g_font);
        }
        LayoutControls(h);

        if (g_selftest) {
            RefreshLists();   // 先填充列表，再统计
            static const wchar_t NL[] = { 13, 10, 0 };
            std::wstring rep;
            auto num = [](long long v) { return std::to_wstring(v); };
            rep += L"NetGuardUI selftest"; rep += NL;
            rep += L"main_window=" + num(g_main ? 1 : 0) + NL;
            rep += L"listEp_cols=" + num(Header_GetItemCount(ListView_GetHeader(g_listEp))) + NL;
            rep += L"listPr_cols=" + num(Header_GetItemCount(ListView_GetHeader(g_listPr))) + NL;
            rep += L"policy_eps=" + num((long long)g_pol.eps.size()) + L" policy_procs=" + num((long long)g_pol.procs.size()) + NL;
            rep += L"listEp_items=" + num(ListView_GetItemCount(g_listEp)) + NL;
            rep += L"listPr_items=" + num(ListView_GetItemCount(g_listPr)) + NL;
            rep += L"chkDeny=" + num(IsWindow(g_chkDeny) ? 1 : 0)
                 + L" chkDhcp=" + num(IsWindow(g_chkDhcp) ? 1 : 0)
                 + L" chkLoop=" + num(IsWindow(g_chkLoop) ? 1 : 0) + NL;
            rep += L"edtLan=" + num(IsWindow(g_edtLan) ? 1 : 0)
                 + L" edtDns=" + num(IsWindow(g_edtDns) ? 1 : 0)
                 + L" edtTemp=" + num(IsWindow(g_edtTemp) ? 1 : 0) + NL;
            rep += L"statusbar=" + num(IsWindow(g_stStatus) ? 1 : 0) + NL;

            CreateDirectoryW(NgDataDir().c_str(), nullptr);
            std::wstring path = NgDataDir();
            path += L"\\ui-selftest.txt";
            HANDLE hf = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
            if (hf != INVALID_HANDLE_VALUE) {
                std::string u8 = NgWideToUtf8(rep);
                DWORD wr = 0;
                WriteFile(hf, u8.data(), (DWORD)u8.size(), &wr, nullptr);
                CloseHandle(hf);
            }
            if (g_shotPath.empty()) PostMessageW(h, WM_CLOSE, 0, 0);   // 截图模式：等 WM_APP+2 拍完再关
        }
        break;
    }
    case WM_SIZE: LayoutControls(h); break;
    case WM_GETMINMAXINFO: {
        MINMAXINFO* mmi = (MINMAXINFO*)l;
        int minW = Ui(900), minH = Ui(560);
        HMONITOR mon = MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST);
        MONITORINFO mi = { sizeof(mi) };
        if (GetMonitorInfoW(mon, &mi)) {
            int availW = mi.rcWork.right - mi.rcWork.left;
            int availH = mi.rcWork.bottom - mi.rcWork.top;
            if (minW > availW) minW = availW;
            if (minH > availH) minH = availH;
        }
        mmi->ptMinTrackSize = { minW, minH };
        break;
    }

    case WM_NOTIFY: {
        NMHDR* nh = (NMHDR*)l;
        if (nh && nh->code == NM_DBLCLK) {
            if (nh->idFrom == 1100) {
                int i = ListView_GetNextItem(g_listEp, -1, LVNI_SELECTED);
                if (i >= 0) { EditEntry(h, false, i); return 0; }
            } else if (nh->idFrom == 1101) {
                int i = ListView_GetNextItem(g_listPr, -1, LVNI_SELECTED);
                if (i >= 0) { EditEntry(h, true, i); return 0; }
            }
        }
        break;
    }

    case WM_COMMAND:
        switch (LOWORD(w)) {
        case ID_ADDBTN: EditEntry(h, false, -1); break;
        case ID_ADD2:   EditEntry(h, true, -1); break;
        case ID_EDITBTN: { int i = ListView_GetNextItem(g_listEp, -1, LVNI_SELECTED); if (i >= 0) EditEntry(h, false, i); else SetStatus(L"先在地址列表里选一行"); break; }
        case ID_EDIT2:   { int i = ListView_GetNextItem(g_listPr, -1, LVNI_SELECTED); if (i >= 0) EditEntry(h, true, i); else SetStatus(L"先在程序列表里选一行"); break; }
        case ID_DELBTN: { int i = ListView_GetNextItem(g_listEp, -1, LVNI_SELECTED); if (i >= 0) { g_pol.eps.erase(g_pol.eps.begin() + i); RefreshLists(); SetStatus(L"已删除地址项（记得保存）"); } break; }
        case ID_DEL2:   { int i = ListView_GetNextItem(g_listPr, -1, LVNI_SELECTED); if (i >= 0) { g_pol.procs.erase(g_pol.procs.begin() + i); RefreshLists(); SetStatus(L"已删除程序项（记得保存）"); } break; }

        case ID_SAVE: {
            SyncFromControls();
            std::wstring err;
            if (!g_pol.Validate(err)) { MessageBoxW(h, err.c_str(), L"策略无效", MB_ICONWARNING); break; }
            std::wstring key, kerr;
            if (!NgPolicyKeyEnsure(key, &kerr)) {
                MessageBoxW(h, kerr.c_str(), L"策略密钥", MB_ICONERROR);
                break;
            }
            if (g_pol.Save(g_policyPath)) SetStatus(L"策略已保存（已重新签名）");
            else SetStatus(L"保存失败（需要管理员权限？）");
            break;
        }
        case ID_APPLY: {
            SyncFromControls();
            std::wstring err;
            if (!g_pol.Validate(err)) { MessageBoxW(h, err.c_str(), L"策略无效", MB_ICONWARNING); break; }
            std::wstring key, kerr;
            if (!NgPolicyKeyEnsure(key, &kerr)) {
                MessageBoxW(h, kerr.c_str(), L"策略密钥", MB_ICONERROR);
                break;
            }
            if (!g_pol.Save(g_policyPath)) { SetStatus(L"保存失败"); break; }

            // 优先通过命名管道让常驻服务重新加载策略（不断服务、不断网）
            DWORD perr = 0;
            std::wstring resp = NgIpcSend(L"apply", 8000, &perr);
            if (resp.find(L"trial-expired") != std::wstring::npos) {
                SetStatus(L"试用已到期：管控已停止，请更换正式授权版本");
                break;
            }
            if (!resp.empty() && resp.rfind(L"OK", 0) == 0) {
                SetStatus((L"策略已应用（服务）：" + resp).c_str());
                break;
            }

            // 服务未运行：安装并启动后重试
            RunCmd(L"install", L"服务安装/更新");
            system("sc start NetGuard >nul 2>&1");
            Sleep(1500);
            resp = NgIpcSend(L"apply", 8000, &perr);
            if (!resp.empty() && resp.rfind(L"OK", 0) == 0)
                SetStatus((L"策略已应用：" + resp).c_str());
            else
                SetStatus(L"应用失败：服务未响应（请检查 NetGuard 服务状态）");
            break;
        }
        case ID_SELFTEST: RunCmd(L"test", L"自检完成"); MessageBoxW(h, L"自检结果已写入 C:\\ProgramData\\NetGuard\\selftest.txt", L"自检", MB_ICONINFORMATION); break;
        case ID_ROLLBACK:
            if (MessageBoxW(h, L"确认撤销全部过滤规则并恢复联网？", L"紧急回滚", MB_YESNO | MB_ICONWARNING) == IDYES) {
                system("sc stop NetGuard >nul 2>&1");
                RunCmd(L"rollback", L"回滚");
            }
            break;
        case ID_TEMP: {
            wchar_t b[32] = L"60";
            GetWindowTextW(g_edtTemp, b, 32);
            std::wstring cmd = L"temp " + std::wstring(b);

            // 优先让常驻服务处理（与服务看门狗共用同一把 WFP 锁）；服务未运行时退回 CLI
            DWORD perr = 0;
            std::wstring resp = NgIpcSend(cmd, 8000, &perr);
            if (resp.find(L"trial-expired") != std::wstring::npos) {
                SetStatus(L"试用已到期：临时放行已不可用，请更换正式授权版本");
                break;
            }
            if (!resp.empty() && resp.rfind(L"OK", 0) == 0) {
                SetStatus((L"已临时放行（服务）：" + resp).c_str());
                break;
            }
            RunCmd(cmd, L"临时放行");
            break;
        }
        case ID_LOGFILE: ShellExecuteW(h, L"open", L"notepad.exe", (L"\"" + NgDataDir() + L"\\ng.log\"").c_str(), nullptr, SW_SHOWNORMAL); break;
        case ID_REPORT: {
            std::wstring rpt = NgDataDir() + L"\\report.txt";
            HANDLE hf = CreateFileW(rpt.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (hf != INVALID_HANDLE_VALUE) {
                std::wstringstream ss;
                SYSTEMTIME st; GetLocalTime(&st);
                ss << L"NetGuard 出网管控检查报告\r\n生成时间: "
                   << st.wYear << L"-" << st.wMonth << L"-" << st.wDay << L" "
                   << st.wHour << L":" << st.wMinute << L"\r\n\r\n";
                ss << L"默认拒绝: " << (g_pol.defaultDeny ? L"开启" : L"关闭") << L"\r\n";
                ss << L"放行 DHCP: " << (g_pol.allowDhcp ? L"是" : L"否") << L"\r\n";
                ss << L"内网放行: " << (g_pol.lanAllow.empty() ? L"(无)" : (g_pol.lanAllow + L"（任意进程/任意端口，不推荐）")) << L"\r\n";
                ss << L"业务地址 " << g_pol.eps.size() << L" 条:\r\n";
                for (auto& e : g_pol.eps) ss << L"  - " << e.name << L"  " << e.cidr << L"  " << e.ports << L"/" << e.proto << L"\r\n";
                ss << L"业务程序 " << g_pol.procs.size() << L" 条:\r\n";
                for (auto& p : g_pol.procs) ss << L"  - " << p.name << L"  " << p.path << L"  SHA256=" << p.sha256 << L"\r\n";
                ss << L"\r\n本机仅允许上述通道访问网络，其余出网流量一律拦截。\r\n";
                std::string u8 = NgWideToUtf8(ss.str());
                DWORD wr = 0;
                WriteFile(hf, u8.data(), (DWORD)u8.size(), &wr, nullptr);
                CloseHandle(hf);
                ShellExecuteW(h, L"open", L"notepad.exe", (L"\"" + rpt + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
            }
            break;
        }
        case ID_EXIT: DestroyWindow(h); break;
        }
        break;

    case WM_APP + 2:
        if (!g_shotPath.empty()) {
            SaveWindowBmp(h, g_shotPath);
            PostMessageW(h, WM_CLOSE, 0, 0);
        }
        return 0;

    case WM_DESTROY: PostQuitMessage(0); break;
    }
    return DefWindowProcW(h, m, w, l);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, LPWSTR, int)
{
    SetProcessDPIAware();   // 避免系统缩放把控件撑变形/截断
    InitDpi();

    // 自检模式（--selftest）：跳过口令，构建窗口后写报告退出
    // 截图模式（--screenshot <file.bmp>）：构建窗口并把画面存成 BMP 后退出
    {
        std::wstring cmd = GetCommandLineW();
        if (cmd.find(L"--selftest") != std::wstring::npos) g_selftest = true;
        size_t p = cmd.find(L"--screenshot");
        if (p != std::wstring::npos) {
            size_t q = cmd.find(L'"', p);
            std::wstring rest = (q != std::wstring::npos) ? cmd.substr(q + 1) : cmd.substr(p + 12);
            size_t q2 = rest.find(L'"');
            if (q2 != std::wstring::npos) rest = rest.substr(0, q2);
            g_shotPath = NgTrim(rest);
            if (!g_shotPath.empty()) g_selftest = true;
        }
        size_t pp = cmd.find(L"--password");
        if (pp != std::wstring::npos) {
            std::wstring rest = cmd.substr(pp + 10);
            size_t sp = rest.find(L' ');
            if (sp != std::wstring::npos) rest = rest.substr(0, sp);
            g_passArg = NgTrim(rest);
        }
    }

    // 必须管理员
    if (!g_selftest && !NgIsAdmin()) {
        MessageBoxW(nullptr, L"请以管理员身份运行 NetGuardUI。\n（右键 → 以管理员身份运行）", L"NetGuard", MB_ICONERROR);
        return 1;
    }
    NgLogInit(NgDataDir());
    g_policyPath = PolicyPath();
    HardenAdminFileAcl();       // 修复旧版本遗留的宽松权限

    // 管理员口令
    if (!g_selftest) {
    bool firstRun = GetFileAttributesW(AdminPath().c_str()) == INVALID_FILE_ATTRIBUTES;
    std::wstring pass;
    if (!g_passArg.empty()) { pass = g_passArg; firstRun = false; }
    if (firstRun) {
        std::wstring p1, p2;
        if (!AskText(nullptr, L"设置管理员口令", L"首次使用，请设置管理员口令（用于保护策略配置）：", p1, true)) return 1;
        if (!AskText(nullptr, L"确认口令", L"请再次输入同一口令：", p2, true)) return 1;
        if (p1 != p2 || p1.empty()) { MessageBoxW(nullptr, L"两次口令不一致或为空", L"NetGuard", MB_ICONERROR); return 1; }
        if (!SaveAdminPassword(p1)) { MessageBoxW(nullptr, L"口令保存失败（需要管理员权限）", L"NetGuard", MB_ICONERROR); return 1; }
    } else {
        if (g_passArg.empty() && !AskText(nullptr, L"NetGuard 管理", L"请输入管理员口令：", pass, true)) return 1;
        if (!CheckAdminPassword(pass)) { MessageBoxW(nullptr, L"口令错误", L"NetGuard", MB_ICONERROR); return 1; }
    }
    }

    g_pol.Load(g_policyPath);

    // 60 天试用期：在状态栏显示剩余天数 / 到期提示
    NgTrialInfo trial;
    bool trialOk = NgTrialEnsure(trial, true);
    std::wstring trialMsg;
    if (trialOk && trial.disabled)
        trialMsg = L"开发版：60 天试用门禁已临时禁用";
    else if (trialOk && trial.expired)
        trialMsg = L"试用已到期：管控已停止，终端保持联网（" + NgTrialTimeText(trial.end) + L"）";
    else if (trialOk)
        trialMsg = L"试用版：剩余 " + std::to_wstring(trial.daysLeft) + L" 天（到 " + NgTrialTimeText(trial.end) + L"）";
    else
        trialMsg = L"试用信息不可读：" + trial.error;

    INITCOMMONCONTROLSEX icc = { sizeof(icc), ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icc);

    WNDCLASSW wc = {};
    wc.lpfnWndProc = MainProc;
    wc.hInstance = inst;
    wc.lpszClassName = L"NetGuardMain";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.hIcon = LoadIconW(nullptr, IDI_SHIELD);
    RegisterClassW(&wc);

    // 初始窗口按 DPI 放大，但不超过当前显示器工作区，避免一开窗就盖住任务栏/屏幕外。
    int winW = Ui(1120), winH = Ui(780);
    RECT wa = { 0, 0, 0, 0 };
    if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0)) {
        int availW = wa.right - wa.left, availH = wa.bottom - wa.top;
        if (winW > availW) winW = availW;
        if (winH > availH) winH = availH;
    }
    HWND h = CreateWindowExW(0, L"NetGuardMain", L"NetGuard - 药店终端出网管控",
                             WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, winW, winH,
                             nullptr, nullptr, inst, nullptr);
    if (!h) return 1;
    RefreshLists();
    RefreshControls();
    SetStatus(trialMsg.c_str());
    ShowWindow(h, g_shotPath.empty() ? SW_SHOW : SW_SHOWNOACTIVATE);
    UpdateWindow(h);
    if (!g_shotPath.empty()) PostMessageW(h, WM_APP + 2, 0, 0);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
