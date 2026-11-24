#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the shared Zebra ZD220 on THIS client PC as a local printer over
    LPR (TCP 515) - replacing the flaky \\HOST\Zebra SMB connection.

.DESCRIPTION
    - Enables the "LPR Port Monitor" Windows optional feature.
    - Creates an LPR printer port pointing to the host PC + queue "ZD220".
    - Installs the printer as a LOCAL printer with the Zebra driver, so it
      shows up in the printer list like any normal printer (Ctrl+P unchanged)
      and cannot "disappear" due to SMB session / point-and-print issues.
    - Optionally removes the old \\HOST\share connection.
    - Prints a test page at the end (disable with -SkipTestPage).

    Run elevated on each client PC:
        powershell -ExecutionPolicy Bypass -File .\setup-client.ps1 -HostIP 192.168.15.X

.PARAMETER HostIP
    IP address of the print host PC (required). Must be a fixed/reserved IP.

.PARAMETER QueueName
    LPR queue name = printer share name on the host. Default: ZD220

.PARAMETER PrinterName
    Display name of the printer on this client. Default: "Etiquetas ZD220"

.PARAMETER DriverName
    Exact driver name to use. If omitted, auto-detects among installed
    Zebra/ZDesigner/ZPL drivers; aborts with a list if ambiguous or none found
    (install the Zebra driver first - e.g. Zebra Setup Utilities).

.PARAMETER OldSharePath
    Optional. Path of the old shared-printer connection to remove,
    e.g. "\\PC-ANTIGO\ZD220". Removal applies to the current Windows user only.

.PARAMETER SkipTestPage
    Do not print a test page at the end.

.EXAMPLE
    .\setup-client.ps1 -HostIP 192.168.15.100
    .\setup-client.ps1 -HostIP 192.168.15.100 -OldSharePath "\\PC-EXPEDICAO\ZD220" -SkipTestPage
#>
param(
    [Parameter(Mandatory = $true)][string]$HostIP,
    [string]$QueueName   = 'ZD220',
    [string]$PrinterName = 'Etiquetas ZD220',
    [string]$DriverName,
    [string]$OldSharePath,
    [switch]$SkipTestPage
)

$ErrorActionPreference = 'Stop'
$script:step = 0
function Step($msg) { $script:step++; Write-Host "`n[$script:step] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    OK  - $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    AVISO - $msg" -ForegroundColor Yellow }

Write-Host "=== Setup do CLIENTE de impressao (Zebra via LPR -> $HostIP) ===" -ForegroundColor White

# ------------------------------------------------------------ reachability --
Step "Testando conexao com o host $HostIP (porta 515/LPR)"
$reachable = Test-NetConnection -ComputerName $HostIP -Port 515 -InformationLevel Quiet -WarningAction SilentlyContinue
if ($reachable) {
    Ok "Host respondeu na porta 515"
} else {
    Warn "Host NAO respondeu na 515 - a instalacao continua, mas confirme que:"
    Warn "  - o setup-host.ps1 ja rodou no host (e o PC foi reiniciado se pedido)"
    Warn "  - o host esta ligado e o IP $HostIP esta correto"
}

# ---------------------------------------------------------- LPR port mon ----
Step "Habilitando 'LPR Port Monitor' (recurso opcional do Windows)"
try {
    $feat = Enable-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-LPRPortMonitor' -All -NoRestart
    if ($feat.RestartNeeded) {
        Warn "Recurso instalado - REINICIE este PC antes de imprimir"
    } else {
        Ok "LPR Port Monitor habilitado"
    }
    # the port monitor registers with the spooler - restart it so Add-PrinterPort sees it
    try {
        Restart-Service Spooler -Force -ErrorAction Stop
        Ok "Spooler reiniciado (registra o monitor LPR)"
    } catch {
        Warn "Nao consegui reiniciar o spooler - se a criacao da porta falhar, reinicie o PC"
    }
} catch {
    throw "Falha ao habilitar o recurso. Alternativa: Recursos do Windows > Servicos de Impressao > 'Monitor de Porta LPR'. Erro: $($_.Exception.Message)"
}

