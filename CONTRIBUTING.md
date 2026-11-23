# Contribuindo com o WinKit

Obrigado por ajudar. Antes de abrir um PR:

1. Rode os testes: `Invoke-Pester tests` (Pester 5) e `Invoke-ScriptAnalyzer -Path src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` sem avisos.
2. Arquivos `.ps1`, `.psm1` e `.psd1` em **UTF-8 com BOM** (o PowerShell 5.1 lê acentos errado sem ele). O CI confere.
3. Nunca faça parse do texto de saída de programas do Windows (`pnputil`, `dism`, `sfc`…): ele muda com o idioma. Decida pelo código de saída ou por CIM/registro.
4. Nunca inclua binários de terceiros no repositório.

## Como criar um módulo

Um módulo é uma pasta em `src/WinKit/Modules/<Id>/` com dois arquivos.

### `manifest.json`
```json
{
  "id": "MeuModulo",
  "name": "Nome que aparece no relatório",
  "description": "O que ele faz, em uma frase",
  "version": "0.1.0",
  "platforms": ["Desktop", "Server", "ServerCore"],
  "minBuild": 14393,
  "risk": "low",
  "requiresReboot": false,
  "dependsOn": [],
  "tools": [],
  "functions": { "test": "Test-WinKitMeuModulo", "invoke": "Invoke-WinKitMeuModulo", "undo": null, "report": null },
  "parameters": {
    "Exemplo": { "type": "int", "default": 10, "description": "Para que serve" }
  }
}
```
- `id` em PascalCase, igual ao nome da pasta.
- `risk`: `none` (só lê), `low`, `medium`, `high`. Médio e alto pedem confirmação e só entram no perfil Avançado.
- `functions.test` é obrigatório: **todo módulo começa pelo diagnóstico**.
- Cada função recebe só os `parameters` que declara.

### `<Id>.psm1`
- `Test-WinKit<Id>` só lê e devolve resultados com `New-WinKitResult -Check -Status ok|info|warn|crit -Message -Code -Fix`.
  O `Code` é estável (ex.: `disk_full`) e é o que o painel usa para oferecer o botão "Resolver".
- `Invoke-WinKit<Id>` aplica. **Nunca** altere registro ou serviço direto: use `Set-WinKitRegistryValue` e `Set-WinKitServiceStartup`, que guardam o estado anterior, respeitam o `-DryRun` e alimentam o undo. Para outras alterações, registre com `Add-WinKitCustomChange` e implemente `Undo-WinKit<Id>`.
- Programas externos: `Invoke-WinKitProcess` (códigos de saída, 3010 = reinício). Downloads: `Get-WinKitDownload -Sha256 -ExpectedSigner`.
- Documente cada ajuste em `docs/tweaks.md` (o que faz, por quê, risco, como reverter, referência oficial).
- Escreva testes em `tests/<Id>.Tests.ps1` com mocks de CIM e registro.

## Como adicionar um fabricante de drivers
O módulo Drivers (em desenvolvimento) terá providers em `src/WinKit/Modules/Drivers/Providers/<Fabricante>.ps1`, cada um com:
- `Test-<Fabricante>Match`: reconhece a máquina por `Win32_ComputerSystem`/`Win32_BaseBoard`;
- `Get-<Fabricante>DriverList`: devolve os pacotes oficiais (URL, versão, hash quando o fabricante publica, classe de driver e HWIDs que resolve);
- a ordem de instalação é decidida pelo Core (chipset primeiro, rede por último).

Contribuições ao `HwidMap.json` (HWID → pacote que resolve) são muito bem-vindas: inclua a saída de `Get-PnpDevice | ? Status -eq 'Error' | fl FriendlyName, InstanceId, HardwareID` e o modelo da placa.
