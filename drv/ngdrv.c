/*
 * NetGuard hash-gate driver
 *
 * 目标：在进程创建时校验白名单程序的 SHA-256，在 ALE_AUTH_CONNECT
 * 连接时按 PID 查表；哈希不匹配的进程即使被用户态 NetGuard 放行，
 * 也会被本驱动 block。
 *
 * 白名单由用户态 NetGuard 服务通过 IOCTL 下发（完整 NT 设备路径 + SHA-256）。
 * 设备 \\.\NgDrv 的 DACL 仅允许 SYSTEM / Administrators。
 */

#define POOL_ZERO_DOWN_LEVEL_SUPPORT
#include <ntddk.h>

// ntifs.h 与 wdm.h 在本环境有类型重定义冲突；直接声明所需内核 API。
NTKERNELAPI NTSTATUS SeLocateProcessImageName(_In_ PEPROCESS Process, _Out_ PUNICODE_STRING* ImageFileName);
NTKERNELAPI NTSTATUS PsLookupProcessByProcessId(_In_ HANDLE ProcessId, _Out_ PEPROCESS* Process);

#pragma warning(push)
#pragma warning(disable:4201)
#include <fwpsk.h>
#pragma warning(pop)
#include <fwpmk.h>

#define INITGUID
#include <guiddef.h>

#include <bcrypt.h>
#include <wdmsec.h>
#include <ntstrsafe.h>

#include "../src/ngdrv_ioctl.h"

#define NG_POOL_TAG 'gNdN'

// ---------------------------------------------------------------- GUIDs
static const GUID NG_PROVIDER =
    { 0x19f0b0a1, 0x2b3c, 0x4d5e, { 0x8f, 0x90, 0x11, 0x22, 0x33, 0x44, 0x55, 0x01 } };
static const GUID NG_SUBLAYER =
    { 0x19f0b0a1, 0x2b3c, 0x4d5e, { 0x8f, 0x90, 0x11, 0x22, 0x33, 0x44, 0x55, 0x02 } };
static const GUID NG_CALLOUT_V4 =
    { 0x19f0b0a1, 0x2b3c, 0x4d5e, { 0x8f, 0x90, 0x11, 0x22, 0x33, 0x44, 0x55, 0x03 } };
static const GUID NG_CALLOUT_V6 =
    { 0x19f0b0a1, 0x2b3c, 0x4d5e, { 0x8f, 0x90, 0x11, 0x22, 0x33, 0x44, 0x55, 0x04 } };
static const GUID NG_DEVCLASS =
    { 0x19f0b0a1, 0x2b3c, 0x4d5e, { 0x8f, 0x90, 0x11, 0x22, 0x33, 0x44, 0x55, 0x05 } };

// ---------------------------------------------------------------- state
static PDEVICE_OBJECT gDevice = NULL;
static BOOLEAN gSymlinkCreated = FALSE;
static HANDLE gEngine = NULL;
static UINT32 gCalloutIdV4 = 0;
static UINT32 gCalloutIdV6 = 0;
static BOOLEAN gProcessNotifySet = FALSE;

typedef struct _NG_WL_ENTRY {
    UNICODE_STRING NtPath;              // \Device\HarddiskVolumeX\...
    WCHAR Hash[NGDRV_HASH_CHARS];
} NG_WL_ENTRY;

static NG_WL_ENTRY* gWlEntries = NULL;
static ULONG gWlCount = 0;
static KSPIN_LOCK gWlLock;

typedef struct _NG_PROC_ENTRY {
    LIST_ENTRY List;
    ULONG Pid;
    BOOLEAN Verified;
} NG_PROC_ENTRY;

static LIST_ENTRY gProcList;
static KSPIN_LOCK gProcLock;

