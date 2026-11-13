#pragma once
#include "ng_common.h"

// 服务端命令处理回调：输入命令，返回响应文本（ASCII 友好）
typedef std::wstring (*NgIpcHandler)(const std::wstring& cmd);

// 在服务里启动管道服务（\\.\pipe\NetGuardControl）
bool NgIpcStartServer(NgIpcHandler handler, const wchar_t* clientSddl);
void NgIpcStopServer();

// 客户端：发送命令并等待响应（失败返回空串，errOut 可给出错误码）
std::wstring NgIpcSend(const std::wstring& cmd, DWORD timeoutMs = 8000, DWORD* errOut = nullptr);
