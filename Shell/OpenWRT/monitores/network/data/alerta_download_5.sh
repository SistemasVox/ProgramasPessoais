#!/bin/bash
#============================================================
#  Monitor de tráfego PÚBLICO via contadores iptables (v2)
#  - Usa chains intermediárias para filtrar IPs privados
#  - Janela de 5 medições (5×INTERVALOs)
#  - Alerta via WhatsApp
#  - Cooldown entre alertas
#============================================================

### CONFIGURAÇÕES ###
INTERFACE="eth0.2"           # <— ajuste para sua WAN
INTERVALO=3                  # segundos entre medições
MAX_RX=40                    # Mbps de referência para DOWNLOAD
MAX_TX=20                    # Mbps de referência para UPLOAD
LIM_PCT=90                   # % limite para disparar alerta
DEBUG=false                  # true para logs no stdout
DIR="$(cd "$(dirname "$0")" && pwd)"
LOCKFILE="/tmp/monitor_iptables_v2_${INTERFACE//./_}.lock" 
COOLDOWN=60                  # segundos entre alertas
last_alert_time=0

# Variáveis da janela de medições
count=0
sum_rx_mbps=0; sum_rx_pct=0; win_rx_str=""
sum_tx_mbps=0; sum_tx_pct=0; win_tx_str=""

# Nomes das chains do iptables
# Chains de contagem final
CHAIN_RX_COUNT="MON_RX_COUNT_${INTERFACE//./_}"
CHAIN_TX_COUNT="MON_TX_COUNT_${INTERFACE//./_}"
# Chains de verificação de IP público
CHAIN_RX_CHECK_PUBLIC="MON_RX_CHK_PUB_${INTERFACE//./_}"
CHAIN_TX_CHECK_PUBLIC="MON_TX_CHK_PUB_${INTERFACE//./_}"

# Lista de faixas de IP privado
PRIVATE_IP_RANGES=(
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "127.0.0.0/8"
    "169.254.0.0/16"
    # Adicione aqui outras faixas se necessário, como IPs de CGNAT se quiser excluí-los
    # "100.64.0.0/10" # Exemplo para CGNAT
)

#============================================================
# log_message
#============================================================
log_message() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    [ "$DEBUG" = true ] && echo "[$ts] $1"
}

#============================================================
# check_root (OpenWrt geralmente já é root)
#============================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_message "ALERTA: Este script idealmente é executado como root. Se houver erros com iptables, execute como root."
    fi
}

#============================================================
# check_iptables
#============================================================
check_iptables() {
    if ! command -v iptables &> /dev/null; then
        log_message "ERRO: Comando 'iptables' não encontrado. Por favor, instale o pacote iptables (opkg update && opkg install iptables)."
        echo "ERRO: Comando 'iptables' não encontrado. Por favor, instale o pacote iptables (opkg update && opkg install iptables)." >&2
        exit 1
    fi
    if ! command -v bc &> /dev/null; then
        log_message "ERRO: Comando 'bc' não encontrado. Por favor, instale (opkg update && opkg install bc)."
        echo "ERRO: Comando 'bc' não encontrado. Por favor, instale (opkg update && opkg install bc)." >&2
        exit 1
    fi
}

