#!/bin/bash

# ============================================================================
# Script de Instalação - Monitor de Quedas de Energia v2.0
# ============================================================================
# Uso: sudo bash install_monitor.sh
# ============================================================================

set -e

SCRIPT_DIR="/opt/power-monitor"
SCRIPT_NAME="monitor_shutdown"
MONITOR_SCRIPT="$SCRIPT_DIR/${SCRIPT_NAME}.sh"
SYSTEMD_SERVICE="/etc/systemd/system/${SCRIPT_NAME}.service"
SYSTEMD_TIMER="/etc/systemd/system/${SCRIPT_NAME}-watchdog.service"

# Verificar se é root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Este script deve ser executado como root (use sudo)"
    exit 1
fi

echo "📦 Instalando Monitor de Quedas de Energia v2.0..."

# Criar diretório
mkdir -p "$SCRIPT_DIR"
echo "✅ Diretório criado: $SCRIPT_DIR"

# Copiar script (você precisa ter ele no diretório atual)
if [ -f "monitor_shutdown_v2_prod.sh" ]; then
    cp "monitor_shutdown_v2_prod.sh" "$MONITOR_SCRIPT"
    chmod +x "$MONITOR_SCRIPT"
    echo "✅ Script de monitor instalado"
else
    echo "⚠️  Aviso: monitor_shutdown_v2_prod.sh não encontrado no diretório atual"
    echo "   Você pode copiar manualmente para: $MONITOR_SCRIPT"
fi

# Criar serviço systemd
cat > "$SYSTEMD_SERVICE" << 'EOF'
[Unit]
Description=Power Outage Monitor with Clock Fallback
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/power-monitor
ExecStart=/opt/power-monitor/monitor_shutdown.sh
Restart=always
RestartSec=5
StandardOutput=append:/opt/power-monitor/monitor_shutdown.log
StandardError=append:/opt/power-monitor/monitor_shutdown.log
TimeoutStopSec=10

# Proteção contra travamentos
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

echo "✅ Serviço systemd criado: $SYSTEMD_SERVICE"

# Criar script de monitoramento de watchdog (opcional)
cat > "$SCRIPT_DIR/check-monitor-health.sh" << 'EOF'
#!/bin/bash

# ============================================================================
# Script de Verificação de Saúde do Monitor
# Uso: ./check-monitor-health.sh
# ============================================================================

MONITOR_DIR="/opt/power-monitor"
LOG_FILE="$MONITOR_DIR/monitor_shutdown.log"
WATCHDOG_MARKER="/tmp/monitor_shutdown.watchdog"
HEARTBEAT_FILE="$MONITOR_DIR/.monitor_shutdown_heartbeat"
TIMEOUT=300

check_status() {
    echo "🔍 Verificando saúde do monitor..."
    echo ""
    
    # Verificar se está rodando
    if pgrep -f "monitor_shutdown.sh" > /dev/null; then
        echo "✅ Monitor está rodando"
    else
        echo "❌ Monitor NÃO está rodando"
        return 1
    fi
    
    # Verificar heartbeat
    if [ -f "$HEARTBEAT_FILE" ]; then
        local last_hb=$(cat "$HEARTBEAT_FILE")
        local now=$(date +%s)
        local age=$((now - last_hb))
        
        echo "📊 Último heartbeat: ${age}s atrás"
        
        if [ "$age" -gt "$TIMEOUT" ]; then
            echo "⚠️  ALERTA: Monitor sem heartbeat há ${age}s (timeout: ${TIMEOUT}s)"
            return 1
        fi
    fi
    
    # Verificar logs recentes
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "📋 Últimas 10 linhas do log:"
        tail -10 "$LOG_FILE"
    fi
    
    echo ""
    echo "✅ Monitor em bom estado"
    return 0
}

# Executar verificação
check_status
exit $?
EOF

chmod +x "$SCRIPT_DIR/check-monitor-health.sh"
echo "✅ Script de verificação de saúde criado"

# Recarregar systemd
systemctl daemon-reload
echo "✅ Systemd recarregado"

# Informações finais
echo ""
echo "================================================================"
echo "✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "================================================================"
echo ""
echo "📍 Localização do script: $MONITOR_SCRIPT"
echo "📍 Localização dos logs: $SCRIPT_DIR/monitor_shutdown.log"
echo "📍 Localização do CSV: $SCRIPT_DIR/monitor_shutdown.csv"
echo ""
echo "🚀 PRÓXIMOS PASSOS:"
echo ""
echo "1️⃣  Inicie o serviço:"
echo "    sudo systemctl start $SCRIPT_NAME"
echo ""
echo "2️⃣  Habilite para iniciar ao boot:"
echo "    sudo systemctl enable $SCRIPT_NAME"
echo ""
echo "3️⃣  Verificar status:"
echo "    sudo systemctl status $SCRIPT_NAME"
echo ""
echo "4️⃣  Ver logs em tempo real:"
echo "    sudo journalctl -u $SCRIPT_NAME -f"
echo ""
echo "5️⃣  Verificar saúde do monitor:"
echo "    $SCRIPT_DIR/check-monitor-health.sh"
echo ""
echo "6️⃣  (OPCIONAL) Se você tem send_whatsapp.sh, coloque em:"
echo "    $SCRIPT_DIR/send_whatsapp.sh"
echo ""
echo "================================================================"
echo "📝 CONFIGURAÇÃO:"
echo "================================================================"
echo "Intervalo de heartbeat: 5 segundos"
echo "Timeout de watchdog: 300 segundos (5 minutos)"
echo "Margem de fallback: 180 segundos (3 minutos)"
echo "NTP Server: a.st1.ntp.br"
echo ""
echo "Para ajustar esses valores, edite o script:"
echo "  nano $MONITOR_SCRIPT"
echo ""
echo "================================================================"