static void NgLogStatus(PCWSTR step, NTSTATUS st)
{
    UNICODE_STRING keyName = RTL_CONSTANT_STRING(L"\\Registry\\Machine\\SOFTWARE\\NetGuard\\DriverTest");
    OBJECT_ATTRIBUTES oa;
    InitializeObjectAttributes(&oa, &keyName, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    HANDLE key = NULL;
    ULONG disp = 0;
    if (!NT_SUCCESS(ZwCreateKey(&key, KEY_SET_VALUE, &oa, 0, NULL, REG_OPTION_NON_VOLATILE, &disp)))
        return;
    UNICODE_STRING vn, vs;
    RtlInitUnicodeString(&vn, L"LastStep");
    RtlInitUnicodeString(&vs, step);
    ZwSetValueKey(key, &vn, 0, REG_SZ, vs.Buffer, vs.Length + sizeof(WCHAR));
    RtlInitUnicodeString(&vn, L"LastStatus");
    ULONG val = (ULONG)st;
    ZwSetValueKey(key, &vn, 0, REG_DWORD, &val, sizeof(val));
    ZwClose(key);
}

// ---------------------------------------------------------------- whitelist
static BOOLEAN NgIsHex64(const WCHAR* h)
{
    for (ULONG i = 0; i < 64; i++) {
        WCHAR c = h[i];
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') || (c >= L'A' && c <= L'F')))
            return FALSE;
    }
    return h[64] == 0;
}

static void NgWlFree(NG_WL_ENTRY* entries, ULONG count)
{
    if (!entries) return;
    for (ULONG i = 0; i < count; i++) {
        if (entries[i].NtPath.Buffer) ExFreePoolWithTag(entries[i].NtPath.Buffer, NG_POOL_TAG);
    }
    ExFreePoolWithTag(entries, NG_POOL_TAG);
}

static void NgProcClear(void)
{
    LIST_ENTRY local;
    InitializeListHead(&local);
    KIRQL irql;
    KeAcquireSpinLock(&gProcLock, &irql);
    while (!IsListEmpty(&gProcList)) {
        PLIST_ENTRY p = RemoveHeadList(&gProcList);
        InsertTailList(&local, p);
    }
    KeReleaseSpinLock(&gProcLock, irql);

    while (!IsListEmpty(&local)) {
        PLIST_ENTRY p = RemoveHeadList(&local);
        NG_PROC_ENTRY* e = CONTAINING_RECORD(p, NG_PROC_ENTRY, List);
        ExFreePoolWithTag(e, NG_POOL_TAG);
    }
}

static void NgWlClear(void)
{
    KIRQL irql;
    NG_WL_ENTRY* old = NULL;
    ULONG oldCount = 0;
    KeAcquireSpinLock(&gWlLock, &irql);
    old = gWlEntries; oldCount = gWlCount;
    gWlEntries = NULL; gWlCount = 0;
    KeReleaseSpinLock(&gWlLock, irql);
    NgWlFree(old, oldCount);
    // 回滚/临时放行/服务停止：同时清掉进程缓存，避免残留 block。
    NgProcClear();
}

static NTSTATUS NgWlSetFromUser(const NGDRV_WL_BUFFER* in, ULONG inputLen)
{
    if (!in || inputLen < sizeof(NGDRV_WL_BUFFER)) return STATUS_INVALID_PARAMETER;
    if (in->Magic != NGDRV_WL_MAGIC || in->Count > NGDRV_MAX_ENTRIES) return STATUS_INVALID_PARAMETER;

    ULONG need = sizeof(NGDRV_WL_BUFFER) +
                 (in->Count > 0 ? (in->Count - 1) * sizeof(NGDRV_WL_ENTRY) : 0);
    if (inputLen < need) return STATUS_INVALID_PARAMETER;

    if (in->Count == 0) { NgWlClear(); return STATUS_SUCCESS; }

    NG_WL_ENTRY* arr = (NG_WL_ENTRY*)ExAllocatePoolWithTag(
        NonPagedPool, in->Count * sizeof(NG_WL_ENTRY), NG_POOL_TAG);
    if (!arr) return STATUS_INSUFFICIENT_RESOURCES;
    RtlZeroMemory(arr, in->Count * sizeof(NG_WL_ENTRY));

    for (ULONG i = 0; i < in->Count; i++) {
        const WCHAR* p = in->Entries[i].Path;
        ULONG n = 0;
        while (n < NGDRV_PATH_CHARS && p[n]) n++;
        if (n < 2 || n >= NGDRV_PATH_CHARS || p[0] != L'\\') {
            NgWlFree(arr, in->Count);
            return STATUS_INVALID_PARAMETER;
        }
        if (!NgIsHex64(in->Entries[i].Hash)) {
            NgWlFree(arr, in->Count);
            return STATUS_INVALID_PARAMETER;
        }

        PWSTR copy = (PWSTR)ExAllocatePoolWithTag(NonPagedPool, (n + 1) * sizeof(WCHAR), NG_POOL_TAG);
        if (!copy) { NgWlFree(arr, in->Count); return STATUS_INSUFFICIENT_RESOURCES; }
        RtlCopyMemory(copy, p, n * sizeof(WCHAR));
        copy[n] = 0;
        arr[i].NtPath.Buffer = copy;
        arr[i].NtPath.Length = (USHORT)(n * sizeof(WCHAR));
        arr[i].NtPath.MaximumLength = (USHORT)((n + 1) * sizeof(WCHAR));
        RtlCopyMemory(arr[i].Hash, in->Entries[i].Hash, NGDRV_HASH_CHARS * sizeof(WCHAR));
        arr[i].Hash[64] = 0;
    }

    KIRQL irql;
    NG_WL_ENTRY* old = NULL;
    ULONG oldCount = 0;
    KeAcquireSpinLock(&gWlLock, &irql);
    old = gWlEntries; oldCount = gWlCount;
    gWlEntries = arr; gWlCount = in->Count;
    KeReleaseSpinLock(&gWlLock, irql);
    NgWlFree(old, oldCount);
    return STATUS_SUCCESS;
}

static BOOLEAN NgFindExpectedHash(PUNICODE_STRING image, WCHAR outHash[NGDRV_HASH_CHARS])
{
    BOOLEAN found = FALSE;
    KIRQL irql;
    outHash[0] = 0;
    KeAcquireSpinLock(&gWlLock, &irql);
    for (ULONG i = 0; i < gWlCount; i++) {
        if (RtlEqualUnicodeString(image, &gWlEntries[i].NtPath, TRUE)) {
            RtlCopyMemory(outHash, gWlEntries[i].Hash, NGDRV_HASH_CHARS * sizeof(WCHAR));
            outHash[64] = 0;
            found = TRUE;
            break;
        }
    }
    KeReleaseSpinLock(&gWlLock, irql);
    return found;
}

// ---------------------------------------------------------------- hash
static BOOLEAN NgHexEqual(const WCHAR* a, const WCHAR* b)
{
    if (!a || !b) return FALSE;
    for (ULONG i = 0; i < 64; i++) {
        WCHAR ca = a[i], cb = b[i];
        if (ca >= L'a' && ca <= L'f') ca = (WCHAR)(ca - L'a' + L'A');
        if (cb >= L'a' && cb <= L'f') cb = (WCHAR)(cb - L'a' + L'A');
        if (ca != cb) return FALSE;
    }
    return a[64] == 0 && b[64] == 0;
}

static BOOLEAN NgHashFile(PUNICODE_STRING path, WCHAR outHex[65])
{
    HANDLE file = NULL;
    IO_STATUS_BLOCK iosb;
    OBJECT_ATTRIBUTES oa;
    NTSTATUS st;
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR obj = NULL, buf = NULL, digest = NULL;
    DWORD cbObj = 0, cbHash = 0, cb = 0;
    BOOLEAN ok = FALSE;

    outHex[0] = 0;
    if (!path || path->Length == 0 || path->Buffer == NULL) return FALSE;

    InitializeObjectAttributes(&oa, path, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    st = ZwCreateFile(&file, FILE_READ_DATA | SYNCHRONIZE, &oa, &iosb, NULL,
                      FILE_ATTRIBUTE_NORMAL,
                      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                      FILE_OPEN, FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT,
                      NULL, 0);
    if (!NT_SUCCESS(st)) return FALSE;

    st = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0);
    if (!NT_SUCCESS(st)) goto done;
    st = BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH, (PUCHAR)&cbObj, sizeof(cbObj), &cb, 0);
    if (!NT_SUCCESS(st)) goto done;
    st = BCryptGetProperty(alg, BCRYPT_HASH_LENGTH, (PUCHAR)&cbHash, sizeof(cbHash), &cb, 0);
    if (!NT_SUCCESS(st)) goto done;

    obj = (PUCHAR)ExAllocatePoolWithTag(NonPagedPool, cbObj, NG_POOL_TAG);
    buf = (PUCHAR)ExAllocatePoolWithTag(NonPagedPool, 64 * 1024, NG_POOL_TAG);
    digest = (PUCHAR)ExAllocatePoolWithTag(NonPagedPool, cbHash, NG_POOL_TAG);
    if (!obj || !buf || !digest) goto done;

    st = BCryptCreateHash(alg, &hash, obj, cbObj, NULL, 0, 0);
    if (!NT_SUCCESS(st)) goto done;

    for (;;) {
        st = ZwReadFile(file, NULL, NULL, NULL, &iosb, buf, 64 * 1024, NULL, NULL);
        if (st == STATUS_END_OF_FILE) break;
        if (!NT_SUCCESS(st)) goto done;
        if (iosb.Information == 0) break;
        st = BCryptHashData(hash, buf, (ULONG)iosb.Information, 0);
        if (!NT_SUCCESS(st)) goto done;
    }
    st = BCryptFinishHash(hash, digest, cbHash, 0);
    if (!NT_SUCCESS(st)) goto done;
    if (cbHash != 32) goto done;

    static const WCHAR hex[] = L"0123456789ABCDEF";
    for (ULONG i = 0; i < 32; i++) {
        outHex[i * 2]     = hex[(digest[i] >> 4) & 0xF];
        outHex[i * 2 + 1] = hex[digest[i] & 0xF];
    }
    outHex[64] = 0;
    ok = TRUE;

done:
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    if (obj) ExFreePoolWithTag(obj, NG_POOL_TAG);
    if (buf) ExFreePoolWithTag(buf, NG_POOL_TAG);
    if (digest) ExFreePoolWithTag(digest, NG_POOL_TAG);
    if (file) ZwClose(file);
    return ok;
}

