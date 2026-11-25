#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Diagnostics for the ZD220 LPD/LPR print setup. Run on the HOST or on a CLIENT.

.DESCRIPTION
    HOST mode (auto-detected when LPDSVC exists):
      - lists printers/share names/ports/drivers
      - checks LPDSVC service + TCP 515 listener + firewall rule
      - reads recent PrintService events
      - with -Watch: pauses the Zebra queue, waits for a job to arrive from a
        client, copies the raw .SPL spool file and prints a preview of the
        actual bytes received (reveals ZPL vs EPL vs EMF/garbage), then
        resumes the queue.

    CLIENT mode (auto-detected when an LPR_* port exists):
      - shows the installed printer + port + driver
      - verifies TCP 515 reachability to the host
      - shows the configured LPR queue name
      - optionally sends a test page (-SendTest)

    Run elevated:
        powershell -ExecutionPolicy Bypass -File .\diagnose.ps1

.EXAMPLE
    # on the HOST, while you send a test from the client:
    .\diagnose.ps1 -Watch

.EXAMPLE
    # on a CLIENT:
    .\diagnose.ps1
    .\diagnose.ps1 -SendTest
#>
param(
    [string]$PrinterName,
    [string]$HostIP,
    [switch]$Watch,
    [int]$WatchSeconds = 90,
    [switch]$SendTest
)

