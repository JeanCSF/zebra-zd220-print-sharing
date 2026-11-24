#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures this PC as the stable print host for the Zebra ZD220.

.DESCRIPTION
    - Shares the local Zebra printer as "ZD220" (the share name doubles as the
      LPR queue name).
    - Enables the built-in Windows LPD Print Service so clients can print over
      plain TCP 515 (LPR) instead of SMB printer sharing.
    - Opens TCP 515 inbound on the Private firewall profile.
    - Hardens the machine against the usual causes of print outages:
        * never sleeps/hibernates on AC power
        * USB selective suspend disabled
        * NIC "allow the computer to turn off this device" disabled
        * Windows Update active hours pinned to the workday
        * daily scheduled task restarts the print spooler (clears jobs that
          got stuck overnight) + one restart at every boot
    - Ends with a self-check (port 515 listening, share exists, task exists).

    Run elevated:
        powershell -ExecutionPolicy Bypass -File .\setup-host.ps1

.PARAMETER PrinterName
    Exact name of the local Zebra printer. If omitted, the script auto-detects
    printers matching Zebra/ZD/ZDesigner patterns and aborts with a list when
    ambiguous - re-run with -PrinterName in that case.

.PARAMETER ShareName
    Share/queue name exposed via LPR. Keep it short and without spaces.
    Default: ZD220

.PARAMETER RestartHour
    Hour (0-23) for the daily spooler restart task. Default: 7

.EXAMPLE
    .\setup-host.ps1
    .\setup-host.ps1 -PrinterName "ZDesigner ZD220-203dpi ZPL" -RestartHour 6
#>
param(
    [string]$PrinterName,
    [string]$ShareName = 'ZD220',
    [ValidateRange(0,23)][int]$RestartHour = 7
)

$ErrorActionPreference = 'Stop'
$script:step = 0
function Step($msg) { $script:step++; Write-Host "`n[$script:step] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    OK  - $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    AVISO - $msg" -ForegroundColor Yellow }

Write-Host "=== Setup do HOST de impressao (Zebra ZD220 via LPD) ===" -ForegroundColor White

