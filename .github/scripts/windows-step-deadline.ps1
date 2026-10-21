# Runs a command with every process it starts in one job object, so an orphan holding the step's
# output cannot outlive the step. At the deadline or exit, prints what is still running and kills it.
param([Parameter(Mandatory)][int]$Minutes, [Parameter(Mandatory)][string]$Command)

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class StepJob {
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length, IntPtr returned);
  static IntPtr job;
  public static void Enter() {
    job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero || !AssignProcessToJobObject(job, GetCurrentProcess())) throw new Win32Exception();
  }
  // JobObjectBasicProcessIdList: two DWORD counts, then the ids as ULONG_PTR.
  public static long[] Pids() {
    int size = 8 + 4096 * IntPtr.Size;
    IntPtr list = Marshal.AllocHGlobal(size);
    try {
      if (!QueryInformationJobObject(job, 3, list, size, IntPtr.Zero)) throw new Win32Exception();
      var pids = new long[Marshal.ReadInt32(list, 4)];
      for (int i = 0; i < pids.Length; i++) pids[i] = Marshal.ReadIntPtr(list, 8 + i * IntPtr.Size).ToInt64();
      return pids;
    } finally { Marshal.FreeHGlobal(list); }
  }
}
'@

[StepJob]::Enter()
$child = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', $Command -NoNewWindow -PassThru
$null = $child.Handle # holds the process open so ExitCode stays readable
$finished = $child.WaitForExit($Minutes * 60000)
$left = @()
# Chrome and worker processes can take a moment to exit after their parent.
$drainUntil = (Get-Date).AddSeconds(10)
do {
  $left = @([StepJob]::Pids() | Where-Object { $_ -ne $PID })
  if (-not $finished -or -not $left) { break }
  Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $drainUntil)
if ($left) {
  $when = if ($finished) { 'after the command exited' } else { "at the $Minutes-minute deadline" }
  Write-Host "Processes still running $($when):"
  Get-CimInstance Win32_Process | Where-Object { $left -contains $_.ProcessId } |
    Format-List ProcessId, ParentProcessId, Name, CommandLine | Out-String -Width 400 | Write-Host
  $left | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
}
if (-not $finished) { Write-Host "::error::Stopped after $Minutes minutes: the command did not finish"; exit 1 }
if ($left) { Write-Host "::error::The command exited but left $($left.Count) process(es) running"; exit 1 }
exit $child.ExitCode