$ErrorActionPreference = 'Continue'
function Hdr($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  OK    - $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  AVISO - $msg" -ForegroundColor Yellow }
function Bad($msg)  { Write-Host "  FALHA - $msg" -ForegroundColor Red }

$isHost   = [bool](Get-Service LPDSVC -ErrorAction SilentlyContinue)
$lprPorts = @(Get-PrinterPort | Where-Object { $_.Name -like 'LPR_*' })
$isClient = $lprPorts.Count -gt 0

Write-Host "Papel detectado: " -NoNewline
if ($isHost -and $isClient) { Write-Host "HOST + CLIENTE" -ForegroundColor White }
elseif ($isHost)            { Write-Host "HOST" -ForegroundColor White }
elseif ($isClient)          { Write-Host "CLIENTE" -ForegroundColor White }
else                        { Write-Host "indefinido - mostrando tudo" -ForegroundColor Yellow }

# ========================================================================== #
#  HOST SIDE                                                                 #
# ========================================================================== #
if ($isHost) {
    Hdr "HOST - impressoras e compartilhamentos"
    Get-Printer | Select-Object Name, DriverName, PortName, ShareName, Shared |
        Format-Table -AutoSize | Out-Host

    $shared = @(Get-Printer | Where-Object Shared)
    if (-not $shared) { Bad "NENHUMA impressora compartilhada - a fila LPR nao existe sem share!" }
    else {
        foreach ($s in $shared) { Ok "Share '$($s.ShareName)' -> impressora '$($s.Name)' (porta $($s.PortName))" }
        Warn "Lembre: a fila LPR do cliente deve ser EXATAMENTE o ShareName (ex.: ZD220)"
    }

    Hdr "HOST - servico LPD e porta 515"
    $svc = Get-Service LPDSVC
    if ($svc.Status -eq 'Running') { Ok "LPDSVC Running (StartType: $($svc.StartType))" }
    else { Bad "LPDSVC esta $($svc.Status) - suba com: Start-Service LPDSVC" }

    $l515 = Get-NetTCPConnection -LocalPort 515 -State Listen -ErrorAction SilentlyContinue
    if ($l515) { Ok "TCP 515 em Listen" } else { Bad "Nada ouvindo na 515" }

    $fw = Get-NetFirewallRule -ErrorAction SilentlyContinue |
          Where-Object { $_.DisplayName -match 'LPD|515' -and $_.Direction -eq 'Inbound' }
    if ($fw) { $fw | Select-Object DisplayName, Enabled, Profile | Format-Table -AutoSize | Out-Host }
    else     { Bad "Nenhuma regra de firewall p/ 515 - rode setup-host.ps1" }

    Hdr "HOST - ultimos eventos de impressao"
    $log = 'Microsoft-Windows-PrintService/Admin'
    Get-WinEvent -LogName $log -MaxEvents 8 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, LevelDisplayName, Message |
        Format-List | Out-Host

    # ------------------------------------------------------------- WATCH ---
    if ($Watch) {
        Hdr "HOST - captura de job (fila pausada por ${WatchSeconds}s)"

        # pick the printer to watch: param > shared Zebra > any shared
        if (-not $PrinterName) {
            $cand = @($shared | Where-Object { $_.ShareName -eq 'ZD220' -or $_.Name -match 'Zebra|ZD' })
            if (-not $cand) { $cand = $shared }
            if ($cand.Count -eq 1) { $PrinterName = $cand[0].Name }
            else { Bad "Ambiguo - reexecute com -PrinterName `"NOME`""; $Watch = $false }
        }

        if ($Watch) {
            $wmi = Get-CimInstance Win32_Printer | Where-Object Name -eq $PrinterName
            $spoolDir = "$env:SystemRoot\System32\spool\PRINTERS"
            $capDir   = Join-Path $PSScriptRoot 'diagnose-capture'
            New-Item -ItemType Directory -Path $capDir -Force | Out-Null

            Write-Host "  Pausando fila '$PrinterName'..." -ForegroundColor White
            Invoke-CimMethod -InputObject $wmi -MethodName Pause | Out-Null
            Write-Host "  >>> Agora mande uma impressao de teste a partir do CLIENTE <<<" -ForegroundColor Magenta

            $seen = @{}
            $t0   = Get-Date
            try {
                while (((Get-Date) - $t0).TotalSeconds -lt $WatchSeconds) {
                    foreach ($j in (Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue)) {
                        if (-not $seen[$j.Id]) {
                            $seen[$j.Id] = $true
                            Write-Host ""
                            Ok "JOB CHEGOU NA FILA DO HOST!"
                            Write-Host "      Document : $($j.DocumentName)"
                            Write-Host "      Size     : $($j.Size) bytes"
                            Write-Host "      Datatype : $($j.Datatype)"
                            Write-Host "      Submitted: $($j.SubmittedTime)"
                        }
                    }
                    # copy fresh .SPL files while paused (they persist until resume)
                    Get-ChildItem $spoolDir -Filter '*.SPL' -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -gt $t0 } |
                        ForEach-Object {
                            $dst = Join-Path $capDir ("{0:HHmmss}_{1}" -f $_.LastWriteTime, $_.Name)
                            if (-not (Test-Path $dst)) {
                                try { Copy-Item $_.FullName $dst -ErrorAction Stop } catch {}
                            }
                        }
                    Start-Sleep -Seconds 2
                }
            } finally {
                Write-Host "`n  Retomando a fila..." -ForegroundColor White
                Invoke-CimMethod -InputObject $wmi -MethodName Resume | Out-Null
            }

            if ($seen.Count -eq 0) {
                Bad "NENHUM job chegou - o problema esta ANTES da fila (IP/porta/fila/firewall/driver no cliente)"
            }

            Get-ChildItem $capDir -Filter '*.SPL' | ForEach-Object {
                $bytes = Get-Content $_.FullName -Encoding Byte -TotalCount 160
                $preview = -join ($bytes | ForEach-Object {
                    if ($_ -ge 32 -and $_ -le 126) { [char]$_ } else { '.' }
                })
                Write-Host "`n  Capturado: $($_.Name)" -ForegroundColor Cyan
                Write-Host "    primeiros bytes: $preview"
                if     ($preview -match '\^XA|\^X') { Ok    "Conteudo parece ZPL - host deveria repassar e imprimir" }
                elseif ($preview -match '^(N|q\d|B\d|A\d|P\d|I8,)') { Warn "Conteudo parece EPL! Impressora em modo ZPL ignora EPL -> sai nada. Troque o driver do cliente p/ variante ZPL" }
                elseif ($preview -match 'EMF|\x01\x00') { Warn "Conteudo binario/EMF - cliente nao renderizou. Verifique driver/datatype no cliente" }
                else   { Warn "Conteudo irreconhecivel - abra o arquivo no Bloco de Notas para inspecao" }
            }
        }
    }
}

# ========================================================================== #
#  CLIENT SIDE                                                               #
# ========================================================================== #
if ($isClient -or (-not $isHost -and -not $isClient)) {
    Hdr "CLIENTE - impressoras locais"
    Get-Printer | Where-Object { $_.PortName -like 'LPR_*' -or $_.Name -match 'ZD|Zebra|Etiqueta' } |
        Select-Object Name, DriverName, PortName, PrinterStatus |
        Format-Table -AutoSize | Out-Host

    Hdr "CLIENTE - portas LPR"
    foreach ($p in $lprPorts) {
        $p | Format-List Name, HostAddress, PortNumber, Protocol | Out-Host
        if ($p.Name -match 'LPR_(.+)') { $queue = $Matches[1] }
        if (-not $HostIP -and $p.HostAddress) { $HostIP = $p.HostAddress }
    }

    # the authoritative LPR config lives in the port monitor registry, not in
    # the PrinterPort CIM object (HostAddress can show empty there)
    Hdr "CLIENTE - config real das portas LPR (registro do monitor)"
    $lprReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\LPR Port\Ports'
    if (Test-Path $lprReg) {
        Get-ChildItem $lprReg | ForEach-Object {
            $cfg = Get-ItemProperty $_.PSPath
            Write-Host "  Porta: $($_.PSChildName)" -ForegroundColor White
            $cfg.PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Provider|Drive)$' } |
                ForEach-Object { Write-Host "      $($_.Name) = $($_.Value)" }
        }
        $srv = (Get-ItemProperty "$lprReg\LPR_$queue" -ErrorAction SilentlyContinue).ServerName
        if (-not $srv) { $srv = (Get-ChildItem $lprReg | Select-Object -First 1 | ForEach-Object { (Get-ItemProperty $_.PSPath).ServerName }) }
        if ($srv -and -not $HostIP) { $HostIP = $srv }
        if (-not $srv) { Bad "Nenhum ServerName configurado nas portas LPR - porta criada errada!" }
    } else {
        Bad "Chave 'LPR Port' nao existe no registro - o LPR Port Monitor NAO esta instalado neste PC!"
    }

    if ($HostIP) {
        Hdr "CLIENTE - conectividade com host $HostIP"
        $ok515 = Test-NetConnection -ComputerName $HostIP -Port 515 -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($ok515) { Ok "$HostIP :515 acessivel" }
        else { Bad "$HostIP :515 INACESSIVEL - host desligado? LPDSVC parado? firewall?" }
    }

    if ($queue) {
        Write-Host "`n  Fila LPR configurada: '$queue'" -ForegroundColor White
        Warn "No host, a impressora deve estar compartilhada como EXATAMENTE '$queue'"
    }

    if ($SendTest) {
        Hdr "CLIENTE - enviando pagina de teste"
        $cliPrinter = @(Get-Printer | Where-Object PortName -like 'LPR_*')
        if ($cliPrinter.Count -eq 1) {
            $nm = $cliPrinter[0].Name
            Get-CimInstance Win32_Printer | Where-Object Name -eq $nm |
                Invoke-CimMethod -MethodName PrintTestPage | Out-Null
            Ok "Teste enviado p/ '$nm' - observe a fila: Get-PrintJob -PrinterName '$nm'"
        } else {
            Warn "Nenhuma/varias impressoras LPR - teste nao enviado"
        }
    }
}

Hdr "Resumo do que procurar"
Write-Host @"
  1) Job NAO aparece na fila do host (Watch)   -> checar IP, porta 515, nome da fila = ShareName
  2) Job aparece, Datatype/Size ok, nao imprime-> conteudo EPL/EMF: ajustar driver do CLIENTE p/ ZPL
  3) Job aparece e Some mas imprime            -> tudo certo :)
"@ -ForegroundColor DarkGray
