#include "ng_drv.h"
#include "ng_common.h"
#include "ngdrv_ioctl.h"
#include <windows.h>
#include <winioctl.h>
#include <vector>
#include <string>

// DOS 路径 -> NT 设备路径（\Device\HarddiskVolumeX\...）
static bool DosPathToNt(const std::wstring& dos, std::wstring& nt)
{
    if (dos.empty()) return false;
    if (dos.rfind(L"\\Device\\", 0) == 0) { nt = dos; return true; }

    std::wstring d = dos;
    if (d.rfind(L"\\\\?\\", 0) == 0) d = d.substr(4);

    if (d.size() >= 2 && d[1] == L':') {
        WCHAR target[1024] = {};
        std::wstring drive = d.substr(0, 2);
        if (QueryDosDeviceW(drive.c_str(), target, 1024) == 0) return false;
        nt = std::wstring(target) + d.substr(2);
        return true;
    }
    return false;
}

static HANDLE OpenDrv()
{
    return CreateFileW(NGDRV_DEVICE_WIN32, GENERIC_READ | GENERIC_WRITE, 0,
                       nullptr, OPEN_EXISTING, 0, nullptr);
}

void NgDrvClearWhitelist()
{
    HANDLE h = OpenDrv();
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD bytes = 0;
    DeviceIoControl(h, IOCTL_NGDRV_CLEAR_WHITELIST, nullptr, 0, nullptr, 0, &bytes, nullptr);
    CloseHandle(h);
}

bool NgDrvSendWhitelist(const NgPolicy& policy)
{
    struct Item { std::wstring path; std::wstring hash; };
    std::vector<Item> items;
    for (const auto& p : policy.procs) {
        if (!p.enabled) continue;
        if (p.path == L"*" || p.path.empty() || p.sha256.size() != 64) continue;
        std::wstring nt;
        if (!DosPathToNt(p.path, nt)) {
            NgLog(L"drv: 无法把路径转换为 NT 路径，跳过: %s", p.path.c_str());
            continue;
        }
        items.push_back({ nt, p.sha256 });
    }

    if (items.empty()) {
        NgDrvClearWhitelist();
        return true;
    }
    if (items.size() > NGDRV_MAX_ENTRIES) items.resize(NGDRV_MAX_ENTRIES);

    const size_t size = sizeof(NGDRV_WL_BUFFER) +
                        (items.size() - 1) * sizeof(NGDRV_WL_ENTRY);
    std::vector<BYTE> buf(size, 0);
    auto* wl = reinterpret_cast<NGDRV_WL_BUFFER*>(buf.data());
    wl->Magic = NGDRV_WL_MAGIC;
    wl->Count = (ULONG)items.size();
    for (size_t i = 0; i < items.size(); i++) {
        wcsncpy_s(wl->Entries[i].Path, NGDRV_PATH_CHARS, items[i].path.c_str(), _TRUNCATE);
        wcsncpy_s(wl->Entries[i].Hash, NGDRV_HASH_CHARS, items[i].hash.c_str(), _TRUNCATE);
    }

    HANDLE h = OpenDrv();
    if (h == INVALID_HANDLE_VALUE) {
        // 驱动未安装/未启动：不影响用户态管控
        return false;
    }
    DWORD bytes = 0;
    BOOL ok = DeviceIoControl(h, IOCTL_NGDRV_SET_WHITELIST,
                              buf.data(), (DWORD)buf.size(),
                              nullptr, 0, &bytes, nullptr);
    DWORD err = ok ? 0 : GetLastError();
    CloseHandle(h);
    if (!ok) {
        NgLog(L"drv: 下发白名单失败 err=%lu", err);
        return false;
    }
    NgLog(L"drv: 已下发 %d 条白名单", (int)items.size());
    return true;
}
