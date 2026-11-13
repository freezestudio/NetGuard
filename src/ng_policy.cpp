#include "ng_policy.h"
#include <ws2tcpip.h>
#include <aclapi.h>
#include <sddl.h>
#include <cstdlib>
#include <fstream>
#include <sstream>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "advapi32.lib")

// ------------------------------------------------------------------ INI 读写
namespace {

// 用 std::map 保证指针/引用稳定（此前用 vector 导致悬空指针 → 堆损坏）
struct Ini {
    std::map<std::wstring, std::map<std::wstring, std::wstring>> sections;

    static std::wstring Key(const std::wstring& s) { return NgLower(NgTrim(s)); }

    std::map<std::wstring, std::wstring>* Get(const std::wstring& name)
    {
        auto it = sections.find(Key(name));
        return (it == sections.end()) ? nullptr : &it->second;
    }

    std::wstring Value(const std::wstring& sec, const std::wstring& key, const std::wstring& def = L"") const
    {
        auto s = sections.find(Key(sec));
        if (s == sections.end()) return def;
        auto k = s->second.find(Key(key));
        return (k == s->second.end()) ? def : k->second;
    }

    bool Bool(const std::wstring& sec, const std::wstring& key, bool def) const
    {
        std::wstring v = Value(sec, key, def ? L"1" : L"0");
        return (v == L"1" || NgIEquals(v, L"true") || NgIEquals(v, L"yes"));
    }

    uint64_t U64(const std::wstring& sec, const std::wstring& key, uint64_t def) const
    {
        std::wstring v = Value(sec, key);
        if (v.empty()) return def;
        return _wcstoui64(v.c_str(), nullptr, 10);
    }
};

bool ReadTextFile(const std::wstring& path, std::wstring& out)
{
    std::ifstream f(NgWideToUtf8(path), std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = NgUtf8ToWide(ss.str());
    return true;
}

bool WriteTextFile(const std::wstring& path, const std::wstring& text)
{
    std::ofstream f(NgWideToUtf8(path), std::ios::binary | std::ios::trunc);
    if (!f) return false;
    std::string u8 = NgWideToUtf8(text);
    f.write(u8.data(), (std::streamsize)u8.size());
    return f.good();
}

// 严格十进制解析：拒绝空串、正负号、尾随垃圾、溢出
bool ParseU32Strict(const std::wstring& s, uint32_t& v)
{
    if (s.empty() || s[0] == L'-' || s[0] == L'+') return false;
    wchar_t* end = nullptr;
    unsigned long long n = _wcstoui64(s.c_str(), &end, 10);
    if (!end || *end != L'\0' || n > 0xFFFFFFFFull) return false;
    v = (uint32_t)n;
    return true;
}

// ---------------------------------------------------------------- 部署密钥（注册表）
// 存放在 HKLM\SOFTWARE\NetGuard\PolicyKey：
//   - 普通用户无法在 HKLM\SOFTWARE 下预置密钥（防止安装前预置策略）；
//   - 键 DACL 收紧为仅 SYSTEM/Administrators，普通用户也读不到密钥。
const wchar_t* kKeySubtree = L"SOFTWARE\\NetGuard";
const wchar_t* kKeyValue   = L"PolicyKey";

bool IsHexKey(const std::wstring& s)
{
    if (s.size() < 32 || s.size() > 256) return false;
    for (wchar_t c : s) {
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') || (c >= L'A' && c <= L'F')))
            return false;
    }
    return true;
}

// 注册表权限：仅 SYSTEM / Administrators 完全控制，并阻止继承
PSECURITY_DESCRIPTOR MakeKeySd()
{
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;KA;;;SY)(A;;KA;;;BA)", SDDL_REVISION_1, &sd, nullptr))
        return nullptr;
    SetSecurityDescriptorControl(sd, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
    return sd;
}

bool ApplyKeyDacl(HKEY h)
{
    PSECURITY_DESCRIPTOR sd = MakeKeySd();
    if (!sd) return false;

    BOOL present = FALSE, defaulted = FALSE;
    PACL dacl = nullptr;
    bool ok = false;
    if (GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted) && present && dacl) {
        ok = SetSecurityInfo((HANDLE)h, SE_REGISTRY_KEY,
                             DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                             nullptr, nullptr, dacl, nullptr) == ERROR_SUCCESS;
    }
    LocalFree(sd);
    return ok;
}

} // namespace

