#include "ng_wfp.h"
#include <windows.h>
#include <fwpmu.h>
#include <ws2tcpip.h>
#include <vector>
#include <deque>
#include <cstring>
#include <fstream>
#include <sstream>

#pragma comment(lib, "fwpuclnt.lib")
#pragma comment(lib, "ws2_32.lib")

// NetGuard 自己的 sublayer，所有过滤器都挂在它下面
static const GUID NG_PROVIDER =
    { 0x1e2f0c10, 0x8a1b, 0x4c9d, { 0x9e, 0x21, 0x11, 0x11, 0x22, 0x22, 0x33, 0x31 } };

static const GUID NG_SUBLAYER =
    { 0x1e2f0c12, 0x8a1b, 0x4c9d, { 0x9e, 0x21, 0x11, 0x11, 0x22, 0x22, 0x33, 0x34 } };

static const UINT64 W_BLOCK     = 0x0000000000000001ULL;
static const UINT64 W_LOOPBACK  = 0x0000000000001000ULL;
static const UINT64 W_DHCP      = 0x0000000000001000ULL;
static const UINT64 W_LAN       = 0x0000000000001800ULL;
static const UINT64 W_BUSINESS  = 0x0000000000002000ULL;

// ---------------------------------------------------------------- 过滤器 ID 记录
// 用文件记录自己下发的过滤器 ID：既用于精确撤销，也可作为审计清单
static std::wstring IdsPath() { return NgDataDir() + L"\\filters.txt"; }

// 本进程会话内下发的过滤器 ID。filters.txt 可能被删除/改坏，
// 会话内的撤销与核验优先使用这份内存清单。
static std::vector<UINT64> g_ids;

static std::vector<UINT64> LoadIds()
{
    std::vector<UINT64> ids;
    std::ifstream f(NgWideToUtf8(IdsPath()));
    if (!f) return ids;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        ids.push_back(_strtoui64(line.c_str(), nullptr, 10));
    }
    return ids;
}

static void saveIds(const std::vector<UINT64>& ids)
{
    CreateDirectoryW(NgDataDir().c_str(), nullptr);
    std::ofstream f(NgWideToUtf8(IdsPath()), std::ios::trunc);
    for (auto id : ids) f << id << "\n";
}

static std::vector<UINT64> CurrentIds()
{
    return g_ids.empty() ? LoadIds() : g_ids;
}

static void AppendId(UINT64 id)
{
    g_ids.push_back(id);
    CreateDirectoryW(NgDataDir().c_str(), nullptr);
    std::ofstream f(NgWideToUtf8(IdsPath()), std::ios::app);
    f << id << "\n";
}

// ---------------------------------------------------------------- 小工具
static bool ParseCidr(const std::wstring& text, UINT32& addr, UINT32& mask)
{
    std::wstring t = NgTrim(text);
    size_t slash = t.find(L'/');
    std::wstring ipPart = (slash == std::wstring::npos) ? t : t.substr(0, slash);
    int prefix = 32;
    if (slash != std::wstring::npos) prefix = _wtoi(t.substr(slash + 1).c_str());
    if (prefix < 0) prefix = 0;
    if (prefix > 32) prefix = 32;

    IN_ADDR a = {};
    if (InetPtonW(AF_INET, ipPart.c_str(), &a) != 1) return false;
    addr = ntohl(a.S_un.S_addr);
    mask = (prefix == 0) ? 0 : (0xFFFFFFFFu << (32 - prefix));
    addr &= mask;
    return true;
}

// IPv6 CIDR：addr 返回 16 字节，prefix 0-128
static bool ParseCidr6(const std::wstring& text, UINT8 addr[16], UINT8& prefix)
{
    std::wstring t = NgTrim(text);
    size_t slash = t.find(L'/');
    std::wstring ipPart = (slash == std::wstring::npos) ? t : t.substr(0, slash);
    int p = 128;
    if (slash != std::wstring::npos) p = _wtoi(t.substr(slash + 1).c_str());
    if (p < 0) p = 0;
    if (p > 128) p = 128;

    IN6_ADDR a = {};
    if (InetPtonW(AF_INET6, NgTrim(ipPart).c_str(), &a) != 1) return false;
    memcpy(addr, &a, 16);
    prefix = (UINT8)p;
    return true;
}

