# Zabbix Windows Updates Monitor (file-based)

Monitoramento de atualizações pendentes do Windows para Zabbix 7.0 LTS, sem
depender de `system.run` nem de módulos de terceiros. Um script PowerShell
roda via Tarefa Agendada e grava um JSON de status; o Zabbix apenas **lê
esse arquivo**.

## Por que essa abordagem

A maioria dos templates de terceiros para Windows Update exige
`AllowKey=system.run[*]` no `zabbix_agentd.conf` para poder disparar
comandos remotamente (verificar e às vezes até aplicar updates). Isso abre
uma superfície de ataque real: qualquer um com acesso à comunicação
agente-servidor passa a poder executar comandos arbitrários no host.

Este projeto separa deliberadamente **monitorar** de **agir**:

- O script roda localmente, agendado, sem input externo.
- O Zabbix só lê `vfs.file.contents`, chave nativa já liberada por padrão.
- Não há aplicação automática de updates — decisão de patch continua sendo
  manual/orquestrada por outra ferramenta (WSUS, SCCM, Intune, etc.).

## Estrutura

```
check_windows_updates.ps1        # Script de coleta (roda no host Windows)
zbx_template_windows_updates.yaml # Template Zabbix 7.0 LTS (import)
```

## Requisitos

- Zabbix Server / Frontend **7.0 LTS**
- Zabbix Agent (1 ou 2) com `vfs.file.contents` habilitado (padrão)
- Windows com PowerShell 5.1+ (usa a API COM nativa `Microsoft.Update.Session`
  — não requer módulo `PSWindowsUpdate`)
- Permissão para criar Tarefa Agendada rodando como `SYSTEM`

## Instalação

### 1. Script no host Windows

```powershell
# Copie check_windows_updates.ps1 para, por exemplo:
# C:\Scripts\check_windows_updates.ps1

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\check_windows_updates.ps1"'
$trigger = New-ScheduledTaskTrigger -Daily -At 6am
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'Zabbix-WinUpdatesCheck' -Action $action `
  -Trigger $trigger -Principal $principal -Description 'Gera status.json para o Zabbix'
```

Teste manual:

```powershell
Start-ScheduledTask -TaskName 'Zabbix-WinUpdatesCheck'
Get-Content C:\ProgramData\ZabbixWinUpdates\status.json
```

### 2. Template no Zabbix

`Data collection → Templates → Import` → selecione
`zbx_template_windows_updates.yaml` → vincule ao host Windows desejado.

## Itens coletados

| Item | Chave | Tipo | Origem |
|---|---|---|---|
| Raw status file | `vfs.file.contents[...]` | Texto | Item mestre |
| Críticos pendentes | `winupdates.critical.count` | Numérico | Dependente (JSONPath) |
| Importantes pendentes | `winupdates.important.count` | Numérico | Dependente |
| Moderados pendentes | `winupdates.moderate.count` | Numérico | Dependente |
| Baixos pendentes | `winupdates.low.count` | Numérico | Dependente |
| Não classificados | `winupdates.unclassified.count` | Numérico | Dependente |
| Total pendente | `winupdates.total.count` | Numérico | Dependente |
| Reboot pendente | `winupdates.reboot.pending` | Booleano | Dependente |
| Última instalação | `winupdates.last_install` | Texto | Dependente |
| Erro do script | `winupdates.script_error` | Texto | Dependente |
| Timestamp do relatório | `winupdates.timestamp` | Texto | Dependente |

## Triggers

| Trigger | Severidade | Condição |
|---|---|---|
| Updates críticos pendentes | High | `critical_count >= {$WINUPDATES.CRITICAL.MIN}` |
| Updates importantes pendentes | Warning | `important_count >= {$WINUPDATES.IMPORTANT.MIN}` |
| Reboot pendente | Warning | `reboot_pending = 1` |
| Status desatualizado | Average | sem dado novo em `{$WINUPDATES.STALE.TIME}` |
| Erro no script de coleta | Warning | campo `error` do JSON preenchido |

## Macros

| Macro | Padrão | Descrição |
|---|---|---|
| `{$WINUPDATES.CRITICAL.MIN}` | `1` | Mínimo de updates críticos para alertar |
| `{$WINUPDATES.IMPORTANT.MIN}` | `1` | Mínimo de updates importantes para alertar |
| `{$WINUPDATES.STALE.TIME}` | `2d` | Tempo sem report antes de alarmar "script parado" |

## Detecção de reboot pendente

Verifica três chaves de registro específicas de Windows Update/CBS:

- `WindowsUpdate\Auto Update\RebootRequired`
- `Component Based Servicing\RebootPending`
- `Component Based Servicing\RebootInProgress`

**Nota:** `PendingFileRenameOperations` (`Session Manager`) foi
deliberadamente excluído do critério. Essa chave é setada por qualquer
instalador que precise renomear/excluir arquivo em uso no próximo boot
(drivers de impressora, .NET, antivírus, etc.), não só Windows Update, e
gera falsos positivos persistentes sem relação com patch de segurança.

## Limitações conhecidas

- Não aplica updates — apenas monitora.
- `MsrcSeverity` vem vazio para updates de feature/preview/driver — por
  isso existe o contador `unclassified_count`.
- O item mestre atualiza a cada 1h (`delay`), mas o dado real só muda
  quando a Tarefa Agendada roda (padrão diário).
- Testado apenas via API COM `Microsoft.Update.Session` — ambientes com
  WSUS configurado via GPO (`UseWUServer=1`) mas sem rota até o servidor
  WSUS vão reportar `error` preenchido no JSON.

## Licença

Uso interno / adaptar livremente conforme necessidade.
