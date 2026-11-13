#pragma once
#include "ng_policy.h"

struct NgResult {
    bool ok = false;
    DWORD err = 0;
    std::wstring msg;
    int filters = 0;
};

// WFP 会话：过滤器为“会话级”，随会话句柄存活。
// 服务常驻 => 等价于开机即生效；进程退出 => 过滤器自动消失（安全的失败姿态）。
struct NgSession {
    void* engine = nullptr;   // HANDLE
};

bool     NgWfpOpen(NgSession& s);
void     NgWfpClose(NgSession& s);
NgResult NgWfpApply(NgSession& s, const NgPolicy& policy);
NgResult NgWfpRollback(NgSession& s);
int      NgWfpLastCount();        // 本会话最近一次成功下发的过滤器数量（期望值）
int      NgWfpLiveCount(NgSession& s);  // 按 filters.txt 逐条查询，实际仍存在的过滤器数量

// 清理旧版本遗留：删除 NetGuard 名下的全部过滤器（含持久化），
// 再删除 sublayer / provider。用于升级或卸载前，避免旧过滤器继续断网。
// 注意：动态会话不允许删除其他会话的对象，所以这里自己开一个非动态会话。
NgResult NgWfpPurge();
