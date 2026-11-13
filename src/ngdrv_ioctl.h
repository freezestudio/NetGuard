#pragma once

// NetGuard 用户态服务 <-> WFP callout 驱动 的共享 IOCTL 接口。
// 该头文件同时被内核驱动和用户态 NetGuard 使用，不能包含 C++ 类型。

#define NGDRV_DEVICE_NT        L"\\Device\\NgDrv"
#define NGDRV_DEVICE_WIN32     L"\\\\.\\NgDrv"
#define NGDRV_SYMLINK          L"\\DosDevices\\NgDrv"

#define NGDRV_MAX_ENTRIES      64
#define NGDRV_PATH_CHARS       520   // MAX_PATH + 1
#define NGDRV_HASH_CHARS       65    // 64 hex + NUL
#define NGDRV_WL_MAGIC         0x4E474457UL  // 'NGDW'

typedef struct _NGDRV_WL_ENTRY {
    WCHAR Path[NGDRV_PATH_CHARS];   // DOS 路径，如 C:\NetGuard\biz.exe
    WCHAR Hash[NGDRV_HASH_CHARS];   // SHA-256，大写/小写均可
} NGDRV_WL_ENTRY;

typedef struct _NGDRV_WL_BUFFER {
    ULONG Magic;
    ULONG Count;
    NGDRV_WL_ENTRY Entries[1];
} NGDRV_WL_BUFFER;

#define IOCTL_NGDRV_SET_WHITELIST \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_WRITE_DATA)
#define IOCTL_NGDRV_CLEAR_WHITELIST \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA)
#define IOCTL_NGDRV_GET_STATUS \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_READ_DATA)

typedef struct _NGDRV_STATUS {
    ULONG Magic;
    ULONG WlCount;
    ULONG LastStatus;
    WCHAR LastStep[32];
} NGDRV_STATUS;
