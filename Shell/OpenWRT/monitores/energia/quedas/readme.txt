# 1. Download dos arquivos
# 2. Ir para o diretório
cd /tmp

# 3. Instalar (5 minutos)
sudo bash install_monitor.sh

# 4. Iniciar
sudo systemctl start monitor_shutdown
sudo systemctl enable monitor_shutdown

# 5. Verificar
sudo systemctl status monitor_shutdown