# Verifica e repara arquivos corrompidos do sistema operacional
Write-Host "Executando verificação do System File Checker (SFC)..."
sfc /scannow

# Verifica se há corrupção na imagem do Windows (verificação rápida)
Write-Host "Verificando integridade da imagem do Windows..."
DISM.exe /online /cleanup-image /checkhealth

# Faz uma verificação mais detalhada na imagem do Windows
Write-Host "Executando verificação avançada da imagem do Windows..."
DISM.exe /online /cleanup-image /scanhealth

# Tenta corrigir automaticamente arquivos corrompidos no Windows
Write-Host "Tentando reparar a imagem do Windows..."
DISM.exe /online /cleanup-image /restorehealth

# Corrige problemas de inicialização do Windows
Write-Host "Corrigindo MBR (Master Boot Record)..."
bootrec /fixmbr

Write-Host "Corrigindo setor de inicialização..."
bootrec /fixboot

Write-Host "Verificando se há instalações do Windows ausentes no boot..."
bootrec /scanos

Write-Host "Reconstruindo o BCD (Boot Configuration Data)..."
bootrec /rebuildbcd

# Verifica e repara setores defeituosos no disco rígido
Write-Host "Executando verificação do disco rígido..."
chkdsk /f /r

# Reinicia componentes do Windows Update
Write-Host "Parando serviços do Windows Update..."
net stop wuauserv
net stop cryptSvc
net stop bits
net stop msiserver

Write-Host "Renomeando pastas do Windows Update..."
ren C:\Windows\SoftwareDistribution SoftwareDistribution.old
ren C:\Windows\System32\catroot2 catroot2.old

Write-Host "Reiniciando serviços do Windows Update..."
net start wuauserv
net start cryptSvc
net start bits
net start msiserver

# Redefine as configurações de rede para corrigir problemas de conexão
Write-Host "Redefinindo configurações de rede..."
netsh winsock reset
netsh int ip reset
ipconfig /release
ipconfig /renew
ipconfig /flushdns

Write-Host "Processo concluído! Reinicie o computador para aplicar as correções."
