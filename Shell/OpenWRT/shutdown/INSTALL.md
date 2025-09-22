# Guia de Instalação - Monitor de Quedas de Energia v7

## Pré-requisitos

### Hardware Mínimo
- **Roteador OpenWRT** com pelo menos 4MB RAM livres
- **Espaço de armazenamento**: 512KB para logs e scripts

### Software Necessário
- **OpenWRT**: versão 19.07 ou superior
- **Busybox**: com suporte aos comandos essenciais
- **ntpclient**: recomendado para sincronização NTP

## Instalação Rápida

### 1. Baixar o Script
```bash
# Conecte-se ao roteador via SSH
ssh root@192.168.1.1

# Baixe o script (substitua pela URL do seu repositório)
wget https://raw.githubusercontent.com/SistemasVox/ProgramasPessoais/master/Shell/OpenWRT/shutdown/monitor_shutdown_v7.sh

# Ou copie via SCP
scp monitor_shutdown_v7.sh root@192.168.1.1:/root/
```

### 2. Configurar Permissões
```bash
# Torne o script executável
chmod +x monitor_shutdown_v7.sh

# Verifique se está funcionando
./monitor_shutdown_v7.sh --help
```

### 3. Configurar WhatsApp (Opcional)
```bash
# Se você tem um script de notificação WhatsApp
# Coloque-o no mesmo diretório do monitor
chmod +x send_whatsapp.sh

# Teste as notificações
./send_whatsapp.sh "Teste do monitor de energia"
```

### 4. Instalação de Dependências (se necessário)
```bash
# Atualizar lista de pacotes
opkg update

# Instalar ntpclient (se não estiver disponível)
opkg install ntpclient

# Instalar flock (se não estiver disponível)
opkg install flock

# Verificar comandos disponíveis
which date ping timeout flock ntpclient
```

## Configuração Inicial

### 1. Teste Manual
```bash
# Execute o script manualmente para teste
./monitor_shutdown_v7.sh

# Verifique os logs gerados
tail -f monitor_shutdown_v7.log
```

### 2. Configuração Personalizada
```bash
# O script cria automaticamente um arquivo de configuração
nano monitor_shutdown_v7.conf

# Exemplos de personalização:
HEARTBEAT_INTERVAL=10    # Reduzir frequência para economizar recursos
NTP_TIMEOUT=10          # Timeout mais rápido para NTP
INTERNET_CACHE_TTL=60   # Cache mais longo para economizar rede
```

### 3. Configuração de Inicialização Automática

#### Método 1: rc.local (Recomendado)
```bash
# Edite o arquivo de inicialização
nano /etc/rc.local

# Adicione antes da linha "exit 0":
/root/monitor_shutdown_v7.sh &

# Salve e reinicie para testar
reboot
```

#### Método 2: Init Script
```bash
# Crie um script de inicialização
cat > /etc/init.d/monitor_energia << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=15

start() {
    echo "Iniciando monitor de energia..."
    /root/monitor_shutdown_v7.sh &
}

stop() {
    echo "Parando monitor de energia..."
    killall monitor_shutdown_v7.sh
}
EOF

# Torne executável e ative
chmod +x /etc/init.d/monitor_energia
/etc/init.d/monitor_energia enable
```

#### Método 3: Cron (Alternativo)
```bash
# Configure cron para verificar se o script está rodando
crontab -e

# Adicione linha para verificar a cada 5 minutos:
*/5 * * * * pgrep -f monitor_shutdown_v7.sh || /root/monitor_shutdown_v7.sh &
```

## Verificação da Instalação

### 1. Verificar se está Rodando
```bash
# Verificar processo
ps | grep monitor_shutdown_v7

# Verificar logs
tail -20 monitor_shutdown_v7.log

# Verificar arquivos gerados
ls -la monitor_shutdown_v7.*
```

### 2. Teste de Funcionalidade
```bash
# Simular queda de energia (CUIDADO: só em ambiente de teste)
# Remova o arquivo heartbeat para simular reinício
rm .monitor_shutdown_v7_heartbeat

# Execute o script novamente e verifique se detecta "reinício"
./monitor_shutdown_v7.sh
```

### 3. Monitoramento
```bash
# Ver estatísticas em tempo real
watch -n 5 'tail -10 monitor_shutdown_v7.log'

# Ver dados CSV
cat monitor_shutdown_v7.csv

# Verificar uso de recursos
ps aux | grep monitor_shutdown_v7
```