// 返回 -1 表示协议非法；0 表示 ANY
static int ProtoNum(const std::wstring& proto)
{
    if (NgIEquals(proto, L"TCP")) return IPPROTO_TCP;
    if (NgIEquals(proto, L"UDP")) return IPPROTO_UDP;
    if (proto.empty() || NgIEquals(proto, L"ANY")) return 0;
    return -1;
}

// ---------------------------------------------------------------- 条件构建
struct FilterBuilder {
    std::vector<FWPM_FILTER_CONDITION0> conds;
    // 条件里保存的是指向这些元素的指针，必须保证 push_back 后地址稳定 -> 用 deque
    std::deque<FWP_V4_ADDR_AND_MASK> addrStore;
    std::deque<FWP_V6_ADDR_AND_MASK> addr6Store;
    std::deque<FWP_RANGE0> rangeStore;
    FWP_BYTE_BLOB* appBlob = nullptr;

    ~FilterBuilder()
    {
        if (appBlob) { void* p = appBlob; FwpmFreeMemory0(&p); }
    }

    void AddAddr(const GUID& key, UINT32 addr, UINT32 mask)
    {
        addrStore.push_back({ addr, mask });
        FWPM_FILTER_CONDITION0 c = {};
        c.fieldKey = key;
        c.matchType = FWP_MATCH_EQUAL;
        c.conditionValue.type = FWP_V4_ADDR_MASK;
        c.conditionValue.v4AddrMask = &addrStore.back();
        conds.push_back(c);
    }

    void AddAddr6(const GUID& key, const UINT8 addr[16], UINT8 prefix)
    {
        FWP_V6_ADDR_AND_MASK v = {};
        memcpy(v.addr, addr, 16);
        v.prefixLength = prefix;
        addr6Store.push_back(v);
        FWPM_FILTER_CONDITION0 c = {};
        c.fieldKey = key;
        c.matchType = FWP_MATCH_EQUAL;
        c.conditionValue.type = FWP_V6_ADDR_MASK;
        c.conditionValue.v6AddrMask = &addr6Store.back();
        conds.push_back(c);
    }

    void AddPortRange(const GUID& key, UINT16 lo, UINT16 hi)
    {
        FWPM_FILTER_CONDITION0 c = {};
        c.fieldKey = key;
        if (lo == hi) {
            c.matchType = FWP_MATCH_EQUAL;
            c.conditionValue.type = FWP_UINT16;
            c.conditionValue.uint16 = lo;
        } else {
            rangeStore.push_back({});
            FWP_RANGE0& r = rangeStore.back();
            r.valueLow.type = FWP_UINT16;  r.valueLow.uint16 = lo;
            r.valueHigh.type = FWP_UINT16; r.valueHigh.uint16 = hi;
            c.matchType = FWP_MATCH_RANGE;
            c.conditionValue.type = FWP_RANGE_TYPE;
            c.conditionValue.rangeValue = &r;
        }
        conds.push_back(c);
    }

    void AddProto(UINT8 proto)
    {
        if (proto == 0) return;
        FWPM_FILTER_CONDITION0 c = {};
        c.fieldKey = FWPM_CONDITION_IP_PROTOCOL;
        c.matchType = FWP_MATCH_EQUAL;
        c.conditionValue.type = FWP_UINT8;
        c.conditionValue.uint8 = proto;
        conds.push_back(c);
    }

    bool AddAppId(const std::wstring& exePath)
    {
        if (FwpmGetAppIdFromFileName0(exePath.c_str(), &appBlob) != ERROR_SUCCESS || !appBlob) return false;
        FWPM_FILTER_CONDITION0 c = {};
        c.fieldKey = FWPM_CONDITION_ALE_APP_ID;
        c.matchType = FWP_MATCH_EQUAL;
        c.conditionValue.type = FWP_BYTE_BLOB_TYPE;
        c.conditionValue.byteBlob = appBlob;
        conds.push_back(c);
        return true;
    }
};