// ------------------------------------------------------------------ 部署密钥（注册表）
bool NgPolicyKeyIsValid(const std::wstring& key) { return IsHexKey(key); }

bool NgPolicyKeyRead(std::wstring& key, std::wstring* err)
{
    key.clear();
    if (err) err->clear();

    HKEY h = nullptr;
    LSTATUS st = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kKeySubtree, 0,
                               KEY_READ | KEY_WOW64_64KEY, &h);
    if (st != ERROR_SUCCESS) {
        if (err) {
            if (st == ERROR_FILE_NOT_FOUND || st == ERROR_PATH_NOT_FOUND)
                *err = L"策略密钥不存在（请先运行 NetGuard.exe initkey 或 sign）";
            else if (st == ERROR_ACCESS_DENIED)
                *err = L"无权读取策略密钥（需要管理员权限）";
            else
                *err = L"无法读取策略密钥: " + NgWin32Error((DWORD)st);
        }
        return false;
    }

    wchar_t buf[512] = {};
    DWORD cb = sizeof(buf) - sizeof(wchar_t);
    DWORD type = 0;
    st = RegQueryValueExW(h, kKeyValue, nullptr, &type, (LPBYTE)buf, &cb);
    RegCloseKey(h);

    if (st != ERROR_SUCCESS || type != REG_SZ) {
        if (err) {
            if (st == ERROR_FILE_NOT_FOUND)
                *err = L"策略密钥不存在（请先运行 NetGuard.exe initkey 或 sign）";
            else if (st == ERROR_ACCESS_DENIED)
                *err = L"无权读取策略密钥（需要管理员权限）";
            else
                *err = L"读取策略密钥失败（注册表值缺失或类型错误）";
        }
        return false;
    }

    std::wstring s = NgTrim(buf);
    if (!IsHexKey(s)) {
        if (err) *err = L"策略密钥内容无效（应为 32-256 个十六进制字符）";
        return false;
    }
    key = s;
    return true;
}