## Configurações Avançadas

### 1. Ajuste de Performance
```bash
# Para roteadores com poucos recursos (< 32MB RAM):
echo "HEARTBEAT_INTERVAL=10" >> monitor_shutdown_v7.conf
echo "INTERNET_CACHE_TTL=120" >> monitor_shutdown_v7.conf
echo "MAX_LOG_ENTRIES=1000" >> monitor_shutdown_v7.conf

# Para roteadores com mais recursos:
echo "HEARTBEAT_INTERVAL=3" >> monitor_shutdown_v7.conf
echo "INTERNET_CACHE_TTL=30" >> monitor_shutdown_v7.conf
echo "MAX_LOG_ENTRIES=5000" >> monitor_shutdown_v7.conf
```

### 2. Personalização de Notificações
```bash
# Edite as mensagens no script se necessário
nano monitor_shutdown_v7.sh

# Procure por linhas como:
# send_notification "⚡ REINÍCIO DETECTADO..."
```

### 3. Configuração de Logs
```bash
# Rotação mais agressiva para economizar espaço
echo "MAX_LOG_SIZE=1048576" >> monitor_shutdown_v7.conf  # 1MB

# Manter mais histórico
echo "MAX_LOG_SIZE=10485760" >> monitor_shutdown_v7.conf  # 10MB
```

## Solução de Problemas

### Script não inicia
```bash
# Verificar dependências
./monitor_shutdown_v7.sh 2>&1 | head -20

# Verificar permissões
ls -la monitor_shutdown_v7.sh
chmod +x monitor_shutdown_v7.sh

# Verificar sintaxe
sh -n monitor_shutdown_v7.sh
```

### Consumo alto de recursos
```bash
# Reduzir frequência
echo "HEARTBEAT_INTERVAL=15" >> monitor_shutdown_v7.conf

# Aumentar cache
echo "INTERNET_CACHE_TTL=180" >> monitor_shutdown_v7.conf

# Limitar logs
echo "MAX_LOG_ENTRIES=500" >> monitor_shutdown_v7.conf
```

### Falsos positivos
```bash
# Aumentar margem de detecção (ajustar no script)
# Procure por: detection_threshold=$((HEARTBEAT_INTERVAL + 20))
# Mude para: detection_threshold=$((HEARTBEAT_INTERVAL + 60))
```

### Notificações não funcionam
```bash
# Verificar script WhatsApp
ls -la send_whatsapp.sh
chmod +x send_whatsapp.sh

# Teste manual
./send_whatsapp.sh "Teste"

# Verificar timeout
echo "NOTIFY_TIMEOUT=60" >> monitor_shutdown_v7.conf
```

## Manutenção

### 1. Limpeza Periódica
```bash
# Limpar logs antigos manualmente
find . -name "monitor_shutdown_v7_*.log.gz" -mtime +30 -delete

# Verificar espaço usado
du -sh monitor_shutdown_v7.*
```

### 2. Backup de Configuração
```bash
# Fazer backup das configurações
tar czf monitor_backup.tar.gz monitor_shutdown_v7.* .monitor_shutdown_v7_heartbeat

# Restaurar backup
tar xzf monitor_backup.tar.gz
```

### 3. Atualizações
```bash
# Parar script atual
killall monitor_shutdown_v7.sh

# Fazer backup
cp monitor_shutdown_v7.sh monitor_shutdown_v7.sh.bak

# Instalar nova versão
# ... baixar nova versão ...

# Testar nova versão
./monitor_shutdown_v7.sh

# Se OK, configurar inicialização novamente
```

## Dicas de Otimização

1. **Para roteadores muito antigos**: Aumente `HEARTBEAT_INTERVAL` para 15-30s
2. **Para redes instáveis**: Aumente `INTERNET_CACHE_TTL` para 300s
3. **Para economizar espaço**: Defina `MAX_LOG_ENTRIES=500`
4. **Para debugging**: Adicione `LOG_LEVEL=DEBUG` no arquivo .conf
5. **Para produção**: Use `LOG_LEVEL=INFO` para reduzir logs

## Suporte

Para problemas específicos:
1. Verifique os logs: `tail -50 monitor_shutdown_v7.log`
2. Execute verificação de saúde: `grep "Verificação de saúde" monitor_shutdown_v7.log`
3. Consulte a documentação completa: `README_v7.md`
4. Reporte problemas com logs completos