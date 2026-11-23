# Changelog

## 0.3.0
- Módulo e tela Drivers: lista os drivers instalados e os dispositivos com problema (com o código de hardware), procura no Windows Update os drivers para esta máquina e mostra quais resolvem cada dispositivo, instala os marcados com backup antes (DISM export + restore.ps1). Para o que o Windows Update não tem: links para o Microsoft Update Catalog, a página do fabricante (Gigabyte, ASUS, MSI, ASRock, Dell, Lenovo, HP…) e os detectores da Intel, AMD e NVIDIA.
- Antivírus de terceiros (Bitdefender e outros) reconhecidos pela Central de Segurança.

## 0.2.0
- Interface gráfica (WPF) no visual do Linux Control: Visão geral com cards, Diagnóstico com semáforo, Aplicativos, Atualizações, Manutenção e Histórico com desfazer. Tarefas rodam em segundo plano, com log ao vivo. No Server Core continua o menu de texto.
- Módulo Apps: 45 programas populares pelo winget (fontes oficiais), mostrando os já instalados; atualizar todos; desfazer desinstala o que o WinKit instalou.
- Módulo Updates: Windows Update pela API COM (segurança reconhecida por categoria, sem texto traduzido), instala as marcadas e avisa quando precisa reiniciar.

## 0.1.0 (em desenvolvimento)
- Core: detecção de ambiente (Desktop, Server, Server Core), log, execuções com RunId, diário de alterações com undo, DryRun, execução de processos por código de saída, downloads com SHA-256 e assinatura Authenticode, plugins com manifest.json, perfis com herança, relatório em console, JSON e HTML.
- Módulo Health (diagnóstico): espaço e saúde física dos discos, erros de disco e desligamentos no Event Log, telas azuis, reinício pendente, antivírus, firewall, dispositivos sem driver, atualizações, memória, temperatura e integridade da imagem; reparo com DISM e SFC.
- Perfis: Diagnostico e Reparo-Sistema.