bool NgPolicyKeyEnsure(std::wstring& key, std::wstring* err, bool* created)
{
    if (created) *created = false;
    if (NgPolicyKeyRead(key, err)) {
        // 密钥已存在：管理员调用时顺便确保 DACL 仍只允许 SYSTEM/Administrators
        //（兼容旧版本/手工创建的宽松权限）。
        if (NgIsAdmin()) {
            HKEY h = nullptr;
            LSTATUS os = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kKeySubtree, 0,
                                       KEY_ALL_ACCESS | KEY_WOW64_64KEY, &h);
            if (os != ERROR_SUCCESS) {
                if (err) *err = L"无权加固策略密钥: " + NgWin32Error((DWORD)os);
                return false;
            }
            bool aclOk = ApplyKeyDacl(h);
            RegCloseKey(h);
            if (!aclOk) {
                if (err) *err = L"加固策略密钥权限失败（需要管理员权限）";
                return false;
            }
        }
        if (err) err->clear();
        return true;
    }

    // 区分“键/值不存在”和“存在但无效/无权”：存在但无效时不静默覆盖
    HKEY probe = nullptr;
    LSTATUS ps = RegOpenKeyExW(HKEY_LOCAL_MACHINE, kKeySubtree, 0,
                               KEY_READ | KEY_WOW64_64KEY, &probe);
    if (ps == ERROR_SUCCESS) {
        DWORD type = 0, cb = 0;
        LSTATUS q = RegQueryValueExW(probe, kKeyValue, nullptr, &type, nullptr, &cb);
        RegCloseKey(probe);
        if (q == ERROR_SUCCESS) {
            if (err && err->empty()) *err = L"策略密钥值存在但无效，请检查或删除后重试";
            return false;
        }
        if (q != ERROR_FILE_NOT_FOUND) {
            if (err && err->empty()) *err = L"检查策略密钥失败";
            return false;
        }
    } else if (ps == ERROR_ACCESS_DENIED) {
        if (err) *err = L"无权访问策略密钥（需要管理员权限）";
        return false;
    } else if (ps != ERROR_FILE_NOT_FOUND && ps != ERROR_PATH_NOT_FOUND) {
        if (err) *err = L"检查策略密钥失败: " + NgWin32Error((DWORD)ps);
        return false;
    }

    if (!NgIsAdmin()) {
        if (err) *err = L"生成策略密钥需要管理员权限";
        return false;
    }

    PSECURITY_DESCRIPTOR sd = MakeKeySd();
    if (!sd) {
        if (err) *err = L"构造策略密钥安全描述符失败";
        return false;
    }
    SECURITY_ATTRIBUTES sa = { sizeof(sa), sd, FALSE };

    HKEY h = nullptr;
    DWORD disp = 0;
    LSTATUS st = RegCreateKeyExW(HKEY_LOCAL_MACHINE, kKeySubtree, 0, nullptr,
                                 REG_OPTION_NON_VOLATILE,
                                 KEY_ALL_ACCESS | KEY_WOW64_64KEY, &sa, &h, &disp);
    bool aclOk = (st == ERROR_SUCCESS) ? ApplyKeyDacl(h) : false;
    LocalFree(sd);

    if (st != ERROR_SUCCESS || !aclOk) {
        DWORD ec = (st != ERROR_SUCCESS) ? (DWORD)st : ERROR_ACCESS_DENIED;
        if (st == ERROR_SUCCESS) RegCloseKey(h);
        if (st == ERROR_SUCCESS && disp == REG_CREATED_NEW_KEY)
            RegDeleteKeyW(HKEY_LOCAL_MACHINE, kKeySubtree);
        if (err) *err = L"创建/加固策略密钥失败（需要管理员权限）: " + NgWin32Error(ec);
        return false;
    }

    // 并发情况下可能已有值：先重读，避免覆盖
    std::wstring existing, rerr;
    if (NgPolicyKeyRead(existing, &rerr)) {
        RegCloseKey(h);
        key = existing;
        if (err) err->clear();
        return true;
    }

    DWORD type = 0, cb = 0;
    LSTATUS q = RegQueryValueExW(h, kKeyValue, nullptr, &type, nullptr, &cb);
    if (q == ERROR_SUCCESS) {
        RegCloseKey(h);
        if (err) *err = rerr.empty() ? L"策略密钥值无效" : rerr;
        return false;
    }
    if (q != ERROR_FILE_NOT_FOUND) {
        RegCloseKey(h);
        if (err) *err = L"读取策略密钥值失败";
        return false;
    }

    std::wstring newKey = NgRandomHex(32);
    if (newKey.empty()) {
        RegCloseKey(h);
        if (err) *err = L"生成随机策略密钥失败";
        return false;
    }

    LSTATUS ws = RegSetValueExW(h, kKeyValue, 0, REG_SZ,
                                (const BYTE*)newKey.c_str(),
                                (DWORD)((newKey.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(h);
    if (ws != ERROR_SUCCESS) {
        if (err) *err = L"写入策略密钥失败: " + NgWin32Error((DWORD)ws);
        return false;
    }

    key = newKey;
    if (created) *created = true;
    if (err) err->clear();
    return true;
}

const std::wstring& NgLegacyPolicyKey()
{
    // 仅用于识别旧版本签名；新签名一律使用 HKLM\SOFTWARE\NetGuard\PolicyKey
    static const std::wstring k = L"NG-2026-PHARMACY-POLICY-KEY-7f3a9c";
    return k;
}

// ------------------------------------------------------------------ 字段格式校验
bool NgParsePortSpec(const std::wstring& ports, std::vector<NgPortRange>& out, std::wstring* why)
{
    out.clear();
    if (why) why->clear();

    for (auto& item : NgSplit(ports, L',')) {
        std::wstring s = NgTrim(item);
        if (s.empty()) continue;                 // 容忍首尾逗号/多余逗号

        size_t dash = s.find(L'-');
        uint32_t lo = 0, hi = 0;
        bool ok = false;
        if (dash == std::wstring::npos) {
            ok = ParseU32Strict(s, lo) && lo <= 65535;
            hi = lo;
        } else {
            ok = (s.find(L'-', dash + 1) == std::wstring::npos)
                 && ParseU32Strict(NgTrim(s.substr(0, dash)), lo)
                 && ParseU32Strict(NgTrim(s.substr(dash + 1)), hi)
                 && lo <= hi && hi <= 65535;
        }
        if (!ok) {
            if (why) *why = L"'" + s + L"' 不是合法端口或端口范围（应为 0-65535 或 lo-hi）";
            out.clear();
            return false;
        }
        out.push_back({ (uint16_t)lo, (uint16_t)hi });
    }

    if (out.empty()) {
        if (why) *why = L"端口列表为空";
        return false;
    }
    return true;
}

bool NgIsValidCidr(const std::wstring& cidr, std::wstring* why)
{
    if (why) why->clear();
    std::wstring t = NgTrim(cidr);
    if (t.empty()) {
        if (why) *why = L"为空";
        return false;
    }

    size_t slash = t.find(L'/');
    if (slash != std::wstring::npos && t.find(L'/', slash + 1) != std::wstring::npos) {
        if (why) *why = L"'/" + t + L"' 前缀长度格式错误";
        return false;
    }

    std::wstring ipPart = (slash == std::wstring::npos) ? t : NgTrim(t.substr(0, slash));
    bool isV6 = t.find(L':') != std::wstring::npos;

    uint32_t prefix = isV6 ? 128 : 32;
    if (slash != std::wstring::npos) {
        if (!ParseU32Strict(NgTrim(t.substr(slash + 1)), prefix) ||
            prefix > (isV6 ? 128u : 32u)) {
            if (why) *why = L"'/" + t + L"' 前缀长度必须是 0-" + std::to_wstring(isV6 ? 128 : 32);
            return false;
        }
    }

    if (isV6) {
        IN6_ADDR a6 = {};
        if (InetPtonW(AF_INET6, ipPart.c_str(), &a6) != 1) {
            if (why) *why = L"'" + ipPart + L"' 不是合法 IPv6 地址";
            return false;
        }
        return true;
    }

    IN_ADDR a = {};
    if (InetPtonW(AF_INET, ipPart.c_str(), &a) != 1) {
        if (why) *why = L"'" + ipPart + L"' 不是合法 IPv4 地址";
        return false;
    }
    return true;
}

bool NgIsValidProto(const std::wstring& proto)
{
    std::wstring p = NgTrim(proto);
    return p.empty() || NgIEquals(p, L"TCP") || NgIEquals(p, L"UDP") || NgIEquals(p, L"ANY");
}

// ------------------------------------------------------------------ 策略
void NgPolicy::Reset()
{
    *this = NgPolicy();
}

bool NgPolicy::Load(const std::wstring& path)
{
    std::wstring text;
    if (!ReadTextFile(path, text)) return false;

    Ini ini;
    std::wstring curSection;
    std::wstringstream ss(text);
    std::wstring line;
    while (std::getline(ss, line)) {
        std::wstring t = NgTrim(line);
        if (t.empty() || t[0] == L';' || t[0] == L'#') continue;
        if (t[0] == L'[') {
            size_t e = t.find(L']');
            if (e == std::wstring::npos) continue;
            curSection = NgTrim(t.substr(1, e - 1));
            ini.sections[Ini::Key(curSection)];   // 建节
            continue;
        }
        size_t eq = t.find(L'=');
        if (eq == std::wstring::npos) continue;
        std::wstring k = Ini::Key(t.substr(0, eq));
        std::wstring v = NgTrim(t.substr(eq + 1));
        ini.sections[Ini::Key(curSection)][k] = v;
    }

    Reset();
    defaultDeny    = ini.Bool(L"general", L"DefaultDeny", true);
    allowDhcp      = ini.Bool(L"general", L"AllowDhcp", true);
    allowLoopback  = ini.Bool(L"general", L"AllowLoopback", true);
    lanAllow       = ini.Value(L"general", L"LanAllow");
    allowLanAnyProcess = ini.Bool(L"general", L"AllowLanAnyProcess", false);
    allowDnsServer = ini.Value(L"general", L"AllowDnsServer");
    strictHash     = ini.Bool(L"general", L"StrictHash", true);
    tempAllowUntil = ini.U64(L"general", L"TempAllowUntil", 0);
    hmac           = ini.Value(L"general", L"PolicyHmac");

    // 收集 [ep.N] / [proc.N]（map 按 key 排序，ep.1..ep.9 顺序正确）
    for (auto& s : ini.sections) {
        const std::wstring& name = s.first;
        if (NgStartsWithI(name, L"ep.")) {
            auto& m = s.second;
            NgEndpoint e;
            e.name    = m.count(L"name") ? m[L"name"] : name;
            e.cidr    = m.count(L"cidr") ? m[L"cidr"] : L"";
            e.ports   = m.count(L"ports") ? m[L"ports"] : L"0-65535";
            e.proto   = m.count(L"proto") ? m[L"proto"] : L"ANY";
            e.enabled = m.count(L"enable") ? (m[L"enable"] == L"1") : true;
            eps.push_back(e);
        } else if (NgStartsWithI(name, L"proc.")) {
            auto& m = s.second;
            NgProcEntry p;
            p.name     = m.count(L"name") ? m[L"name"] : name;
            p.path     = m.count(L"path") ? m[L"path"] : L"";
            p.sha256   = m.count(L"sha256") ? m[L"sha256"] : L"";
            p.endpoint = m.count(L"endpoint") ? m[L"endpoint"] : L"*";
            p.enabled  = m.count(L"enable") ? (m[L"enable"] == L"1") : true;
            procs.push_back(p);
        }
    }
    return true;
}

bool NgPolicy::Save(const std::wstring& path)
{
    // 先读取部署级密钥（缺失/不可读则拒绝签名），再算签名（不含 hmac 自身）
    std::wstring key, kerr;
    if (!NgPolicyKeyRead(key, &kerr)) {
        NgLog(L"policy save rejected: %s", kerr.c_str());
        return false;
    }
    return SaveWithKey(path, key);
}

bool NgPolicy::SaveWithKey(const std::wstring& path, const std::wstring& key)
{
    if (!NgPolicyKeyIsValid(key)) {
        NgLog(L"policy save rejected: 密钥格式无效");
        return false;
    }

    NgPolicy tmp = *this;
    tmp.hmac.clear();
    std::wstring sig;
    if (!tmp.ComputeHmac(key, sig)) {
        NgLog(L"policy save rejected: HMAC 计算失败");
        return false;
    }
    hmac = sig;

    std::wstringstream o;
    o << L"; NetGuard policy - 由 NetGuardUI 生成，请勿手工编辑\r\n";
    o << L"; StrictHash=1：启用的程序必须有 64 位 SHA-256，且禁止 Path=*\r\n";
    o << L"; LanAllow 是任意进程放行；如确需，必须同时 AllowLanAnyProcess=1\r\n";
    o << L"[general]\r\n";
    o << L"DefaultDeny=" << (defaultDeny ? 1 : 0) << L"\r\n";
    o << L"AllowDhcp=" << (allowDhcp ? 1 : 0) << L"\r\n";
    o << L"AllowLoopback=" << (allowLoopback ? 1 : 0) << L"\r\n";
    if (!lanAllow.empty())       o << L"LanAllow=" << lanAllow << L"\r\n";
    o << L"AllowLanAnyProcess=" << (allowLanAnyProcess ? 1 : 0) << L"\r\n";
    if (!allowDnsServer.empty()) o << L"AllowDnsServer=" << allowDnsServer << L"\r\n";
    o << L"StrictHash=" << (strictHash ? 1 : 0) << L"\r\n";
    o << L"TempAllowUntil=" << tempAllowUntil << L"\r\n";
    o << L"PolicyHmac=" << hmac << L"\r\n";

    for (size_t i = 0; i < eps.size(); i++) {
        const auto& e = eps[i];
        o << L"\r\n[ep." << (i + 1) << L"]\r\n";
        o << L"Name=" << e.name << L"\r\n";
        o << L"Cidr=" << e.cidr << L"\r\n";
        o << L"Ports=" << e.ports << L"\r\n";
        o << L"Proto=" << e.proto << L"\r\n";
        o << L"Enable=" << (e.enabled ? 1 : 0) << L"\r\n";
    }
    for (size_t i = 0; i < procs.size(); i++) {
        const auto& p = procs[i];
        o << L"\r\n[proc." << (i + 1) << L"]\r\n";
        o << L"Name=" << p.name << L"\r\n";
        o << L"Path=" << p.path << L"\r\n";
        o << L"Sha256=" << p.sha256 << L"\r\n";
        o << L"Endpoint=" << p.endpoint << L"\r\n";
        o << L"Enable=" << (p.enabled ? 1 : 0) << L"\r\n";
    }

    return WriteTextFile(path, o.str());
}

std::string NgPolicy::Canonical() const
{
    std::wstringstream o;
    o << L"v2|" << (defaultDeny ? 1 : 0) << L"|" << (allowDhcp ? 1 : 0) << L"|"
      << (allowLoopback ? 1 : 0) << L"|" << lanAllow << L"|"
      << (allowLanAnyProcess ? 1 : 0) << L"|" << allowDnsServer << L"|"
      << (strictHash ? 1 : 0) << L"|";
    for (const auto& e : eps)
        o << L"E|" << e.name << L"|" << e.cidr << L"|" << e.ports << L"|" << e.proto << L"|" << (e.enabled ? 1 : 0) << L";";
    for (const auto& p : procs)
        o << L"P|" << NgLower(p.path) << L"|" << p.sha256 << L"|" << p.endpoint << L"|" << (p.enabled ? 1 : 0) << L";";
    return NgWideToUtf8(o.str());
}

bool NgPolicy::ComputeHmac(const std::wstring& key, std::wstring& out) const
{
    if (key.empty()) return false;
    return NgHmacSha256Hex(NgWideToUtf8(key), Canonical(), out);
}

bool NgPolicy::VerifyHmac(const std::wstring& key) const
{
    if (key.empty() || hmac.empty()) return false;
    std::wstring calc;
    if (!ComputeHmac(key, calc)) return false;
    return NgIEquals(calc, hmac);
}

const NgEndpoint* NgPolicy::FindEndpoint(const std::wstring& name) const
{
    for (const auto& e : eps)
        if (NgIEquals(e.name, name)) return &e;
    return nullptr;
}

bool NgPolicy::Validate(std::wstring& err) const
{
    if (eps.empty() && procs.empty()) { err = L"策略为空：至少要有一条业务地址和一条业务程序"; return false; }

    // LanAllow 是“任意进程”放行；必须显式 opt-in，避免默认策略悄悄放宽。
    if (!lanAllow.empty() && !allowLanAnyProcess) {
        err = L"LanAllow 会放行任意进程访问整个网段；如确需，请在 [general] 显式设置 AllowLanAnyProcess=1";
        return false;
    }
    for (auto& item : NgSplit(lanAllow, L',')) {
        std::wstring c = NgTrim(item);
        if (c.empty()) continue;
        if (c.find(L':') != std::wstring::npos) {
            err = L"LanAllow 目前只支持 IPv4 CIDR: " + c;
            return false;
        }
        std::wstring why;
        if (!NgIsValidCidr(c, &why)) { err = L"LanAllow 项 '" + c + L"' 无效: " + why; return false; }
    }
    if (!allowDnsServer.empty()) {
        std::wstring why;
        if (allowDnsServer.find(L':') != std::wstring::npos || !NgIsValidCidr(allowDnsServer, &why)) {
            err = L"AllowDnsServer 必须是 IPv4 地址/CIDR";
            return false;
        }
    }

    for (const auto& e : eps) {
        std::wstring why;
        if (e.cidr.empty()) { err = L"地址项 '" + e.name + L"' 缺少 Cidr"; return false; }
        if (!NgIsValidCidr(e.cidr, &why)) {
            err = L"地址项 '" + e.name + L"' 的 Cidr 无效: " + why;
            return false;
        }
        if (e.ports.empty()) { err = L"地址项 '" + e.name + L"' 缺少 Ports"; return false; }
        std::vector<NgPortRange> ranges;
        if (!NgParsePortSpec(e.ports, ranges, &why)) {
            err = L"地址项 '" + e.name + L"' 的 Ports 无效: " + why;
            return false;
        }
        if (!NgIsValidProto(e.proto)) {
            err = L"地址项 '" + e.name + L"' 的协议无效（只能是 TCP/UDP/ANY）: " + e.proto;
            return false;
        }
    }
    for (const auto& p : procs) {
        if (p.path.empty()) { err = L"程序项 '" + p.name + L"' 缺少 Path"; return false; }
        if (!p.endpoint.empty() && p.endpoint != L"*") {
            for (const auto& nm : NgSplit(p.endpoint, L',')) {
                if (nm.empty()) continue;
                if (!FindEndpoint(nm)) {
                    err = L"程序项 '" + p.name + L"' 绑定的地址 '" + nm + L"' 不存在";
                    return false;
                }
            }
        }
        if (strictHash && p.enabled) {
            if (p.path == L"*") {
                err = L"程序项 '" + p.name + L"' 使用了 Path=*；StrictHash=1 时禁止任意进程放行";
                return false;
            }
            if (p.sha256.size() != 64) {
                err = L"程序项 '" + p.name + L"' 必须有 64 位 SHA-256（先在管理界面选择 exe 自动计算）";
                return false;
            }
            for (wchar_t c : p.sha256) {
                if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') || (c >= L'A' && c <= L'F'))) {
                    err = L"程序项 '" + p.name + L"' 的 SHA-256 含非十六进制字符";
                    return false;
                }
            }
        }
    }
    return true;
}
