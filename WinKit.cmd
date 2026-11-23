@echo off
rem WinKit: atalho que roda o PowerShell sem depender da política de execução da máquina
rem (e evita o problema do navegador salvar .ps1 como .ps1.txt).
setlocal
where pwsh >nul 2>nul && (set "PS=pwsh") || (set "PS=powershell")
%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\winkit.ps1" %*
exit /b %ERRORLEVEL%
