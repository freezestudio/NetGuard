#pragma once
#include <string>
#include <cstdint>

// 60 天试用期信息
// 位置：HKLM\SOFTWARE\NetGuard
//   TrialStart (REG_QWORD)  首次登记的 Unix 时间
//   TrialSig   (REG_SZ)     HMAC-SHA256(PolicyKey, "trial|<TrialStart>")
//
// 开发开关：1 = 启用 60 天试用；0 = 临时禁用（开发/回归构建）。
// 发布前必须改回 1 并重新构建。
#define NG_TRIAL_ENABLED 0

struct NgTrialInfo {
    bool present = false;   // 是否读到 TrialStart/TrialSig
    bool valid = false;     // 签名校验是否通过
    bool expired = false;   // 是否已到期（或时钟异常/信息被改）
    bool disabled = false;  // 开发版：试用门禁已禁用
    int daysLeft = 0;       // 剩余天数（向上取整）
    uint64_t start = 0;
    uint64_t end = 0;
    std::wstring error;
};

// allowCreate：管理员/SYSTEM 调用时，缺失则登记（开始计时）。
// 已存在但签名不对：判为被修改，不会重置。
bool NgTrialEnsure(NgTrialInfo& out, bool allowCreate);

// 本地时间文本：yyyy-mm-dd hh:mm
std::wstring NgTrialTimeText(uint64_t unixSec);
