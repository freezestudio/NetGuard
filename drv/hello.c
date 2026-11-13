#include <ntddk.h>

static VOID NgHelloUnload(PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);
    DbgPrint("NgHello: unload\n");
}

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(RegistryPath);
    DriverObject->DriverUnload = NgHelloUnload;
    DbgPrint("NgHello: loaded\n");
    return STATUS_SUCCESS;
}
