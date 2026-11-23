# WinKit

**PT-BR** · [English](#english)

Kit open source para **preparar, otimizar, proteger e diagnosticar Windows**: Windows 10/11 e Windows Server 2016, 2019, 2022 e 2025, inclusive **Server Core**. Para técnicos de TI, MSPs, sysadmins e usuários avançados.

> Em desenvolvimento (0.1). Hoje: Core completo e o módulo **Health** (diagnóstico e reparo da imagem do Windows). Próximos: Updates, Apps e Drivers.

## Princípios
- **Seguro por padrão:** nada destrutivo sem confirmação; todo módulo aceita `-DryRun`.
- **Reversível:** cada execução tem um `RunId`; o estado anterior de registro e serviços fica guardado e `winkit undo -RunId <id>` desfaz. No Desktop, um ponto de restauração é criado antes de qualquer alteração.
- **Não quebra o Windows:** sem "debloat" que remova componentes do sistema, sem desligar Windows Update ou Defender de vez.
- **Sem dependências:** PowerShell 5.1 nativo, compatível com PowerShell 7. Ferramentas externas são baixadas sob demanda da fonte oficial, com SHA-256 e assinatura conferidos.
- **Transparente:** log completo, relatório antes/depois e código legível. **Sem telemetria.**

## Uso rápido (sem baixar nada)
Abra o **PowerShell como administrador** e rode:

```powershell
irm https://github.com/webpeak-br/winkit/releases/latest/download/winkit.ps1 | iex
```

Abre um menu com diagnóstico, reparo, relatórios e desfazer. Se o PowerShell não estiver como administrador, o WinKit pede a elevação sozinho. O arquivo é gerado a partir do código deste repositório a cada versão; o SHA-256 está em `SHA256SUMS.txt` na release.

Para automação, passe o comando direto:
```powershell
& ([scriptblock]::Create((irm https://github.com/webpeak-br/winkit/releases/latest/download/winkit.ps1))) run -Module Health
```

### Com o .zip
Baixe o `WinKit.zip` da [última versão](https://github.com/webpeak-br/winkit/releases), extraia e, num prompt:

```cmd
WinKit.cmd run -Module Health                 :: diagnóstico (não altera nada)
WinKit.cmd run -Profile Reparo-Sistema -DryRun :: mostra o que faria
WinKit.cmd run -Profile Reparo-Sistema         :: DISM /RestoreHealth + SFC, com relatório
WinKit.cmd runs                                :: execuções anteriores
WinKit.cmd undo -RunId 20261124-101500-a1b2c3  :: desfaz uma execução
WinKit.cmd report                              :: abre o relatório da última execução
WinKit.cmd list                                :: módulos e perfis disponíveis
```

O `WinKit.cmd` pede elevação (UAC) quando precisa e roda com `-ExecutionPolicy Bypass` só para ele, sem mudar a política da máquina.

Relatórios ficam em `%ProgramData%\WinKit\runs\<RunId>\` (`report.html`, `report.json`, `log.txt`). Código de saída: 0 ok, 1 atenção, 2 crítico.

## O que o diagnóstico (Health) verifica
| Verificação | Como |
|---|---|
| Espaço em disco | `Win32_LogicalDisk` (atenção 80%, crítico 90%) |
| Saúde física dos discos | `Get-PhysicalDisk`, `Get-StorageReliabilityCounter` (erros de leitura, desgaste, temperatura) e previsão de falha do SMART |
| Erros de disco e desligamentos | Event Log por provedor e id (disk 7/51/153, Ntfs 55, Kernel-Power 41…), sem ler texto traduzido |
| Telas azuis | minidumps e evento 1001 com o código de parada |
| Reinício pendente, tempo ligado | chaves do Windows Update, CBS e PendingFileRenameOperations |
| Antivírus e firewall | `Get-MpComputerStatus`, Security Center, `Get-NetFirewallProfile` |
| Dispositivos sem driver | `Win32_PnPEntity` com HWID |
| Atualizações, memória, temperatura | histórico de hotfix, `Win32_OperatingSystem`, zonas térmicas ACPI |
| Integridade do Windows | `Repair-WindowsImage -CheckHealth` |

## Painel central
Para acompanhar várias máquinas num só lugar, o WinKit é integrado ao [Linux Control](https://github.com/webpeak-br/linux-control), painel open source que já monitora servidores Linux. O agente Windows (em desenvolvimento) envia o diagnóstico do WinKit ao painel, com alertas e botões para resolver.

## Contribuir
Veja [CONTRIBUTING.md](CONTRIBUTING.md): como criar um módulo e como adicionar um fabricante de drivers.

## Licença
[MIT](LICENSE).

---

## English

Open source kit to **prepare, optimize, secure and diagnose Windows**: Windows 10/11 and Windows Server 2016–2025, including **Server Core**.

- Safe by default (`-DryRun` everywhere, confirmation for risky steps), reversible (`winkit undo -RunId <id>`), no mandatory dependencies (Windows PowerShell 5.1 or PowerShell 7), no telemetry.
- Third-party tools are downloaded on demand from official sources and verified (SHA-256 and Authenticode) before running. WinKit never redistributes binaries.
- Status: Core and the **Health** module (diagnostics, DISM/SFC repair). Next: Updates, Apps, Drivers.

```powershell
irm https://github.com/webpeak-br/winkit/releases/latest/download/winkit.ps1 | iex   # menu, as administrator
```

Reports: `%ProgramData%\WinKit\runs\<RunId>\report.html`. Exit code: 0 ok, 1 warning, 2 critical. License: MIT.
