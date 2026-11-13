#pragma once
#include "ng_common.h"

struct NgEndpoint {
    std::wstring name;
    std::wstring cidr;      // 10.1.2.3/32  或 192.168.1.0/24
    std::wstring ports;     // 8000-8005 或 8000,8001,9000-9010
    std::wstring proto;     // TCP / UDP / ANY
    bool enabled = true;
};

struct NgProcEntry {
    std::wstring name;
    std::wstring path;      // exe 完整路径；"*" 表示任意进程（仅用于局域网打印机等）
    std::wstring sha256;    // 大写十六进制；为空表示不校验（不推荐）
    std::wstring endpoint;  // 绑定的地址名；"*" 或空表示所有已定义地址
    bool enabled = true;
};

struct NgPolicy {
    bool defaultDeny = true;
    bool allowDhcp = true;
    bool allowLoopback = true;
    // LanAllow 是任意进程放行整个网段；必须显式 AllowLanAnyProcess=1 才允许。
    std::wstring lanAllow;          // 额外允许的网段（任意进程可访问），逗号分隔 CIDR
    bool allowLanAnyProcess = false;
    std::wstring allowDnsServer;    // 允许的 DNS 服务器 IP（为空=不允许 DNS）
    // StrictHash=1（默认）：启用的业务程序必须有 64 位 SHA-256，且禁止 Path=*。
    bool strictHash = true;
    uint64_t tempAllowUntil = 0;    // 临时放行截止时间（unix 秒）
    std::wstring hmac;              // 策略签名

    std::vector<NgEndpoint> eps;
    std::vector<NgProcEntry> procs;

    void Reset();
    bool Load(const std::wstring& path);
    bool Save(const std::wstring& path);                                  // 使用部署密钥
    bool SaveWithKey(const std::wstring& path, const std::wstring& key);  // 离线/测试用指定密钥
    std::string Canonical() const;                        // HMAC 输入
    bool ComputeHmac(const std::wstring& key, std::wstring& out) const;
    bool VerifyHmac(const std::wstring& key) const;
    bool Validate(std::wstring& err) const;
    const NgEndpoint* FindEndpoint(const std::wstring& name) const;
};

// ---------------------------------------------------------------- 字段格式校验（fail-closed）
// 解析失败必须拒绝策略，不能降级成“全部端口/全部协议”。
struct NgPortRange { uint16_t lo = 0; uint16_t hi = 0; };
bool NgParsePortSpec(const std::wstring& ports, std::vector<NgPortRange>& out, std::wstring* why = nullptr);
bool NgIsValidCidr(const std::wstring& cidr, std::wstring* why = nullptr);
bool NgIsValidProto(const std::wstring& proto);

// ---------------------------------------------------------------- 部署级策略密钥
// 密钥: HKLM\SOFTWARE\NetGuard\PolicyKey（键 DACL 仅 SYSTEM/Administrators）
// 缺失/不可读时，签名与校验一律失败（fail-closed），不再使用编译进二进制的固定密钥。
// 存放在 HKLM 而不是 ProgramData，普通用户无法在安装前预置密钥。
bool NgPolicyKeyIsValid(const std::wstring& key);
bool NgPolicyKeyRead(std::wstring& key, std::wstring* err = nullptr);
bool NgPolicyKeyEnsure(std::wstring& key, std::wstring* err = nullptr, bool* created = nullptr);

// 旧版本固定密钥：只用于识别/迁移旧签名，禁止用于新签名
const std::wstring& NgLegacyPolicyKey();