static DWORD AddFilter(HANDLE engine, const GUID& layer, const std::wstring& name, UINT64 weight,
                       FWP_ACTION_TYPE action, std::vector<FWPM_FILTER_CONDITION0>& conds, UINT64* outId,
                       bool persistent = false)
{
    FWPM_FILTER0 f = {};
    f.displayData.name = (wchar_t*)name.c_str();
    f.displayData.description = (wchar_t*)L"NetGuard managed filter";
    f.layerKey = layer;
    f.subLayerKey = NG_SUBLAYER;
    f.weight.type = FWP_UINT64;
    f.weight.uint64 = &weight;
    f.action.type = action;
    f.flags = persistent ? FWPM_FILTER_FLAG_PERSISTENT : 0;
    if (!conds.empty()) {
        f.filterCondition = conds.data();
        f.numFilterConditions = (UINT32)conds.size();
    }
    UINT64 id = 0;
    DWORD st = FwpmFilterAdd0(engine, &f, nullptr, &id);
    if (st == ERROR_SUCCESS && outId) *outId = id;
    return st;
}

static DWORD EnsureSubLayer(HANDLE engine)
{
    // 注册 provider（Win7 上 sublayer 需关联 provider）
    FWPM_PROVIDER0 prov = {};
    prov.providerKey = NG_PROVIDER;
    prov.displayData.name = (wchar_t*)L"NetGuard";
    prov.displayData.description = (wchar_t*)L"NetGuard provider";
    DWORD pst = FwpmProviderAdd0(engine, &prov, nullptr);
    NgLog(L"provider add=%lu", pst);
    if (pst != ERROR_SUCCESS && pst != ERROR_ALREADY_EXISTS && pst != 0x80320009u) {
        // 继续尝试，但记录
    }

    // 依次尝试多种写法，记录 Win7 接受哪一种
    struct Variant { const wchar_t* name; bool useProvider; UINT16 weight; UINT32 flags; };
    Variant variants[] = {
        { L"provider+0x1000", true,  0x1000, 0 },
        { L"noprovider+0x1000", false, 0x1000, 0 },
        { L"provider+w0x8000", true,  0x8000, 0 },
        { L"provider+w0", true,  0,      0 },
        { L"provider+persistent", true, 0x1000, FWPM_SUBLAYER_FLAG_PERSISTENT },
    };
    for (auto& v : variants) {
        FWPM_SUBLAYER0 sub = {};
        sub.subLayerKey = NG_SUBLAYER;
        sub.providerKey = v.useProvider ? (GUID*)&NG_PROVIDER : nullptr;
        sub.displayData.name = (wchar_t*)L"NetGuard";
        sub.displayData.description = (wchar_t*)L"Pharmacy egress whitelist";
        sub.weight = v.weight;
        sub.flags = v.flags;
        DWORD st = FwpmSubLayerAdd0(engine, &sub, nullptr);
        NgLog(L"sublayer %s -> %lu", v.name, st);
        if (st == ERROR_SUCCESS || st == ERROR_ALREADY_EXISTS || st == 0x80320009u) {
            NgLog(L"sublayer OK with variant %s (st=%lu)", v.name, st);
            return ERROR_SUCCESS;
        }
    }
    return ERROR_INVALID_FUNCTION;
}

static const GUID* Layers()
{
    static const GUID l[2] = { FWPM_LAYER_ALE_AUTH_CONNECT_V4, FWPM_LAYER_ALE_AUTH_CONNECT_V6 };
    return l;
}

// 按记录的 ID 精确撤销
static DWORD DeleteByIds(HANDLE engine)
{
    auto ids = CurrentIds();
    int deleted = 0;
    for (auto id : ids) {
        DWORD st = FwpmFilterDeleteById0(engine, id);
        if (st == ERROR_SUCCESS) deleted++;
    }
    g_ids.clear();
    saveIds({});
    NgLog(L"delete-by-id: 记录 %d 条，实际删除 %d 条", (int)ids.size(), deleted);
    return ERROR_SUCCESS;
}

// ---------------------------------------------------------------- 对外接口
static int g_lastCount = 0;
int NgWfpLastCount() { return g_lastCount; }