// ---------------------------------------------------------------- process list
static void NgAddProcess(ULONG pid, BOOLEAN verified)
{
    NG_PROC_ENTRY* e = (NG_PROC_ENTRY*)ExAllocatePoolWithTag(NonPagedPool, sizeof(*e), NG_POOL_TAG);
    if (!e) return;
    e->Pid = pid;
    e->Verified = verified;
    KIRQL irql;
    KeAcquireSpinLock(&gProcLock, &irql);
    InsertTailList(&gProcList, &e->List);
    KeReleaseSpinLock(&gProcLock, irql);
}

static void NgSetVerified(ULONG pid, BOOLEAN verified)
{
    KIRQL irql;
    KeAcquireSpinLock(&gProcLock, &irql);
    for (PLIST_ENTRY p = gProcList.Flink; p != &gProcList; p = p->Flink) {
        NG_PROC_ENTRY* e = CONTAINING_RECORD(p, NG_PROC_ENTRY, List);
        if (e->Pid == pid) { e->Verified = verified; break; }
    }
    KeReleaseSpinLock(&gProcLock, irql);
}

static void NgRemoveProcess(ULONG pid)
{
    KIRQL irql;
    KeAcquireSpinLock(&gProcLock, &irql);
    for (PLIST_ENTRY p = gProcList.Flink; p != &gProcList; p = p->Flink) {
        NG_PROC_ENTRY* e = CONTAINING_RECORD(p, NG_PROC_ENTRY, List);
        if (e->Pid == pid) {
            RemoveEntryList(&e->List);
            KeReleaseSpinLock(&gProcLock, irql);
            ExFreePoolWithTag(e, NG_POOL_TAG);
            return;
        }
    }
    KeReleaseSpinLock(&gProcLock, irql);
}

