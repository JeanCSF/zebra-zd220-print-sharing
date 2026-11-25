# Troubleshooting — client sends job, nothing prints

Symptom: the client prints "successfully" (job leaves the queue, nothing
stuck) but the ZD220 outputs nothing. Host prints fine locally.

Work through the steps **in order** — each one narrows down where the job dies.

> All commands run in an **elevated PowerShell** (right-click → Run as
> administrator). `<HOST_IP>` = the host's fixed/reserved IPv4 address.

---

## Step 0 — sanity checks on the CLIENT (30 seconds)

```powershell
# 1. The LPR port monitor feature must be Enabled - if it was just installed
#    and the PC was NOT rebooted, printing silently fails.
Get-WindowsOptionalFeature -Online -FeatureName Printing-Foundation-LPRPortMonitor | Select-Object State
#   -> must say "Enabled". If "Disabled"/pending: enable and REBOOT the client.

# 2. The printer must exist as a local printer on an LPR port
Get-Printer "Etiquetas ZD220" | Select-Object Name, DriverName, PortName
#   -> PortName must be LPR_ZD220, DriverName should be the *ZPL* variant.

# 3. Reachability to the host
Test-NetConnection <HOST_IP> -Port 515
#   -> TcpTestSucceeded must be True.
#      False = host off, LPDSVC stopped, or firewall blocking.
```

---

## Step 1 — read the REAL port configuration (CLIENT)

`Get-PrinterPort` can show an empty `HostAddress` for LPR ports — the
authoritative config lives in the port monitor registry. **Important:** ports
created by `Add-PrinterPort -LprHostAddress` usually register under the
**`Standard TCP/IP Port`** monitor (with `Protocol = 2` = LPR), NOT under the
legacy `LPR Port` monitor — an empty `LPR Port\Ports` key is normal.

Enumerate **all** monitors to find where the port really lives:

```powershell
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors' |
    ForEach-Object { $mon = $_.PSChildName
        Get-ChildItem "$($_.PSPath)\Ports" -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "[$mon] $($_.PSChildName)"; Get-ItemProperty $_.PSPath | Format-List } }
```

Expected entry (somewhere in the output):

```
[Standard TCP/IP Port] LPR_ZD220
    HostAddress : <HOST_IP>
    PortNumber  : 515
    Protocol    : 2          (1 = RAW, 2 = LPR)
    Queue       : ZD220
```

| Finding                                        | Meaning / fix                                      |
| ---------------------------------------------- | -------------------------------------------------- |
| `LPR_ZD220` appears **under no monitor**       | Port was never really created → [recreate it](#fix--recreate-the-lpr-port) |
| `HostAddress` wrong/empty or `Queue` ≠ `ZD220` | Broken config → recreate the port                  |
| `Protocol` = 1                                 | RAW protocol — wrong for Windows LPD → recreate with `-LprHostAddress/-LprQueueName` |
| Everything correct                             | Go to Step 2                                       |

---

## Step 2 — capture where the job dies (HOST + CLIENT together)

The definitive test: pause the host queue and watch whether the job even
arrives.

1. **On the HOST**, start the watcher (pauses the queue, waits, resumes
   automatically):

   ```powershell
   .\diagnose.ps1 -Watch -WatchSeconds 120
   ```

2. **Immediately on the CLIENT**, send a test page:
   Settings → Printers → "Etiquetas ZD220" → **Print test page** — or:

   ```powershell
   Get-CimInstance Win32_Printer | Where-Object Name -eq "Etiquetas ZD220" |
       Invoke-CimMethod -MethodName PrintTestPage
   ```

   > The test must be sent **while** the watcher runs — if it says "NENHUM
   > job chegou" but you sent the test before/after the window, redo it.

3. **Check the client queue right after sending:**

   ```powershell
   Get-PrintJob -PrinterName "Etiquetas ZD220"
   # -> "Error-Printing" status = the port monitor tried to send and failed
   #    (confirms broken port config or unreachable host)
   ```

---

## Step 3 — interpret the result

### A) Job does NOT appear on the host queue

The problem is **before** the queue — one of:

| Cause                                  | How to confirm                                   | Fix                                      |
| -------------------------------------- | ------------------------------------------------ | ---------------------------------------- |
| Wrong/missing `ServerName` in port     | Step 1 registry dump                             | Recreate port (below)                    |
| `Queue` ≠ host ShareName               | Step 1 vs `Get-Printer` ShareName on host        | Recreate port with correct queue name    |
| Client can't reach 515                 | `Test-NetConnection <HOST_IP> -Port 515`         | Host on? `Start-Service LPDSVC`; firewall rule |
| LPR feature pending reboot             | Step 0 check #1                                  | Reboot client, recreate port             |
| Printer mapped to the wrong port       | Step 0 check #2 (`PortName`)                     | `Set-Printer -Name "Etiquetas ZD220" -PortName LPR_ZD220` |

### B) Job ARRIVES on the host queue but nothing prints

The transport works — the **content** is wrong. `diagnose.ps1 -Watch` copies
the raw `.SPL` into `diagnose-capture\` and prints a byte preview:

| First bytes look like                  | Meaning                                          | Fix                                      |
| -------------------------------------- | ------------------------------------------------ | ---------------------------------------- |
| `^XA ...`                              | Valid ZPL — host *should* print it               | Check host queue port = `USB00x`, not `PORTPROMPT:`/`FILE:`; test locally again |
| `N`, `q200`, `B...`, `A...`            | **EPL data** — a ZPL-mode printer silently ignores it | Switch the **client** to the `ZDesigner ZD220-203dpi ZPL` driver variant (below) |
| Binary junk / `EMF`                    | Client didn't render — wrong driver              | Reinstall ZDesigner driver on client     |

### C) Job arrives, prints — done 🎉

---

## Fix — recreate the LPR port

Run elevated **on the client**:

```powershell
Remove-Printer -Name "Etiquetas ZD220"
Remove-PrinterPort -Name LPR_ZD220 -ErrorAction SilentlyContinue
.\setup-client.ps1 -HostIP <HOST_IP>
```

Then **reboot the client once** if the LPR feature was recently enabled —
the port monitor can silently misbehave until the first restart.

## Fix — switch the client driver to the ZPL variant

```powershell
# list available Zebra drivers on the client
Get-PrinterDriver | Where-Object Name -match 'Zebra|ZDesigner'

# if "ZDesigner ZD220-203dpi ZPL" exists:
Set-Printer -Name "Etiquetas ZD220" -DriverName "ZDesigner ZD220-203dpi ZPL"

# if only the EPL variant exists, install the ZPL one via Zebra Setup
# Utilities (choose the ZPL driver variant during install), then rerun
```

## Fix — host-side quick checks

```powershell
Get-Service LPDSVC                                  # must be Running
Get-Printer | Where-Object Shared | Select Name, ShareName, PortName
#   ShareName must be exactly "ZD220", PortName must be the USB port.
Restart-Service Spooler -Force                      # clears a wedged queue
```

---

## Quick decision map

```
client sends job
   |
   +-- Get-PrintJob shows "Error-Printing" ---> broken port / unreachable host -> Step 1 + recreate port
   |
   +-- job leaves cleanly
          |
          +-- host -Watch shows NOTHING ---> never arrived: IP/port/queue/feature -> Steps 0-1
          |
          +-- host -Watch captures job
                    |
                    +-- bytes = EPL/EMF ---> wrong driver variant on client -> ZPL fix
                    +-- bytes = ZPL but no print ---> host queue port/driver issue
```
