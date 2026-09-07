param([int]$HostPhysicalCores = 2)
$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw 'CPU topology probe requires a 64-bit Windows shell' }
if (-not ('TowerProbeCpuTopology' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class TowerProbeCpuTopology {
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetLogicalProcessorInformation(IntPtr buffer, ref uint length);
    [DllImport("kernel32.dll")]
    private static extern ushort GetActiveProcessorGroupCount();
    public static long[] GetPhysicalCoreMasks() {
        if (GetActiveProcessorGroupCount() != 1) throw new NotSupportedException("CPU isolation probe supports one Windows processor group only");
        uint length = 0;
        GetLogicalProcessorInformation(IntPtr.Zero, ref length);
        if (Marshal.GetLastWin32Error() != 122 || length == 0 || length % 32 != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr buffer = Marshal.AllocHGlobal((int)length);
        try {
            if (!GetLogicalProcessorInformation(buffer, ref length)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var masks = new List<long>();
            // Windows x64 SYSTEM_LOGICAL_PROCESSOR_INFORMATION has a 32-byte
            // ABI: pointer-sized mask, relationship enum, aligned 16-byte union.
            for (int offset = 0; offset < length; offset += 32) {
                if (Marshal.ReadInt32(buffer, offset + 8) == 0) masks.Add(Marshal.ReadInt64(buffer, offset));
            }
            return masks.ToArray();
        } finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
}
$coreMasks = [TowerProbeCpuTopology]::GetPhysicalCoreMasks()
if ($HostPhysicalCores -lt 1 -or $HostPhysicalCores -ge $coreMasks.Count) { throw 'Reserve at least one physical core for Host and one for other participants' }
[long]$hostMask = 0
[long]$otherMask = 0
for ($index = 0; $index -lt $coreMasks.Count; $index++) {
    if ($index -lt $HostPhysicalCores) { $hostMask = $hostMask -bor $coreMasks[$index] }
    else { $otherMask = $otherMask -bor $coreMasks[$index] }
}
[PSCustomObject]@{
    method = 'GetLogicalProcessorInformation physical-core masks; Process.ProcessorAffinity'
    physical_core_masks = $coreMasks
    host_physical_cores = $HostPhysicalCores
    host_mask = $hostMask
    clients_and_relay_mask = $otherMask
}