static BOOLEAN NgLookupProcess(ULONG pid, BOOLEAN* found)
{
    KIRQL irql;
    BOOLEAN verified = FALSE;
    *found = FALSE;
    KeAcquireSpinLock(&gProcLock, &irql);
    for (PLIST_ENTRY p = gProcList.Flink; p != &gProcList; p = p->Flink) {
        NG_PROC_ENTRY* e = CONTAINING_RECORD(p, NG_PROC_ENTRY, List);
        if (e->Pid == pid) {
            *found = TRUE;
            verified = e->Verified;
            break;
        }
    }
    KeReleaseSpinLock(&gProcLock, irql);
    return verified;
}

static VOID NgProcessNotify(HANDLE ParentId, HANDLE ProcessId, BOOLEAN Create)
{
    UNREFERENCED_PARAMETER(ParentId);
    ULONG pid = (ULONG)(ULONG_PTR)ProcessId;

    if (!Create) {
        NgRemoveProcess(pid);
        return;
    }

    PEPROCESS proc = NULL;
    if (!NT_SUCCESS(PsLookupProcessByProcessId(ProcessId, &proc)) || !proc)
        return;

    PUNICODE_STRING image = NULL;
    if (NT_SUCCESS(SeLocateProcessImageName(proc, &image)) && image) {
        WCHAR expected[NGDRV_HASH_CHARS] = {0};
        if (NgFindExpectedHash(image, expected)) {
            // 先以“未验证”入表（fail-closed），再计算哈希；哈希期间
            // 该进程即使立刻发起连接也会被拦。
            NgAddProcess(pid, FALSE);
            BOOLEAN verified = FALSE;
            WCHAR hex[65] = {0};
            if (KeGetCurrentIrql() == PASSIVE_LEVEL) {
                if (NgHashFile(image, hex)) {
                    verified = NgHexEqual(hex, expected);
                    DbgPrint("NgDrv: pid=%lu hash=%ws expected=%ws verified=%d\n",
                             pid, hex, expected, verified);
                } else {
                    DbgPrint("NgDrv: pid=%lu hash failed\n", pid);
                }
            } else {
                DbgPrint("NgDrv: pid=%lu not PASSIVE\n", pid);
            }
            NgSetVerified(pid, verified);
        }
        ExFreePool(image);
    }
    ObDereferenceObject(proc);
}