#============================================================
# setup_iptables
#============================================================
setup_iptables() {
    log_message "⚙️ Configurando regras do iptables para monitoramento em $INTERFACE..."

    # 1. Limpar regras e chains antigas (se existirem)
    log_message "🧹 Limpando regras e chains antigas do iptables..."
    iptables -D FORWARD -i "$INTERFACE" -j "$CHAIN_RX_CHECK_PUBLIC" 2>/dev/null || true
    iptables -D FORWARD -o "$INTERFACE" -j "$CHAIN_TX_CHECK_PUBLIC" 2>/dev/null || true
    
    for chain in "$CHAIN_RX_COUNT" "$CHAIN_TX_COUNT" "$CHAIN_RX_CHECK_PUBLIC" "$CHAIN_TX_CHECK_PUBLIC"; do
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    done

    # 2. Criar novas chains
    log_message "⛓️ Criando novas chains: $CHAIN_RX_CHECK_PUBLIC, $CHAIN_TX_CHECK_PUBLIC, $CHAIN_RX_COUNT, $CHAIN_TX_COUNT"
    for chain in "$CHAIN_RX_CHECK_PUBLIC" "$CHAIN_TX_CHECK_PUBLIC" "$CHAIN_RX_COUNT" "$CHAIN_TX_COUNT"; do
        iptables -N "$chain"
        if [ $? -ne 0 ]; then
            log_message "ERRO: Falha ao criar chain $chain."
            cleanup_iptables_silent # Tenta limpar o que foi criado parcialmente
            exit 1
        fi
    done

    # 3. Configurar chain de verificação RX (Download Público)
    log_message "🔎 Configurando chain de verificação RX: $CHAIN_RX_CHECK_PUBLIC"
    for ip_range in "${PRIVATE_IP_RANGES[@]}"; do
        iptables -A "$CHAIN_RX_CHECK_PUBLIC" -s "$ip_range" -j RETURN # Se for IP privado, não conta, retorna.
    done
    # Se passou por todas as verificações de IP privado, é tráfego público. Envia para contagem.
    iptables -A "$CHAIN_RX_CHECK_PUBLIC" -j "$CHAIN_RX_COUNT" 
    # Os bytes contados serão da regra acima que faz o JUMP para CHAIN_RX_COUNT.

    # 4. Configurar chain de verificação TX (Upload Público)
    log_message "🔎 Configurando chain de verificação TX: $CHAIN_TX_CHECK_PUBLIC"
    for ip_range in "${PRIVATE_IP_RANGES[@]}"; do
        iptables -A "$CHAIN_TX_CHECK_PUBLIC" -d "$ip_range" -j RETURN # Se for IP privado, não conta, retorna.
    done
    # Se passou por todas as verificações de IP privado, é tráfego público. Envia para contagem.
    iptables -A "$CHAIN_TX_CHECK_PUBLIC" -j "$CHAIN_TX_COUNT"
    # Os bytes contados serão da regra acima que faz o JUMP para CHAIN_TX_COUNT.

    # 5. Adicionar regras à FORWARD para direcionar tráfego para as chains de verificação
    # Estas devem ser inseridas de forma que capturem o tráfego desejado.
    # Inserir no topo para garantir que sejam processadas primeiro.
    log_message "➕ Adicionando regras principais à chain FORWARD."
    # A regra de TX é inserida primeiro com -I 1, depois a de RX com -I 1 (ficando no topo).
    iptables -I FORWARD 1 -o "$INTERFACE" -j "$CHAIN_TX_CHECK_PUBLIC"
     if [ $? -ne 0 ]; then log_message "ERRO: Falha ao adicionar regra TX à FORWARD."; cleanup_iptables_silent; exit 1; fi
    iptables -I FORWARD 1 -i "$INTERFACE" -j "$CHAIN_RX_CHECK_PUBLIC"
     if [ $? -ne 0 ]; then log_message "ERRO: Falha ao adicionar regra RX à FORWARD."; cleanup_iptables_silent; exit 1; fi

    log_message "👍 Regras do iptables configuradas com sucesso."
}

#============================================================
# cleanup_iptables
#============================================================
cleanup_iptables() {
    log_message "🧹 Removendo regras e chains do iptables..."
    iptables -D FORWARD -i "$INTERFACE" -j "$CHAIN_RX_CHECK_PUBLIC" 2>/dev/null || true
    iptables -D FORWARD -o "$INTERFACE" -j "$CHAIN_TX_CHECK_PUBLIC" 2>/dev/null || true
    
    for chain in "$CHAIN_RX_COUNT" "$CHAIN_TX_COUNT" "$CHAIN_RX_CHECK_PUBLIC" "$CHAIN_TX_CHECK_PUBLIC"; do
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    done
    log_message "🗑️ Regras e chains do iptables removidas."
}