static bool OpenEngine(HANDLE* out, UINT32 sessionFlags)
{
    FWPM_SESSION0 session = {};
    session.flags = sessionFlags;
    HANDLE engine = nullptr;
    DWORD st = FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session, &engine);
    if (st != ERROR_SUCCESS) { NgLog(L"engine open failed %lu", st); return false; }
    *out = engine;
    return true;
}

bool NgWfpOpen(NgSession& s)
{
    // 必须是动态会话：否则过滤器不随会话句柄关闭而删除，服务停止/崩溃后会一直断网
    // （直到重启或显式删除）。动态会话是“失败即安全”语义的前提。
    HANDLE engine = nullptr;
    if (!OpenEngine(&engine, FWPM_SESSION_FLAG_DYNAMIC)) return false;
    s.engine = engine;
    return true;
}

void NgWfpClose(NgSession& s)
{
    if (s.engine) { FwpmEngineClose0((HANDLE)s.engine); s.engine = nullptr; }
}

NgResult NgWfpApply(NgSession& sess, const NgPolicy& policy)
{
    NgResult r;
    HANDLE engine = (HANDLE)sess.engine;
    if (!engine) { r.msg = L"WFP 会话未打开"; return r; }

    // 下发前做一次完整校验：格式错误必须整体拒绝，避免“某条规则悄悄变成全端口”
    std::wstring verr;
    if (!policy.Validate(verr)) {
        r.msg = L"策略无效: " + verr;
        NgLog(L"apply rejected: %s", r.msg.c_str());
        return r;
    }

    DWORD st = ERROR_SUCCESS;
    // 事务失败会回滚 WFP，但 DeleteByIds 已清空清单；恢复旧 ID 清单，
    // 否则旧过滤器仍在、清单却丢了，后续无法撤销。
    auto oldIds = CurrentIds();

    auto fail = [&](const wchar_t* what, DWORD code) {
        FwpmTransactionAbort0(engine);
        g_ids = oldIds;
        saveIds(oldIds);
        r.ok = false; r.err = code;
        r.msg = std::wstring(what) + L": " + NgWin32Error(code);
        NgLog(L"apply FAILED: %s", r.msg.c_str());
        return r;
    };

    { DWORD se = EnsureSubLayer(engine); if (se != ERROR_SUCCESS) return fail(L"创建 sublayer 失败", se); }

    st = FwpmTransactionBegin0(engine, 0);
    if (st != ERROR_SUCCESS) return fail(L"开启事务失败", st);

    // 1) 先撤销旧过滤器（按记录 ID）
    DeleteByIds(engine);

    int count = 0;
    bool usePersistent = false;  // 会话级过滤器（服务常驻即持久）
    auto addOne = [&](const GUID& layer, const std::wstring& nm, UINT64 w, FWP_ACTION_TYPE act,
                      std::vector<FWPM_FILTER_CONDITION0>& conds, DWORD* err) -> bool {
        UINT64 id = 0;
        DWORD a = AddFilter(engine, layer, nm, w, act, conds, &id, usePersistent);
        if (a == 0x80320016 /* FWP_E_LIFETIME_MISMATCH */ && usePersistent) {
            usePersistent = false;
            NgLog(L"persistent 过滤器不可用，降级为会话级（重启后失效）");
            a = AddFilter(engine, layer, nm, w, act, conds, &id, false);
        }
        if (a != ERROR_SUCCESS) { if (err) *err = a; return false; }
        AppendId(id);
        count++;
        return true;
    };

    if (!policy.defaultDeny) {
        st = FwpmTransactionCommit0(engine);
        if (st != ERROR_SUCCESS) { g_ids = oldIds; saveIds(oldIds); r.err = st; r.msg = L"提交失败: " + NgWin32Error(st); return r; }
        g_lastCount = 0;            // 旧的拒绝过滤器已删除，期望值必须同步归零
        r.ok = true; r.msg = L"已关闭默认拒绝（未下发过滤规则）"; return r;
    }

    // 2) 默认拒绝（v4 + v6）
    for (int i = 0; i < 2; i++) {
        std::vector<FWPM_FILTER_CONDITION0> none;
        DWORD e = 0;
        if (!addOne(Layers()[i], L"NetGuard: Default Deny", W_BLOCK, FWP_ACTION_BLOCK, none, &e))
            return fail(L"添加默认拒绝失败", e);
    }

    // 3) 回环（IPv4 + IPv6）。默认拒绝覆盖 V6，若不单独放行 ::1，
    //    优先解析 IPv6 的 localhost 应用会被误伤。
    if (policy.allowLoopback) {
        FilterBuilder fb4;
        fb4.AddAddr(FWPM_CONDITION_IP_REMOTE_ADDRESS, 0x7F000000u, 0xFF000000u);
        DWORD e4 = 0;
        if (!addOne(FWPM_LAYER_ALE_AUTH_CONNECT_V4, L"NetGuard: allow loopback v4", W_LOOPBACK, FWP_ACTION_PERMIT, fb4.conds, &e4))
            return fail(L"IPv4 回环放行失败", e4);

        static const UINT8 kLoopback6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        FilterBuilder fb6;
        fb6.AddAddr6(FWPM_CONDITION_IP_REMOTE_ADDRESS, kLoopback6, 128);
        DWORD e6 = 0;
        if (!addOne(FWPM_LAYER_ALE_AUTH_CONNECT_V6, L"NetGuard: allow loopback v6", W_LOOPBACK, FWP_ACTION_PERMIT, fb6.conds, &e6))
            return fail(L"IPv6 回环放行失败", e6);
    }

    // 4) DHCP
    if (policy.allowDhcp) {
        FilterBuilder fb;
        fb.AddProto(IPPROTO_UDP);
        fb.AddPortRange(FWPM_CONDITION_IP_LOCAL_PORT, 68, 68);
        fb.AddPortRange(FWPM_CONDITION_IP_REMOTE_PORT, 67, 67);
        DWORD e = 0;
        if (!addOne(FWPM_LAYER_ALE_AUTH_CONNECT_V4, L"NetGuard: allow DHCP", W_DHCP, FWP_ACTION_PERMIT, fb.conds, &e))
            return fail(L"DHCP 放行失败", e);
    }

    // 5) DNS（可选）
    if (!policy.allowDnsServer.empty()) {
        UINT32 a = 0, m = 0;
        if (ParseCidr(policy.allowDnsServer, a, m)) {
            FilterBuilder fb;
            fb.AddProto(IPPROTO_UDP);
            fb.AddAddr(FWPM_CONDITION_IP_REMOTE_ADDRESS, a, m);
            fb.AddPortRange(FWPM_CONDITION_IP_REMOTE_PORT, 53, 53);
            DWORD e = 0;
            addOne(FWPM_LAYER_ALE_AUTH_CONNECT_V4, L"NetGuard: allow DNS", W_LAN, FWP_ACTION_PERMIT, fb.conds, &e);
        }
    }

    // 6) 内网放行（任意进程）
    for (auto& item : NgSplit(policy.lanAllow, L',')) {
        if (item.empty()) continue;
        UINT32 a = 0, m = 0;
        if (!ParseCidr(item, a, m)) { NgLog(L"跳过非法内网段: %s", item.c_str()); continue; }
        FilterBuilder fb;
        fb.AddAddr(FWPM_CONDITION_IP_REMOTE_ADDRESS, a, m);
        DWORD e = 0;
        if (!addOne(FWPM_LAYER_ALE_AUTH_CONNECT_V4, L"NetGuard: allow LAN " + item, W_LAN, FWP_ACTION_PERMIT, fb.conds, &e))
            return fail(L"内网放行失败", e);
    }

    // 7) 业务白名单：程序 × 地址 × 端口
    for (const auto& p : policy.procs) {
        if (!p.enabled || p.path.empty()) continue;

        std::vector<const NgEndpoint*> targets;
        if (p.endpoint.empty() || p.endpoint == L"*") {
            for (const auto& e : policy.eps) if (e.enabled) targets.push_back(&e);
        } else {
            for (auto& nm : NgSplit(p.endpoint, L',')) {
                const NgEndpoint* e = policy.FindEndpoint(nm);
                if (!e) { NgLog(L"程序 %s 绑定地址 '%s' 不存在", p.name.c_str(), nm.c_str()); continue; }
                if (e->enabled) targets.push_back(e);
            }
        }

        for (const NgEndpoint* e : targets) {
            bool isV6 = e->cidr.find(L':') != std::wstring::npos;
            UINT32 a = 0, m = 0;
            UINT8 a6[16] = {};
            UINT8 prefix6 = 128;
            if (isV6) {
                if (!ParseCidr6(e->cidr, a6, prefix6)) {
                    NgLog(L"地址 %s IPv6 Cidr 非法", e->name.c_str());
                    return fail(L"IPv6 地址 Cidr 非法", ERROR_INVALID_PARAMETER);
                }
            } else if (!ParseCidr(e->cidr, a, m)) {
                NgLog(L"地址 %s Cidr 非法", e->name.c_str());
                return fail(L"地址 Cidr 非法", ERROR_INVALID_PARAMETER);
            }
            int proto = ProtoNum(e->proto);
            if (proto < 0) {
                NgLog(L"地址 %s 协议非法: %s", e->name.c_str(), e->proto.c_str());
                return fail(L"协议非法", ERROR_INVALID_PARAMETER);
            }
            std::vector<NgPortRange> ranges;
            std::wstring why;
            if (!NgParsePortSpec(e->ports, ranges, &why)) {
                NgLog(L"地址 %s 的 Ports 无效: %s", e->name.c_str(), why.c_str());
                return fail(L"端口格式非法", ERROR_INVALID_PARAMETER);
            }
            for (auto& pr : ranges) {
                FilterBuilder fb;
                if (isV6) fb.AddAddr6(FWPM_CONDITION_IP_REMOTE_ADDRESS, a6, prefix6);
                else      fb.AddAddr(FWPM_CONDITION_IP_REMOTE_ADDRESS, a, m);
                fb.AddProto((UINT8)proto);
                fb.AddPortRange(FWPM_CONDITION_IP_REMOTE_PORT, pr.lo, pr.hi);
                if (p.path != L"*") {
                    if (!fb.AddAppId(p.path)) { NgLog(L"程序路径无效: %s", p.path.c_str()); continue; }
                }
                DWORD err = 0;
                GUID layer = isV6 ? FWPM_LAYER_ALE_AUTH_CONNECT_V6 : FWPM_LAYER_ALE_AUTH_CONNECT_V4;
                if (!addOne(layer,
                            L"NetGuard: allow " + p.name + L" -> " + e->name,
                            W_BUSINESS, FWP_ACTION_PERMIT, fb.conds, &err))
                    return fail(L"业务放行失败", err);
            }
        }
    }

    st = FwpmTransactionCommit0(engine);
    if (st != ERROR_SUCCESS) { g_ids = oldIds; saveIds(oldIds); r.err = st; r.msg = L"事务提交失败: " + NgWin32Error(st); return r; }

    r.ok = true;
    r.filters = count;
    g_lastCount = count;
    r.msg = L"策略已生效，过滤器 " + std::to_wstring(count) + L" 条";
    NgLog(L"apply ok: %s", r.msg.c_str());
    return r;
}

