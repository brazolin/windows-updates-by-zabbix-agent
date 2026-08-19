<#
.SYNOPSIS
    Verifica atualizacoes pendentes do Windows e grava um JSON de status para o Zabbix ler.

.DESCRIPTION
    Usa a API COM nativa do Windows Update Agent (Microsoft.Update.Session) - nao depende
    de modulos de terceiros (PSWindowsUpdate) nem de acesso à internet alem do proprio
    Windows Update. Roda como tarefa agendada (SYSTEM), sem precisar de system.run no Zabbix.

.NOTES
    Saida: C:\ProgramData\ZabbixWinUpdates\status.json
    Execucao recomendada: Tarefa Agendada, 1x por dia (ou a cada X horas), conta SYSTEM.
#>

$ErrorActionPreference = 'Stop'

$outputDir  = 'C:\ProgramData\ZabbixWinUpdates'
$outputFile = Join-Path $outputDir 'status.json'

if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

function Get-RebootPending {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
    )
    # PendingFileRenameOperations foi removido do criterio: essa chave e setada por
    # qualquer instalador (drivers de impressora, .NET, antivirus, etc.), nao so
    # Windows Update, e gera falsos positivos persistentes sem relacao com patch.
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

function Get-LastInstallDate {
    try {
        $hotfix = Get-HotFix -ErrorAction SilentlyContinue |
                   Sort-Object InstalledOn -Descending |
                   Select-Object -First 1
        if ($hotfix -and $hotfix.InstalledOn) {
            return $hotfix.InstalledOn.ToString('yyyy-MM-ddTHH:mm:ss')
        }
    } catch {}
    return $null
}

$result = [ordered]@{
    timestamp          = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    hostname            = $env:COMPUTERNAME
    critical_count      = 0
    important_count     = 0
    moderate_count      = 0
    low_count           = 0
    unclassified_count  = 0
    total_pending       = 0
    reboot_pending      = [int](Get-RebootPending)
    last_install_date   = Get-LastInstallDate
    error               = $null
}

try {
    $updateSession  = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()

    # IsInstalled=0 and IsHidden=0 -> so atualizacoes pendentes e visiveis
    $searchResult = $updateSearcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

    foreach ($update in $searchResult.Updates) {
        switch ($update.MsrcSeverity) {
            'Critical'  { $result.critical_count++ }
            'Important' { $result.important_count++ }
            'Moderate'  { $result.moderate_count++ }
            'Low'       { $result.low_count++ }
            default     { $result.unclassified_count++ }
        }
    }

    $result.total_pending = $searchResult.Updates.Count
}
catch {
    $result.error = $_.Exception.Message
}

$result | ConvertTo-Json -Depth 3 | Set-Content -Path $outputFile -Encoding UTF8 -Force
