# Zebra ZD220 — stable print sharing without SMB

Replaces the flaky Windows SMB printer share (`\\HOST\Zebra`) with direct
TCP/IP printing: clients keep a **local printer** that talks LPR (TCP 515) to
the host's built-in **LPD Print Service**. The user experience is identical —
the printer is in the normal list, Ctrl+P just works — but there are no SMB
sessions, network discovery or point-and-print dependencies to break.

```
Client PCs (2-5)                    Host PC (always started first)
+-----------------+                 +----------------------------+
| Local printer   |   TCP 515 LPR   | LPD Print Service          |
| "Etiquetas"     | --------------> | share "ZD220" -> Spooler   |
| Zebra driver    |                 | -> USB -> ZD220            |
+-----------------+                 +----------------------------+
```

> **Honest limit:** the ZD220 is USB-only, so a Windows spooler still owns the
> printer somewhere — this setup removes the fragile layer on top of it and
> auto-restarts the spooler daily. The only way to remove the PC entirely is a
> USB print server box (~R$150, e.g. TP-Link TL-PS110U): same client setup,
> just a RAW 9100 port instead of LPR.

## Files

| File               | Where it runs                    | What it does                                  |
| ------------------ | -------------------------------- | --------------------------------------------- |
| `setup-host.ps1`   | host PC (elevated)               | share + LPD service + firewall + hardening    |
| `setup-client.ps1` | each client PC (elevated)        | local printer via LPR port to the host        |
| `diagnose.ps1`     | host and/or client (elevated)    | health checks + raw job capture (`-Watch`)     |

## Step 0 — physical / network prep (manual)

1. Pick the **host** = the PC that is always the first one powered on.
2. Make sure the ZD220's USB cable can physically reach it.
3. **Fix the host's IP**: DHCP reservation on the router (preferred) or a
   static IP. If the IP changes, clients lose the printer.
4. Plug the ZD220 into the host, install the Zebra driver locally
   (Zebra Setup Utilities / "ZDesigner ZD220-203dpi ZPL") and print a **local
   test label** before touching anything else.
5. Keep the old `\\OLDHOST\Zebra` share alive during migration (rollback).

## Step 1 — host

Elevated PowerShell on the host:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-host.ps1
# or, if auto-detection fails:
powershell -ExecutionPolicy Bypass -File .\setup-host.ps1 -PrinterName "ZDesigner ZD220-203dpi ZPL"
```

It will: share as `ZD220`, enable LPD (TCP 515), open the firewall, set the
network profile to Private, disable sleep/USB-NIC power saving, pin Windows
Update active hours, and create the `Restart-PrintSpooler` task (at boot +
daily at 07:00). **Reboot if it says the LPD service needs it**, then confirm
the self-check shows `Porta 515: SIM`.

## Step 2 — each client (one at a time)

Elevated PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-client.ps1 -HostIP 192.168.15.X

# optionally clean up the old connection in the same pass:
powershell -ExecutionPolicy Bypass -File .\setup-client.ps1 -HostIP 192.168.15.X -OldSharePath "\\PC-ANTIGO\ZD220"
```

Notes:

- The script auto-detects the installed Zebra driver; if it can't, install the
  driver first (Zebra Setup Utilities) or pass `-DriverName "exact name"`.
- `-OldSharePath` removes the connection **for the current user only** — run
  the cleanup under the account that actually prints.
- Validate a real label from the actual workflow on the first client before
  rolling out to the rest.

## Verify

```powershell
# from each client:
Test-NetConnection <HOST_IP> -Port 515        # must be True
```

- [ ] Test label prints via Ctrl+P from the real application
- [ ] Reboot the host → clients print again with zero changes
- [ ] Reboot a client → printer still listed (it's local, cannot vanish)
- [ ] `Stop-Service Spooler` on host → after restart, queued jobs flow
- [ ] Next morning (host was off overnight): first print just works

## Rollback

If anything goes wrong, the old share is still up — reconnect it on a client
with **Add Printer → network printer → `\\OLDHOST\ZD220`**, or remove the new
one: `Remove-Printer "Etiquetas ZD220"`.

## Troubleshooting

| Symptom                                  | Check                                                                 |
| ---------------------------------------- | --------------------------------------------------------------------- |
| `Test-NetConnection ... 515` fails       | host on? `Get-Service LPDSVC` running? firewall rule enabled?          |
| Jobs stuck in client queue               | `Restart-Service Spooler` on the **host** (task does this daily too)   |
| Job sent, queue clears, nothing prints   | run `.\diagnose.ps1 -Watch` on the host while printing — captures the raw job; EPL data into a ZPL printer prints nothing |
| "Printer offline" on client              | host reachable on 515? LPR port monitor marks errors but retries        |
| Driver missing on client                 | install Zebra Setup Utilities driver, re-run script                     |
| Old `\\HOST\Zebra` still listed          | remove under the user's own session: `Remove-Printer "\\HOST\Zebra"`    |
| Host IP changed                          | fix reservation; on clients re-run script (it warns about stale ports)  |

## Daily operation

Nothing. The host restarts its spooler every morning automatically; clients
are fully independent. For a rare mid-day hang, keep a
`restart-spooler.bat` on the host desktop:

```bat
net stop spooler && net start spooler
```
