#include "ng_common.h"
#include <bcrypt.h>
#include <shlobj.h>
#include <cstdarg>
#include <cstdio>
#include <ctime>

#pragma comment(lib, "bcrypt.lib")

static std::wstring g_logPath;

std::wstring NgExeDir()
{
    wchar_t buf[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    std::wstring p(buf);
    size_t pos = p.find_last_of(L'\\');
    return (pos == std::wstring::npos) ? L"." : p.substr(0, pos);
}

std::wstring NgDataDir()
{
    // C:\ProgramData\NetGuard
    wchar_t buf[MAX_PATH] = {};
    DWORD n = GetEnvironmentVariableW(L"ProgramData", buf, MAX_PATH);
    std::wstring base = (n > 0 && n < MAX_PATH) ? buf : L"C:\\ProgramData";
    return base + L"\\NetGuard";
}

std::wstring NgLogPath() { return g_logPath; }

void NgLogInit(const std::wstring& baseDir)
{
    CreateDirectoryW(baseDir.c_str(), nullptr);
    g_logPath = baseDir + L"\\ng.log";
    NgLog(L"=== NetGuard log start ===");
}

void NgLog(const wchar_t* fmt, ...)
{
    wchar_t msg[2048] = {};
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(msg, _TRUNCATE, fmt, ap);
    va_end(ap);

    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t line[2300] = {};
    _snwprintf_s(line, _TRUNCATE, L"%04d-%02d-%02d %02d:%02d:%02d  %s\r\n",
                 st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, msg);

    OutputDebugStringW(line);

    if (g_logPath.empty()) return;
    HANDLE h = CreateFileW(g_logPath.c_str(), FILE_APPEND_DATA,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        std::string u8 = NgWideToUtf8(line);
        WriteFile(h, u8.data(), (DWORD)u8.size(), &written, nullptr);
        CloseHandle(h);
    }
}

std::wstring NgTrim(const std::wstring& s)
{
    size_t b = s.find_first_not_of(L" \t\r\n");
    if (b == std::wstring::npos) return L"";
    size_t e = s.find_last_not_of(L" \t\r\n");
    return s.substr(b, e - b + 1);
}

std::vector<std::wstring> NgSplit(const std::wstring& s, wchar_t sep)
{
    std::vector<std::wstring> out;
    std::wstring cur;
    for (wchar_t c : s) {
        if (c == sep) { out.push_back(NgTrim(cur)); cur.clear(); }
        else cur.push_back(c);
    }
    if (!cur.empty()) out.push_back(NgTrim(cur));
    return out;
}

std::vector<std::wstring> NgSplitAny(const std::wstring& s, const wchar_t* seps)
{
    std::vector<std::wstring> out;
    std::wstring cur;
    for (wchar_t c : s) {
        if (wcschr(seps, c)) { out.push_back(NgTrim(cur)); cur.clear(); }
        else cur.push_back(c);
    }
    if (!cur.empty()) out.push_back(NgTrim(cur));
    return out;
}

std::wstring NgLower(const std::wstring& s)
{
    std::wstring r = s;
    for (auto& c : r) c = (wchar_t)towlower(c);
    return r;
}

bool NgIEquals(const std::wstring& a, const std::wstring& b)
{
    return NgLower(a) == NgLower(b);
}

bool NgStartsWithI(const std::wstring& s, const std::wstring& prefix)
{
    if (s.size() < prefix.size()) return false;
    return NgIEquals(s.substr(0, prefix.size()), prefix);
}

std::string NgWideToUtf8(const std::wstring& w)
{
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s((size_t)n, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

std::wstring NgUtf8ToWide(const std::string& s)
{
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w((size_t)n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

static std::wstring ToHex(const unsigned char* p, size_t n)
{
    static const wchar_t* d = L"0123456789ABCDEF";
    std::wstring s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; i++) { s.push_back(d[p[i] >> 4]); s.push_back(d[p[i] & 0xF]); }
    return s;
}

bool NgSha256File(const std::wstring& path, std::wstring& hexUpper)
{
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) { NgLog(L"sha256: open failed %lu path=%s", GetLastError(), path.c_str()); return false; }

    BCRYPT_ALG_HANDLE  alg = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    bool ok = false;
    DWORD cbObj = 0, cbRes = 0, cbData = 0;
    std::vector<UCHAR> obj;      // 必须与 hash 句柄同生命周期（BCrypt 会直接使用这块内存）
    std::vector<UCHAR> buf(64 * 1024);
    std::vector<UCHAR> digest;

    NTSTATUS st = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (st != 0) { NgLog(L"sha256: BCryptOpen=0x%08X", (unsigned)st); goto done; }
    st = BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH, (PUCHAR)&cbObj, sizeof(cbObj), &cbRes, 0);
    if (st != 0) { NgLog(L"sha256: GetObjLen=0x%08X", (unsigned)st); goto done; }
    st = BCryptGetProperty(alg, BCRYPT_HASH_LENGTH, (PUCHAR)&cbData, sizeof(cbData), &cbRes, 0);
    if (st != 0) { NgLog(L"sha256: GetHashLen=0x%08X", (unsigned)st); goto done; }

    obj.assign(cbObj, 0);
    st = BCryptCreateHash(alg, &hash, obj.data(), cbObj, nullptr, 0, 0);
    if (st != 0) { NgLog(L"sha256: CreateHash=0x%08X cbObj=%lu", (unsigned)st, cbObj); goto done; }
    {
        DWORD read = 0;
        for (;;) {
            if (!ReadFile(h, buf.data(), (DWORD)buf.size(), &read, nullptr) || read == 0) break;
            st = BCryptHashData(hash, buf.data(), read, 0);
            if (st != 0) { NgLog(L"sha256: HashData=0x%08X", (unsigned)st); goto done; }
        }
    }
    digest.assign(cbData, 0);
    st = BCryptFinishHash(hash, digest.data(), cbData, 0);
    if (st != 0) { NgLog(L"sha256: FinishHash=0x%08X", (unsigned)st); goto done; }
    hexUpper = ToHex(digest.data(), digest.size());
    ok = true;

done:
    if (hash) BCryptDestroyHash(hash);
    if (alg)  BCryptCloseAlgorithmProvider(alg, 0);
    CloseHandle(h);
    return ok;
}

bool NgHmacSha256Hex(const std::string& key, const std::string& data, std::wstring& hexUpper)
{
    BCRYPT_ALG_HANDLE alg = nullptr;
    bool ok = false;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG) != 0)
        return false;

    DWORD cbObj = 0, cbRes = 0, cbHash = 0;
    BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH, (PUCHAR)&cbObj, sizeof(cbObj), &cbRes, 0);
    BCryptGetProperty(alg, BCRYPT_HASH_LENGTH, (PUCHAR)&cbHash, sizeof(cbHash), &cbRes, 0);

    std::vector<UCHAR> obj(cbObj), digest(cbHash);
    BCRYPT_HASH_HANDLE h = nullptr;
    if (BCryptCreateHash(alg, &h, obj.data(), (ULONG)obj.size(),
                         (PUCHAR)key.data(), (ULONG)key.size(), 0) == 0) {
        if (BCryptHashData(h, (PUCHAR)data.data(), (ULONG)data.size(), 0) == 0 &&
            BCryptFinishHash(h, digest.data(), (ULONG)digest.size(), 0) == 0) {
            hexUpper = ToHex(digest.data(), digest.size());
            ok = true;
        }
        BCryptDestroyHash(h);
    }
    BCryptCloseAlgorithmProvider(alg, 0);
    return ok;
}

std::wstring NgRandomHex(size_t bytes)
{
    std::vector<UCHAR> buf(bytes);
    if (BCryptGenRandom(nullptr, buf.data(), (ULONG)bytes, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
        return L"";
    return ToHex(buf.data(), buf.size());
}

bool NgIsAdmin()
{
    BOOL isAdmin = FALSE;
    PSID adminSid = nullptr;
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
    if (AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID, DOMAIN_ALIAS_RID_ADMINS,
                                 0, 0, 0, 0, 0, 0, &adminSid)) {
        CheckTokenMembership(nullptr, adminSid, &isAdmin);
        FreeSid(adminSid);
    }
    return isAdmin != FALSE;
}

std::wstring NgWin32Error(DWORD err)
{
    wchar_t* buf = nullptr;
    DWORD n = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                             FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, err, 0, (LPWSTR)&buf, 0, nullptr);
    std::wstring s = (n && buf) ? NgTrim(buf) : L"(unknown)";
    if (buf) LocalFree(buf);
    wchar_t num[32];
    _snwprintf_s(num, _TRUNCATE, L" [%lu]", err);
    return s + num;
}

uint64_t NgUnixNow()
{
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    return (u.QuadPart - 116444736000000000ULL) / 10000000ULL;
}