#============================================================
# cleanup_iptables_silent
#============================================================
cleanup_iptables_silent() {
    iptables -D FORWARD -i "$INTERFACE" -j "$CHAIN_RX_CHECK_PUBLIC" &>/dev/null || true
    iptables -D FORWARD -o "$INTERFACE" -j "$CHAIN_TX_CHECK_PUBLIC" &>/dev/null || true
    for chain in "$CHAIN_RX_COUNT" "$CHAIN_TX_COUNT" "$CHAIN_RX_CHECK_PUBLIC" "$CHAIN_TX_CHECK_PUBLIC"; do
        iptables -F "$chain" &>/dev/null || true
        iptables -X "$chain" &>/dev/null || true
    done
}

#============================================================
# get_bytes_from_iptables
#============================================================
get_bytes_from_iptables() {
    local direction=$1
    local check_chain # A chain que contém a regra de salto para a chain de contagem
    local count_chain # A chain de contagem final, cujo nome identifica a regra

    if [ "$direction" == "rx" ]; then
        check_chain="$CHAIN_RX_CHECK_PUBLIC"
        count_chain="$CHAIN_RX_COUNT"
    elif [ "$direction" == "tx" ]; then
        check_chain="$CHAIN_TX_CHECK_PUBLIC"
        count_chain="$CHAIN_TX_COUNT"
    else
        log_message "ERRO INTERNO: Direção inválida '$direction' para get_bytes_from_iptables."
        return 1
    fi

    local bytes
    # Os bytes são contados na regra DENTRO da check_chain que faz o JUMP para a count_chain
    bytes=$(iptables -L "$check_chain" -v -n -x | grep " $count_chain " | awk '{print $2}' | head -n 1)

    if [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ ]]; then
        log_message "⚠️ Erro ao ler bytes do iptables para $direction (check: $check_chain, target: $count_chain)."
        log_message "DEBUG: Comando: iptables -L \"$check_chain\" -v -n -x"
        [ "$DEBUG" = true ] && iptables -L "$check_chain" -v -n -x
        return 1
    fi
    echo "$bytes"
}

#============================================================
# calc_rate
#============================================================
calc_rate() {
    local dt=$1 dir=$2 b0 b1 delta

    b0=$(get_bytes_from_iptables "$dir")
    if [ $? -ne 0 ]; then log_message "Falha contagem inicial bytes $dir."; return 1; fi
    
    sleep "$dt"
    
    b1=$(get_bytes_from_iptables "$dir")
    if [ $? -ne 0 ]; then log_message "Falha contagem final bytes $dir."; return 1; fi
    
    if (( $(echo "$b1 < $b0" | bc -l) )); then
        log_message "AVISO: Contagem bytes $dir diminuiu ($b0->$b1). Reset/wrap-around? Ignorando."
        return 1
    fi

    delta=$(( (b1 - b0) * 8 ))
    echo "scale=2; $delta/($dt*1000000)" | bc
}

#============================================================
# send_alert
#============================================================
send_alert() {
    local msg="$1"
    log_message "🚨 Enviando alerta via WhatsApp..."
    if [ -x "$DIR/send_whatsapp.sh" ]; then
        "$DIR/send_whatsapp.sh" "$msg"
        log_message "✅ Alerta enviado."
    else
        log_message "ERRO: Script 'send_whatsapp.sh' não encontrado/executável em $DIR."
    fi
}

#============================================================
# Início do Script
#============================================================
check_root
check_iptables # Também verifica 'bc'
setup_iptables

exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log_message "🔒 Já em execução (lockfile $LOCKFILE ocupado)."
    exit 1
fi
log_message "🔑 Lock adquirido: $LOCKFILE"

trap 'log_message "🛑 Encerrando..."; cleanup_iptables; rm -f "$LOCKFILE"; log_message "🏁 Monitoramento finalizado."' INT TERM EXIT

log_message "✅ Iniciando monitoramento PÚBLICO em $INTERFACE (janela 5×${INTERVALO}s)..."

