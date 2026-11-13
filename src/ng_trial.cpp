#include "ng_trial.h"
#include "ng_common.h"
#include "ng_policy.h"
#include <cstdio>

static const wchar_t* kSubtree  = L"SOFTWARE\\NetGuard";
static const wchar_t* kStartVal = L"TrialStart";
static const wchar_t* kSigVal   = L"TrialSig";
static const uint64_t kTrialDays = 60;
static const uint64_t kDaySec    = 86400;

static bool ReadStart(uint64_t& v, std::wstring& err)
{
    v = 0;
    HKEY h = nullptr;
    LSTATUS st = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kSubtree, 0, KEY_READ | KEY_WOW64_64KEY, &h);
    if (st != ERROR_SUCCESS) {
        if (st != ERROR_FILE_NOT_FOUND && st != ERROR_PATH_NOT_FOUND)
            err = L"无法打开试用信息注册表: " + NgWin32Error((DWORD)st);
        return false;
    }
    DWORD type = 0, cb = sizeof(v);
    st = RegQueryValueExW(h, kStartVal, nullptr, &type, (LPBYTE)&v, &cb);
    RegCloseKey(h);
    if (st == ERROR_FILE_NOT_FOUND) return false;
    if (st != ERROR_SUCCESS || type != REG_QWORD || cb != sizeof(v)) {
        err = L"试用开始时间格式无效";
        return false;
    }
    return true;
}

static bool ReadSig(std::wstring& s, std::wstring& err)
{
    s.clear();
    HKEY h = nullptr;
    LSTATUS st = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kSubtree, 0, KEY_READ | KEY_WOW64_64KEY, &h);
    if (st != ERROR_SUCCESS) return false;
    wchar_t buf[256] = {};
    DWORD type = 0, cb = sizeof(buf) - sizeof(wchar_t);
    st = RegQueryValueExW(h, kSigVal, nullptr, &type, (LPBYTE)buf, &cb);
    RegCloseKey(h);
    if (st == ERROR_FILE_NOT_FOUND) return false;
    if (st != ERROR_SUCCESS || type != REG_SZ) {
        err = L"试用签名格式无效";
        return false;
    }
    s = buf;
    return true;
}

static bool WriteStartSig(uint64_t start, const std::wstring& sig, std::wstring& err)
{
    HKEY h = nullptr;
    LSTATUS st = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kSubtree, 0, KEY_SET_VALUE | KEY_WOW64_64KEY, &h);
    if (st != ERROR_SUCCESS) {
        err = L"无法写入试用信息（需要管理员权限）: " + NgWin32Error((DWORD)st);
        return false;
    }
    st = RegSetValueExW(h, kStartVal, 0, REG_QWORD, (const BYTE*)&start, sizeof(start));
    if (st == ERROR_SUCCESS)
        st = RegSetValueExW(h, kSigVal, 0, REG_SZ, (const BYTE*)sig.c_str(),
                            (DWORD)((sig.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(h);
    if (st != ERROR_SUCCESS) {
        err = L"写入试用信息失败: " + NgWin32Error((DWORD)st);
        return false;
    }
    return true;
}

static bool ComputeTrialSig(const std::wstring& key, uint64_t start, std::wstring& sig)
{
    std::string data = "trial|" + std::to_string((unsigned long long)start);
    return NgHmacSha256Hex(NgWideToUtf8(key), data, sig);
}

std::wstring NgTrialTimeText(uint64_t unixSec)
{
    ULONGLONG ft = (unixSec + 11644473600ULL) * 10000000ULL;
    FILETIME f = {};
    f.dwLowDateTime = (DWORD)(ft & 0xFFFFFFFFULL);
    f.dwHighDateTime = (DWORD)(ft >> 32);
    FILETIME lf = {};
    SYSTEMTIME st = {};
    wchar_t buf[64] = {};
    if (FileTimeToLocalFileTime(&f, &lf) && FileTimeToSystemTime(&lf, &st)) {
        swprintf_s(buf, L"%04d-%02d-%02d %02d:%02d",
                   st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute);
    }
    return buf;
}

bool NgTrialEnsure(NgTrialInfo& out, bool allowCreate)
{
    out = NgTrialInfo();

#if !NG_TRIAL_ENABLED
    // 开发/回归构建：不读写注册表，不做 60 天门禁。
    // 发布前把 ng_trial.h 里的 NG_TRIAL_ENABLED 改回 1。
    out.present = true;
    out.valid = true;
    out.expired = false;
    out.disabled = true;
    out.start = NgUnixNow();
    out.end = out.start + 100ULL * 365ULL * 86400ULL;
    out.daysLeft = 36500;
    out.error.clear();
    return true;
#endif

    std::wstring key, kerr;
    if (!NgPolicyKeyRead(key, &kerr)) {
        out.error = kerr;
        return false;
    }

    std::wstring rdErr;
    uint64_t start = 0;
    std::wstring sig;
    bool haveStart = ReadStart(start, rdErr);
    bool haveSig = ReadSig(sig, rdErr);
    if (!rdErr.empty()) {
        out.present = haveStart;
        out.error = rdErr;
        out.expired = true;
        return false;
    }

    bool ok = false;
    if (haveStart && haveSig) {
        std::wstring want;
        if (!ComputeTrialSig(key, start, want)) {
            out.error = L"试用签名计算失败";
            out.expired = true;
            return false;
        }
        ok = NgIEquals(sig, want);
        if (!ok) {
            out.present = true;
            out.error = L"试用信息被修改（签名不匹配）";
            out.expired = true;
            return false;
        }
        out.present = true;
        out.valid = true;
    } else if (!haveStart && !haveSig && allowCreate) {
        start = NgUnixNow();
        std::wstring sig2;
        if (!ComputeTrialSig(key, start, sig2)) {
            out.error = L"试用签名计算失败";
            return false;
        }
        if (!WriteStartSig(start, sig2, rdErr)) {
            out.error = rdErr;
            return false;
        }
        out.present = true;
        out.valid = true;
    } else {
        out.present = haveStart || haveSig;
        out.error = L"试用信息不完整（TrialStart/TrialSig 缺失）";
        out.expired = true;
        return false;
    }

    uint64_t now = NgUnixNow();
    out.start = start;
    out.end = start + kTrialDays * kDaySec;

    if (now + 2 * kDaySec < start) {
        out.expired = true;
        out.daysLeft = 0;
        out.error = L"系统时间异常（早于试用开始时间）";
        return true;
    }
    if (now >= out.end) {
        out.expired = true;
        out.daysLeft = 0;
    } else {
        uint64_t left = out.end - now;
        out.daysLeft = (int)((left + kDaySec - 1) / kDaySec);
        out.expired = false;
    }
    return true;
}
