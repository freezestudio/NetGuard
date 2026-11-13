#pragma once
#include "ng_policy.h"

// 将策略中的程序白名单下发给 WFP callout 驱动（\\.\NgDrv）。
// 驱动未安装时返回 false，不影响用户态管控。
bool NgDrvSendWhitelist(const NgPolicy& policy);

// 清空驱动白名单（回滚/临时放行/服务停止时调用）。
void NgDrvClearWhitelist();