while true; do
    current_rx_rate=$(calc_rate $INTERVALO rx)
    if [ $? -ne 0 ]; then
        log_message "⚠️ Erro medindo RX público. Pulando ciclo."
        sleep $INTERVALO 
        count=0; sum_rx_mbps=0; sum_rx_pct=0; win_rx_str=""; sum_tx_mbps=0; sum_tx_pct=0; win_tx_str=""
        continue
    fi

    current_tx_rate=$(calc_rate $INTERVALO tx)
    if [ $? -ne 0 ]; then
        log_message "⚠️ Erro medindo TX público. Pulando ciclo."
        sleep $INTERVALO
        count=0; sum_rx_mbps=0; sum_rx_pct=0; win_rx_str=""; sum_tx_mbps=0; sum_tx_pct=0; win_tx_str=""
        continue
    fi

    pct_rx=$(echo "scale=2; ($current_rx_rate/$MAX_RX)*100" | bc -l)
    pct_tx=$(echo "scale=2; ($current_tx_rate/$MAX_TX)*100" | bc -l)

    log_message "Medição Pública: DL=$(printf '%.2f' "$current_rx_rate")Mbps ($(printf '%.0f' "$pct_rx")%), UL=$(printf '%.2f' "$current_tx_rate")Mbps ($(printf '%.0f' "$pct_tx")%)"

    count=$((count+1))
    sum_rx_mbps=$(echo "$sum_rx_mbps + $current_rx_rate" | bc)
    sum_rx_pct=$(echo "$sum_rx_pct + $pct_rx" | bc)
    win_rx_str="${win_rx_str} $(printf '%.2f' "$current_rx_rate")"
    
    sum_tx_mbps=$(echo "$sum_tx_mbps + $current_tx_rate" | bc)
    sum_tx_pct=$(echo "$sum_tx_pct + $pct_tx" | bc)
    win_tx_str="${win_tx_str} $(printf '%.2f' "$current_tx_rate")"

    if [ "$count" -eq 5 ]; then
        avg_rx=$(echo "scale=2; $sum_rx_mbps/5" | bc)
        avg_rx_pct=$(echo "scale=2; $sum_rx_pct/5" | bc)
        avg_tx=$(echo "scale=2; $sum_tx_mbps/5" | bc)
        avg_tx_pct=$(echo "scale=2; $sum_tx_pct/5" | bc)

        log_message "Média Janela: RX=$(printf '%.2f' "$avg_rx")Mbps ($(printf '%.0f' "$avg_rx_pct")%), TX=$(printf '%.2f' "$avg_tx")Mbps ($(printf '%.0f' "$avg_tx_pct")%)"

        current_time=$(date +%s)
        alerta_disparado_nesta_janela=0

        if [ $((current_time - last_alert_time)) -ge $COOLDOWN ]; then
            if [ "$(echo "$avg_rx_pct >= $LIM_PCT" | bc -l)" -eq 1 ]; then
                msg="🚨 ALERTA DE DOWNLOAD 🚨
📅 Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')
🌐 Interface: ${INTERFACE}
⏱ Média (Últimos $(($INTERVALO * 5))s)
📥 DL (Público): $(printf '%.2f' "$avg_rx") Mbps ($(printf '%.0f' "$avg_rx_pct")% de ${MAX_RX} Mbps)
🔢 Medições:${win_rx_str}"
                send_alert "$msg"
                alerta_disparado_nesta_janela=1
            fi

            if [ "$(echo "$avg_tx_pct >= $LIM_PCT" | bc -l)" -eq 1 ]; then
                msg="🚨 ALERTA DE UPLOAD 🚨
📅 Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')
🌐 Interface: ${INTERFACE}
⏱ Média (Últimos $(($INTERVALO * 5))s)
📤 UL (Público): $(printf '%.2f' "$avg_tx") Mbps ($(printf '%.0f' "$avg_tx_pct")% de ${MAX_TX} Mbps)
🔢 Medições:${win_tx_str}"
                send_alert "$msg"
                alerta_disparado_nesta_janela=1
            fi

            if [ "$alerta_disparado_nesta_janela" -eq 1 ]; then
                last_alert_time=$current_time
            fi
        else
            log_message "❄️ Cooldown ativo. Próximo alerta em $((last_alert_time + COOLDOWN - current_time))s."
        fi

        count=0; sum_rx_mbps=0; sum_rx_pct=0; win_rx_str=""; sum_tx_mbps=0; sum_tx_pct=0; win_tx_str=""
    fi
done