// ---------------------------------------------------------------- WFP classify
static void NTAPI NgClassifyV4(
    const FWPS_INCOMING_VALUES* inFixedValues,
    const FWPS_INCOMING_METADATA_VALUES* inMetaValues,
    void* layerData,
    const void* classifyContext,
    const FWPS_FILTER1* filter,
    UINT64 flowContext,
    FWPS_CLASSIFY_OUT* classifyOut)
{
    UNREFERENCED_PARAMETER(inFixedValues);
    UNREFERENCED_PARAMETER(layerData);
    UNREFERENCED_PARAMETER(classifyContext);
    UNREFERENCED_PARAMETER(filter);
    UNREFERENCED_PARAMETER(flowContext);

    if ((classifyOut->rights & FWPS_RIGHT_ACTION_WRITE) == 0) return;

    UINT64 pid64 = 0;
    if (FWPS_IS_METADATA_FIELD_PRESENT(inMetaValues, FWPS_METADATA_FIELD_PROCESS_ID))
        pid64 = inMetaValues->processId;

    BOOLEAN found = FALSE;
    BOOLEAN verified = NgLookupProcess((ULONG)pid64, &found);
    if (found && !verified) {
        classifyOut->actionType = FWP_ACTION_BLOCK;
        classifyOut->rights &= ~FWPS_RIGHT_ACTION_WRITE;
        DbgPrint("NgDrv: BLOCK pid=%llu\n", pid64);
    } else {
        classifyOut->actionType = FWP_ACTION_CONTINUE;
    }
}

