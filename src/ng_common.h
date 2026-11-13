#pragma once
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <vector>
#include <map>
#include <cstdint>

// ---------------------------------------------------------------- 日志
void NgLogInit(const std::wstring& baseDir);
void NgLog(const wchar_t* fmt, ...);
std::wstring NgLogPath();

// ---------------------------------------------------------------- 字符串 / 路径
std::wstring NgTrim(const std::wstring& s);
std::vector<std::wstring> NgSplit(const std::wstring& s, wchar_t sep);
std::vector<std::wstring> NgSplitAny(const std::wstring& s, const wchar_t* seps);
bool NgIEquals(const std::wstring& a, const std::wstring& b);
bool NgStartsWithI(const std::wstring& s, const std::wstring& prefix);
std::wstring NgExeDir();
std::wstring NgDataDir();            // C:\ProgramData\NetGuard

// ---------------------------------------------------------------- 编码
std::string  NgWideToUtf8(const std::wstring& w);
std::wstring NgUtf8ToWide(const std::string& s);
std::wstring NgLower(const std::wstring& s);

// ---------------------------------------------------------------- 哈希
bool NgSha256File(const std::wstring& path, std::wstring& hexUpper);
bool NgHmacSha256Hex(const std::string& key, const std::string& data, std::wstring& hexUpper);
std::wstring NgRandomHex(size_t bytes);

// ---------------------------------------------------------------- 杂项
bool NgIsAdmin();
std::wstring NgWin32Error(DWORD err);
uint64_t NgUnixNow();