NgResult NgWfpRollback(NgSession& sess)
{
    NgResult r;
    HANDLE engine = (HANDLE)sess.engine;
    if (!engine) { r.msg = L"WFP 会话未打开"; return r; }

    auto oldIds = CurrentIds();
    DWORD st = FwpmTransactionBegin0(engine, 0);
    if (st == ERROR_SUCCESS) {
        DeleteByIds(engine);
        st = FwpmTransactionCommit0(engine);
    }
    if (st != ERROR_SUCCESS) {
        g_ids = oldIds;         // 事务回滚后旧过滤器仍在，恢复内存/文件清单
        saveIds(oldIds);
        r.err = st; r.msg = L"撤销失败: " + NgWin32Error(st); return r;
    }
    g_ids.clear();
    g_lastCount = 0;
    r.ok = true;
    r.msg = L"已撤销 NetGuard 全部过滤器（恢复联网）";
    NgLog(L"rollback ok");
    return r;
}

// 删除 NetGuard provider 下所有过滤器（不论持久化与否），再删 sublayer/provider。
// 旧版本曾创建持久化过滤器，升级后即使服务停止也会继续断网；此函数用于清理这类残留。
NgResult NgWfpPurge()
{
    NgResult r;
    HANDLE engine = nullptr;
    // 非动态会话：动态会话不允许删除其他会话（旧版本/旧服务）创建的过滤器
    if (!OpenEngine(&engine, 0)) { r.msg = L"无法打开 WFP 引擎（需要管理员）"; return r; }

    std::vector<UINT64> victims;
    const GUID* layers = Layers();
    auto isOurs = [](const FWPM_FILTER0* f) {
        // 旧版本创建的持久化过滤器没有 providerKey，只能靠 sublayer 或显示名识别
        if (f->subLayerKey == NG_SUBLAYER) return true;
        if (f->displayData.name && wcsncmp(f->displayData.name, L"NetGuard", 8) == 0) return true;
        return false;
    };
    for (int i = 0; i < 2; i++) {
        FWPM_FILTER_ENUM_TEMPLATE0 t = {};
        t.layerKey = layers[i];
        t.enumType = FWP_FILTER_ENUM_FULLY_CONTAINED;
        t.actionMask = 0xFFFFFFFF;
        t.flags = FWP_FILTER_ENUM_FLAG_INCLUDE_DISABLED;
        HANDLE h = nullptr;
        if (FwpmFilterCreateEnumHandle0(engine, &t, &h) != ERROR_SUCCESS || !h) continue;
        for (;;) {
            FWPM_FILTER0** entries = nullptr;
            UINT32 count = 0;
            DWORD st = FwpmFilterEnum0(engine, h, 64, &entries, &count);
            if (st != ERROR_SUCCESS || count == 0) {
                if (entries) { void* p = entries; FwpmFreeMemory0(&p); }
                break;
            }
            for (UINT32 k = 0; k < count; k++) {
                if (entries[k] && isOurs(entries[k])) victims.push_back(entries[k]->filterId);
            }
            void* p = entries; FwpmFreeMemory0(&p);
        }
        FwpmFilterDestroyEnumHandle0(engine, h);
    }

    int deleted = 0, failed = 0;
    for (auto id : victims) {
        DWORD d = FwpmFilterDeleteById0(engine, id);
        if (d == ERROR_SUCCESS || d == FWP_E_FILTER_NOT_FOUND || d == ERROR_FILE_NOT_FOUND) deleted++;
        else { failed++; NgLog(L"purge: 删除过滤器 %llu 失败 %lu", (unsigned long long)id, d); }
    }

    DWORD sd = FwpmSubLayerDeleteByKey0(engine, &NG_SUBLAYER);
    if (sd != ERROR_SUCCESS && sd != FWP_E_SUBLAYER_NOT_FOUND && sd != FWP_E_NOT_FOUND) {
        NgLog(L"purge: 删除 sublayer 失败 %lu", sd);
    }
    DWORD pd = FwpmProviderDeleteByKey0(engine, &NG_PROVIDER);
    if (pd != ERROR_SUCCESS && pd != FWP_E_PROVIDER_NOT_FOUND && pd != FWP_E_NOT_FOUND) {
        NgLog(L"purge: 删除 provider 失败 %lu", pd);
    }

    g_ids.clear();
    g_lastCount = 0;
    {
        std::ofstream f(NgWideToUtf8(IdsPath()), std::ios::trunc);
    }

    FwpmEngineClose0(engine);

    r.ok = (failed == 0);
    r.filters = deleted;
    r.msg = L"已清理 NetGuard 遗留过滤器 " + std::to_wstring(deleted) + L" 条";
    if (failed) r.msg += L"（失败 " + std::to_wstring(failed) + L" 条，详见 ng.log）";
    NgLog(L"purge: %s", r.msg.c_str());
    return r;
}

// 逐条查询 filters.txt 中的过滤器是否仍存在（可发现被其他工具删除的情况）
int NgWfpLiveCount(NgSession& sess)
{
    HANDLE engine = (HANDLE)sess.engine;
    if (!engine) return 0;

    int live = 0;
    for (auto id : CurrentIds()) {
        FWPM_FILTER0* f = nullptr;
        if (FwpmFilterGetById0(engine, id, &f) == ERROR_SUCCESS) {
            live++;
            if (f) { void* p = f; FwpmFreeMemory0(&p); }
        }
    }
    return live;
}