static void NTAPI NgClassifyV6(
    const FWPS_INCOMING_VALUES* inFixedValues,
    const FWPS_INCOMING_METADATA_VALUES* inMetaValues,
    void* layerData,
    const void* classifyContext,
    const FWPS_FILTER1* filter,
    UINT64 flowContext,
    FWPS_CLASSIFY_OUT* classifyOut)
{
    NgClassifyV4(inFixedValues, inMetaValues, layerData, classifyContext, filter, flowContext, classifyOut);
}

static NTSTATUS NTAPI NgNotify(
    FWPS_CALLOUT_NOTIFY_TYPE notifyType,
    const GUID* filterKey,
    FWPS_FILTER1* filter)
{
    UNREFERENCED_PARAMETER(notifyType);
    UNREFERENCED_PARAMETER(filterKey);
    UNREFERENCED_PARAMETER(filter);
    return STATUS_SUCCESS;
}

// ---------------------------------------------------------------- WFP registration
static NTSTATUS NgAddCalloutAndFilter(
    const GUID* layerKey,
    const GUID* calloutKey,
    const WCHAR* name,
    FWPS_CALLOUT_CLASSIFY_FN1 classifyFn,
    UINT32* calloutId)
{
    NTSTATUS st;
    FWPS_CALLOUT1 sc = {0};
    sc.calloutKey = *calloutKey;
    sc.classifyFn = classifyFn;
    sc.notifyFn = NgNotify;

    st = FwpsCalloutRegister1(gDevice, &sc, calloutId);
    if (!NT_SUCCESS(st)) {
        DbgPrint("NgDrv: FwpsCalloutRegister1 failed 0x%08X\n", st);
        return st;
    }

    FWPM_CALLOUT0 mc = {0};
    mc.calloutKey = *calloutKey;
    mc.displayData.name = (wchar_t*)name;
    mc.displayData.description = (wchar_t*)L"NetGuard hash gate";
    mc.applicableLayer = *layerKey;
    st = FwpmCalloutAdd0(gEngine, &mc, NULL, NULL);
    if (!NT_SUCCESS(st)) {
        DbgPrint("NgDrv: FwpmCalloutAdd0 failed 0x%08X\n", st);
        return st;
    }

    UINT64 weight = 0x7000;
    FWPM_FILTER0 f = {0};
    f.layerKey = *layerKey;
    f.subLayerKey = NG_SUBLAYER;
    f.displayData.name = (wchar_t*)name;
    f.displayData.description = (wchar_t*)L"NetGuard hash gate filter";
    // UNKNOWN 允许 callout 返回 CONTINUE；TERMINATING 会把 CONTINUE 当成最终动作，
    // 导致“已验证进程”绕过用户态默认拒绝。
    f.action.type = FWP_ACTION_CALLOUT_UNKNOWN;
    f.action.calloutKey = *calloutKey;
    f.weight.type = FWP_UINT64;
    f.weight.uint64 = &weight;

    st = FwpmFilterAdd0(gEngine, &f, NULL, NULL);
    if (!NT_SUCCESS(st)) {
        DbgPrint("NgDrv: FwpmFilterAdd0 failed 0x%08X\n", st);
        return st;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS NgWfpInit(void)
{
    NTSTATUS st;
    FWPM_SESSION0 session = {0};
    session.flags = FWPM_SESSION_FLAG_DYNAMIC;

    st = FwpmEngineOpen0(NULL, RPC_C_AUTHN_WINNT, NULL, &session, &gEngine);
    if (!NT_SUCCESS(st)) { NgLogStatus(L"engine", st); return st; }

    st = FwpmTransactionBegin0(gEngine, 0);
    if (!NT_SUCCESS(st)) { NgLogStatus(L"txn_begin", st); return st; }

    FWPM_PROVIDER0 prov = {0};
    prov.providerKey = NG_PROVIDER;
    prov.displayData.name = (wchar_t*)L"NetGuard Driver";
    prov.displayData.description = (wchar_t*)L"NetGuard hash gate provider";
    st = FwpmProviderAdd0(gEngine, &prov, NULL);
    if (!NT_SUCCESS(st) && st != STATUS_FWP_ALREADY_EXISTS) {
        NgLogStatus(L"provider", st);
        FwpmTransactionAbort0(gEngine);
        return st;
    }

    FWPM_SUBLAYER0 sub = {0};
    sub.subLayerKey = NG_SUBLAYER;
    sub.providerKey = (GUID*)&NG_PROVIDER;
    sub.displayData.name = (wchar_t*)L"NetGuard Driver";
    sub.displayData.description = (wchar_t*)L"NetGuard hash gate sublayer";
    sub.weight = 0x7000;
    st = FwpmSubLayerAdd0(gEngine, &sub, NULL);
    if (!NT_SUCCESS(st) && st != STATUS_FWP_ALREADY_EXISTS) {
        NgLogStatus(L"sublayer", st);
        FwpmTransactionAbort0(gEngine);
        return st;
    }

    st = NgAddCalloutAndFilter(&FWPM_LAYER_ALE_AUTH_CONNECT_V4, &NG_CALLOUT_V4,
                               L"NetGuard hash gate V4", NgClassifyV4, &gCalloutIdV4);
    if (!NT_SUCCESS(st)) { NgLogStatus(L"callout_v4", st); FwpmTransactionAbort0(gEngine); return st; }

    st = NgAddCalloutAndFilter(&FWPM_LAYER_ALE_AUTH_CONNECT_V6, &NG_CALLOUT_V6,
                               L"NetGuard hash gate V6", NgClassifyV6, &gCalloutIdV6);
    if (!NT_SUCCESS(st)) { NgLogStatus(L"callout_v6", st); FwpmTransactionAbort0(gEngine); return st; }

    st = FwpmTransactionCommit0(gEngine);
    if (!NT_SUCCESS(st)) { NgLogStatus(L"commit", st); return st; }
    return STATUS_SUCCESS;
}

// ---------------------------------------------------------------- device IOCTL
static NTSTATUS NgCreateClose(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static NTSTATUS NgDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS st = STATUS_INVALID_DEVICE_REQUEST;
    ULONG outLen = 0;
    PVOID buf = Irp->AssociatedIrp.SystemBuffer;

    switch (sp->Parameters.DeviceIoControl.IoControlCode) {
    case IOCTL_NGDRV_SET_WHITELIST:
        st = NgWlSetFromUser((const NGDRV_WL_BUFFER*)buf,
                             sp->Parameters.DeviceIoControl.InputBufferLength);
        break;
    case IOCTL_NGDRV_CLEAR_WHITELIST:
        NgWlClear();
        st = STATUS_SUCCESS;
        break;
    case IOCTL_NGDRV_GET_STATUS:
        if (sp->Parameters.DeviceIoControl.OutputBufferLength >= sizeof(NGDRV_STATUS)) {
            NGDRV_STATUS* s = (NGDRV_STATUS*)buf;
            RtlZeroMemory(s, sizeof(*s));
            s->Magic = NGDRV_WL_MAGIC;
            KIRQL irql;
            KeAcquireSpinLock(&gWlLock, &irql);
            s->WlCount = gWlCount;
            KeReleaseSpinLock(&gWlLock, irql);
            RtlStringCchCopyW(s->LastStep, RTL_NUMBER_OF(s->LastStep), L"ok");
            outLen = sizeof(*s);
            st = STATUS_SUCCESS;
        } else {
            st = STATUS_BUFFER_TOO_SMALL;
        }
        break;
    default:
        break;
    }

    Irp->IoStatus.Status = st;
    Irp->IoStatus.Information = outLen;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return st;
}

// ---------------------------------------------------------------- unload/entry
static VOID NgUnload(PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);
    if (gProcessNotifySet) {
        PsSetCreateProcessNotifyRoutine(NgProcessNotify, TRUE);
        gProcessNotifySet = FALSE;
    }
    if (gCalloutIdV4) FwpsCalloutUnregisterById0(gCalloutIdV4);
    if (gCalloutIdV6) FwpsCalloutUnregisterById0(gCalloutIdV6);
    if (gEngine) { FwpmEngineClose0(gEngine); gEngine = NULL; }

    NgWlClear();

    KIRQL irql;
    KeAcquireSpinLock(&gProcLock, &irql);
    while (!IsListEmpty(&gProcList)) {
        PLIST_ENTRY p = RemoveHeadList(&gProcList);
        NG_PROC_ENTRY* e = CONTAINING_RECORD(p, NG_PROC_ENTRY, List);
        ExFreePoolWithTag(e, NG_POOL_TAG);
    }
    KeReleaseSpinLock(&gProcLock, irql);

    if (gSymlinkCreated) {
        UNICODE_STRING sym = RTL_CONSTANT_STRING(NGDRV_SYMLINK);
        IoDeleteSymbolicLink(&sym);
        gSymlinkCreated = FALSE;
    }
    if (gDevice) { IoDeleteDevice(gDevice); gDevice = NULL; }
    DbgPrint("NgDrv: unloaded\n");
}

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(RegistryPath);
    NTSTATUS st;
    UNICODE_STRING devName = RTL_CONSTANT_STRING(NGDRV_DEVICE_NT);
    UNICODE_STRING symLink = RTL_CONSTANT_STRING(NGDRV_SYMLINK);
    UNICODE_STRING sddl = RTL_CONSTANT_STRING(L"D:P(A;;GA;;;SY)(A;;GA;;;BA)");

    st = IoCreateDeviceSecure(DriverObject, 0, &devName, FILE_DEVICE_UNKNOWN,
                              FILE_DEVICE_SECURE_OPEN, FALSE, &sddl, &NG_DEVCLASS, &gDevice);
    if (!NT_SUCCESS(st)) {
        NgLogStatus(L"io_create_secure", st);
        return st;
    }

    st = IoCreateSymbolicLink(&symLink, &devName);
    if (!NT_SUCCESS(st)) {
        NgLogStatus(L"symlink", st);
        IoDeleteDevice(gDevice); gDevice = NULL;
        return st;
    }
    gSymlinkCreated = TRUE;

    DriverObject->DriverUnload = NgUnload;
    DriverObject->MajorFunction[IRP_MJ_CREATE] = NgCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = NgCreateClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = NgDeviceControl;

    InitializeListHead(&gProcList);
    KeInitializeSpinLock(&gProcLock);
    KeInitializeSpinLock(&gWlLock);

    st = PsSetCreateProcessNotifyRoutine(NgProcessNotify, FALSE);
    if (!NT_SUCCESS(st)) {
        NgLogStatus(L"ps_notify", st);
        NgUnload(DriverObject);
        return st;
    }
    gProcessNotifySet = TRUE;

    st = NgWfpInit();
    if (!NT_SUCCESS(st)) {
        NgLogStatus(L"wfp_init", st);
        NgUnload(DriverObject);
        return st;
    }

    NgLogStatus(L"ok", 0);
    DbgPrint("NgDrv: loaded\n");
    return STATUS_SUCCESS;
}
