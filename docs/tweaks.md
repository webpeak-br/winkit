# Ajustes aplicados pelo WinKit

Cada alteração que o WinKit faz no sistema é documentada aqui: o que faz, por quê, risco, como reverter e a referência oficial. Alterações sem entrada neste arquivo não são aceitas.

## Health (Invoke)

### Reparo da imagem do Windows
- **O que faz:** `DISM /Online /Cleanup-Image /RestoreHealth` e depois `sfc /scannow`.
- **Por quê:** corrige arquivos do sistema corrompidos (causa comum de erros de atualização e travamentos).
- **Risco:** baixo. Não altera configurações; substitui arquivos do sistema pelas versões íntegras.
- **Como reverter:** não se aplica (restaura o estado original dos arquivos). O ponto de restauração criado antes cobre o Desktop.
- **Referência:** [Repair a Windows Image (Microsoft Learn)](https://learn.microsoft.com/windows-hardware/manufacture/desktop/repair-a-windows-image)