# ------------------------------------------------------------------ driver --
Step "Resolvendo o driver da impressora"
if (-not $DriverName) {
    $zebraDrivers = @(Get-PrinterDriver | Where-Object { $_.Name -match 'Zebra|ZDesigner|ZD\d{3}|ZPL' } | Select-Object -ExpandProperty Name)
    if ($zebraDrivers.Count -eq 1) {
        $DriverName = $zebraDrivers[0]
    } elseif ($zebraDrivers.Count -gt 1) {
        $exact = @($zebraDrivers | Where-Object { $_ -match 'ZD220' -and $_ -match 'ZPL' })
        if ($exact.Count -eq 1) { $DriverName = $exact[0] }
        else {
            Write-Host "    Drivers Zebra encontrados:" -ForegroundColor Yellow
            $zebraDrivers | ForEach-Object { Write-Host "      - $_" }
            throw "Mais de um driver possivel. Reexecute com -DriverName `"NOME EXATO`"."
        }
    } else {
        throw "Nenhum driver Zebra instalado neste PC. Instale antes (Zebra Setup Utilities / driver 'ZDesigner ZD220-203dpi ZPL') e reexecute."
    }
}
if (-not (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue)) {
    throw "Driver '$DriverName' nao esta instalado. Instale o driver Zebra ou ajuste -DriverName."
}
Ok "Driver: $DriverName"

# -------------------------------------------------------------------- port --
$PortName = "LPR_$QueueName"
Step "Criando porta LPR '$PortName' -> ${HostIP}:$QueueName"
$existing = Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue
if ($existing) {
    Warn "Porta '$PortName' ja existe (host: $($existing.HostAddress)). Reutilizando."
    if ($existing.HostAddress -and $existing.HostAddress -ne $HostIP) {
        Warn "ATENCAO: a porta aponta p/ outro IP ($($existing.HostAddress)). Se estiver errado, remova a impressora e a porta e reexecute."
    }
} else {
    Add-PrinterPort -Name $PortName -LprHostAddress $HostIP -LprQueueName $QueueName
    Ok "Porta LPR criada"
}

# ----------------------------------------------------------------- printer --
Step "Instalando a impressora '$PrinterName'"
$current = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
if ($current) {
    if ($current.PortName -ne $PortName -or $current.DriverName -ne $DriverName) {
        Set-Printer -Name $PrinterName -PortName $PortName -DriverName $DriverName
        Ok "Impressora existente atualizada (porta/driver)"
    } else {
        Ok "Impressora ja existia configurada corretamente"
    }
} else {
    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName
    Ok "Impressora instalada"
}

# ------------------------------------------------------ old share cleanup ---
Step "Removendo conexao antiga (\\HOST\...)"
$removed = $false
if ($OldSharePath) {
    try {
        Remove-Printer -Name $OldSharePath -ErrorAction Stop
        Ok "Conexao '$OldSharePath' removida (usuario atual)"
        $removed = $true
    } catch {
        Warn "Nao consegui remover '$OldSharePath': $($_.Exception.Message)"
    }
}
$leftover = @(Get-Printer | Where-Object { $_.Name -like '\\*' -and $_.Name -match 'ZD|Zebra|etiqueta' })
if ($leftover.Count -gt 0) {
    Warn "Ainda existem conexoes de rede para impressoras Zebra (remova p/ evitar confusao):"
    $leftover | ForEach-Object {
        Write-Host "      - $($_.Name)   [remova com: Remove-Printer '$($_.Name)' ou em Dispositivos e Impressoras]"
    }
} elseif (-not $OldSharePath -and -not $removed) {
    Ok "Nenhuma conexao \\HOST\... de Zebra encontrada"
}

# -------------------------------------------------------------- test page ---
if (-not $SkipTestPage) {
    Step "Imprimindo pagina/etiqueta de teste"
    try {
        Get-CimInstance Win32_Printer | Where-Object Name -eq $PrinterName |
            Invoke-CimMethod -MethodName PrintTestPage | Out-Null
        Ok "Teste enviado - confira se saiu a etiqueta"
    } catch {
        Warn "Falha ao enviar teste: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- summary ---
Write-Host "`n=== Resumo ===" -ForegroundColor White
Write-Host "   Impressora : $PrinterName"
Write-Host "   Porta      : $PortName (LPR -> $HostIP, fila '$QueueName')"
Write-Host "   Driver     : $DriverName"
Write-Host "   Host na 515: " + $(if ($reachable) {'OK'} else {'NAO RESPONDEU - verificar host'})
Write-Host "`nA impressora agora e LOCAL: aparece na lista normal do Ctrl+P e nao" -ForegroundColor Green
Write-Host "depende mais do compartilhamento SMB do Windows." -ForegroundColor Green