# ---------------------------------------------------------------- printer ---
Step "Localizando a impressora Zebra neste PC"
if (-not $PrinterName) {
    $candidates = @(Get-Printer | Where-Object { $_.Name -match 'Zebra|ZD\d{3}|ZDesigner|GC420|GK420' })
    if ($candidates.Count -eq 0) {
        $candidates = @(Get-Printer | Where-Object { $_.PortName -match '^(USB|DOT4)' })
    }
    if ($candidates.Count -eq 1) {
        $PrinterName = $candidates[0].Name
    } else {
        Get-Printer | Select-Object Name, PortName, DriverName | Format-Table -AutoSize
        throw "Nao consegui identificar a Zebra automaticamente. Reexecute com -PrinterName `"NOME EXATO`"."
    }
}
$printer = Get-Printer -Name $PrinterName
Ok "Impressora: '$PrinterName' | porta $($printer.PortName) | driver $($printer.DriverName)"

# ------------------------------------------------------------------ share ---
Step "Compartilhando como '$ShareName'"
Set-Printer -Name $PrinterName -Shared $true -ShareName $ShareName -Published $false
try {
    Set-Printer -Name $PrinterName -RenderingMode CSR
    Ok "Renderizacao no cliente habilitada (menos carga no spooler do host)"
} catch {
    Warn "RenderingMode=CSR nao aplicado (sem impacto p/ clientes LPR - eles ja renderizam local)"
}
try {
    $wmi = Get-CimInstance Win32_Printer | Where-Object Name -eq $PrinterName
    if ($wmi.EnableBIDI) {
        $wmi.EnableBIDI = $false
        Set-CimInstance -InputObject $wmi
        Ok "Suporte bidirecional desativado (evita travamentos de polling de status)"
    } else {
        Ok "Bidirecional ja desativado"
    }
} catch {
    Warn "Nao consegui desativar bidirecional - faca manual: Propriedades > Portas > desmarcar 'Habilitar suporte bidirecional'"
}
Ok "Share ativo: \\$env:COMPUTERNAME\$ShareName"

# -------------------------------------------------------------------- LPD ---
Step "Habilitando 'LPD Print Service' (recurso opcional do Windows)"
try {
    $feat = Enable-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-LPDPrintService' -All -NoRestart
    if ($feat.RestartNeeded) {
        Warn "Recurso instalado - sera necessario REINICIAR o PC para o servico subir"
    } else {
        Ok "LPD Print Service habilitado"
    }
} catch {
    throw "Falha ao habilitar o recurso. Alternativa manual: Painel > Recursos do Windows > Servicos de Impressao > 'Servico de Impressao LPD'. Erro: $($_.Exception.Message)"
}

$svc = Get-Service -Name 'LPDSVC' -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.StartType -ne 'Automatic') { Set-Service LPDSVC -StartupType Automatic }
    if ($svc.Status -ne 'Running') {
        try { Start-Service LPDSVC; Ok "Servico LPDSVC iniciado" }
        catch { Warn "LPDSVC instalado mas nao iniciou - REINICIE o PC ao final do setup" }
    } else { Ok "Servico LPDSVC rodando" }
} else {
    Warn "LPDSVC ainda nao existe - normal se o recurso exigir reinicio. REINICIE o PC ao final."
}

# --------------------------------------------------------------- firewall ---
Step "Liberando TCP 515 no firewall (perfil Privado)"
$ruleName = 'LPD Service (TCP 515)'
if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
    Enable-NetFirewallRule -DisplayName $ruleName
    Ok "Regra '$ruleName' ja existia - garantida habilitada"
} else {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 515 -Profile Private | Out-Null
    Ok "Regra '$ruleName' criada"
}
Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'LPD|Line Printer' } |
    Enable-NetFirewallRule -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- network ---
Step "Fixando perfil de rede como 'Privado'"
Get-NetConnectionProfile | Where-Object { $_.InterfaceAlias -notlike '*Loopback*' } | ForEach-Object {
    if ($_.NetworkCategory -ne 'Private') {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
        Ok "'$($_.Name)' -> Privado"
    } else { Ok "'$($_.Name)' ja e Privado" }
}

# ------------------------------------------------------------------- power ---
Step "Desativando suspensao/hibernacao e economia USB na tomada"
powercfg /change standby-timeout-ac 0  | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
# USB selective suspend OFF (GUID: USB settings > selective suspend)
powercfg -SETACVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
powercfg -SETACTIVE SCHEME_CURRENT | Out-Null
Ok "PC nao dorme na tomada; suspensao seletiva USB desligada"

Step "Desativando 'permitir desligar dispositivo p/ economizar energia' nas NICs"
foreach ($nic in (Get-NetAdapter -Physical | Where-Object Status -eq 'Up')) {
    try {
        $dev = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop |
               Where-Object { $_.InstanceName -like "$($nic.PNPDeviceID)*" }
        if ($dev -and $dev.Enable) {
            $dev.Enable = $false
            Set-CimInstance -InputObject $dev
            Ok "Energia da NIC '$($nic.Name)' desativada"
        } elseif ($dev) {
            Ok "NIC '$($nic.Name)' ja estava ok"
        } else {
            Warn "NIC '$($nic.Name)': controle nao encontrado - cheque Gerenciador de Dispositivos > placa > Energia"
        }
    } catch {
        Warn "NIC '$($nic.Name)': $($_.Exception.Message)"
    }
}

# ------------------------------------------------------- windows update -----
Step "Definindo horario ativo do Windows Update (06h - 23h)"
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
if (-not (Test-Path $ux)) { New-Item $ux -Force | Out-Null }
Set-ItemProperty $ux -Name 'ActiveHoursStart' -Value 6  -Type DWord
Set-ItemProperty $ux -Name 'ActiveHoursEnd'   -Value 23 -Type DWord
Ok "Reboots de update fora do horario de expediente"

# --------------------------------------------------------- scheduled task ---
Step "Criando tarefa agendada de auto-reinicio do spooler"
$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
       -Argument '-NoProfile -WindowStyle Hidden -Command "Restart-Service Spooler -Force"'
$trg = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Daily -At ([DateTime]::Today.AddHours($RestartHour)))
)
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
       -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'Restart-PrintSpooler' -Action $act -Trigger $trg `
    -Settings $set -User 'SYSTEM' -RunLevel Highest -Force `
    -Description 'Reinicia o spooler de impressao: limpa jobs travados da vespera e auto-recupera fila travada.' | Out-Null
Ok "Tarefa 'Restart-PrintSpooler': no boot + todo dia as $($RestartHour)h (como SYSTEM)"

# -------------------------------------------------------------- self check ---
Step "Verificacao final"
$svc   = Get-Service LPDSVC -ErrorAction SilentlyContinue
$port  = if ($svc -and $svc.Status -eq 'Running') {
            Test-NetConnection -ComputerName 127.0.0.1 -Port 515 -InformationLevel Quiet -WarningAction SilentlyContinue
         } else { $false }
$share = [bool](Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)
$task  = [bool](Get-ScheduledTask -TaskName 'Restart-PrintSpooler' -ErrorAction SilentlyContinue)

Write-Host ""
Write-Host ("   Servico LPDSVC rodando:            " + $(if ($svc.Status -eq 'Running') {'SIM'} else {'NAO - reinicie o PC e reteste'}))
Write-Host ("   Porta 515 (LPR) ouvindo:           " + $(if ($port) {'SIM'} else {'NAO - reinicie o PC e reteste'}))
Write-Host ("   Compartilhamento '$ShareName' criado: " + $(if ($share) {'SIM'} else {'NAO'}))
Write-Host ("   Tarefa Restart-PrintSpooler:       " + $(if ($task) {'SIM'} else {'NAO'}))

Write-Host "`nIP(s) deste PC - anote para configurar os clientes:" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.*' -and $_.InterfaceAlias -notlike '*Loopback*' -and $_.InterfaceAlias -notlike 'vEthernet*' } |
    ForEach-Object { Write-Host "   $($_.InterfaceAlias): $($_.IPAddress)" }

Write-Host "`nIMPORTANTE: reserve este IP no roteador (DHCP reservation) ou configure IP fixo," -ForegroundColor Yellow
Write-Host "senao os clientes perdem a impressora quando o IP mudar." -ForegroundColor Yellow
Write-Host "`nProximo passo (em cada cliente):  .\setup-client.ps1 -HostIP <IP acima>" -ForegroundColor Green
