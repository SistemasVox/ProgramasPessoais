#!/bin/bash

# ========================================
# Monitor da Lua - Versão Corrigida com API Confiável e Tradução PT-BR
# ========================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PREFIX="$(basename "${BASH_SOURCE[0]%.*}")"
LOG_FILE="$DIR/${SCRIPT_PREFIX}.log"

# Coordenadas de Uberlândia-MG
LATITUDE="-18.9113"
LONGITUDE="-48.2622"

# API pública e gratuita para dados astronômicos (wttr.in)
API_URL="http://v2.wttr.in/Uberlandia?format=j1"

# ========================================
# Funções Básicas
# ========================================

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

send_notification() {
    local script_name message
    script_name=$(basename "$0")
    message=$(printf "[%s]\n%s" "$script_name" "$1")
    
    log_message "Enviando notificação via WhatsApp..."
    # Descomente as linhas abaixo se os scripts de envio existirem
    "$DIR/send_whatsapp.sh" "$message" >/dev/null 2>&1
    "$DIR/send_whatsapp_2.sh" "$message" >/dev/null 2>&1
    log_message "Notificação enviada."
}

check_internet_connection() {
    ping -c 1 -W 2 "1.1.1.1" >/dev/null 2>&1
}

# ========================================
# Busca e Extração de Dados via API
# ========================================

extract_moon_info() {
    log_message "🌙 Buscando dados lunares via API (wttr.in)..."
    
    if ! command -v jq &> /dev/null; then
        log_message "❌ ERRO: A ferramenta 'jq' não está instalada. Por favor, instale-a."
        return 1
    fi

    local max_retries=3
    local retry_delay=5
    local json_response=""

    for ((i=1; i<=max_retries; i++)); do
        json_response=$(curl -s -m 15 "$API_URL")
        if [ -n "$json_response" ] && echo "$json_response" | jq -e '.weather[0].astronomy[0]' >/dev/null; then
            break
        else
            log_message "⚠️ Tentativa $i falhou. Aguardando $retry_delay segundos..."
            sleep $retry_delay
        fi
    done

    if [ -z "$json_response" ] || ! echo "$json_response" | jq -e '.weather[0].astronomy[0]' >/dev/null; then
        log_message "❌ ERRO: Falha após $max_retries tentativas. Resposta da API: $json_response"
        return 1
    fi

    local astronomy_data=$(echo "$json_response" | jq '.weather[0].astronomy[0]')

    MOON_PHASE=$(echo "$astronomy_data" | jq -r '.moon_phase // "N/D"')
    MOON_ILLUMINATION=$(echo "$astronomy_data" | jq -r '.moon_illumination // "N/D"')
    MOONRISE=$(echo "$astronomy_data" | jq -r '.moonrise // "N/D"')
    MOONSET=$(echo "$astronomy_data" | jq -r '.moonset // "N/D"')
    
    case "$MOON_PHASE" in
        "New Moon")          MOON_PHASE="🌑 Lua Nova" ;;
        "Waxing Crescent")   MOON_PHASE="🌒 Crescente Côncava" ;;
        "First Quarter")     MOON_PHASE="🌓 Quarto Crescente" ;;
        "Waxing Gibbous")    MOON_PHASE="🌔 Gibosa Crescente" ;;
        "Full Moon")         MOON_PHASE="🌕 Lua Cheia" ;;
        "Waning Gibbous")    MOON_PHASE="🌖 Gibosa Minguante" ;;
        "Last Quarter")      MOON_PHASE="🌗 Quarto Minguante" ;;
        "Waning Crescent")   MOON_PHASE="🌘 Minguante Côncava" ;;
        *)                   MOON_PHASE="🌙 $MOON_PHASE" ;; # Fallback para fases não mapeadas
    esac

    # Formatação de data e hora para Português do Brasil
    export LC_TIME=pt_BR.UTF-8
    CURRENT_DATE=$(date '+%d de %B de %Y')
    CURRENT_TIME=$(date '+%H:%M:%S')

    DATA_SOURCE="🌐 API: v2.wttr.in"

    log_message "✅ Dados da lua processados com sucesso!"
    return 0
}

# ========================================
# Formatação Final
# ========================================

format_and_display() {
    local message_body
    
    message_body=$(cat << EOF
🌙 Informações Lunares - Uberlândia
╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋
📅 Data: ${CURRENT_DATE}
🕐 Hora atual: ${CURRENT_TIME}

🌙 FASE DA LUA:
• Fase atual: ${MOON_PHASE:-N/D}
• Iluminação: ${MOON_ILLUMINATION:-N/D}%

🌅 HORÁRIOS DA LUA (horário local):
• Nascer da lua: ${MOONRISE:-N/D}
• Pôr da lua: ${MOONSET:-N/D}

📊 INFORMAÇÕES ADICIONAIS:
• Coordenadas: ${LATITUDE}, ${LONGITUDE}

─────────────────────────────────────────────────
📡 ${DATA_SOURCE}
✅ Dados obtidos com sucesso!
EOF
)
    
    echo ""
    echo "$message_body"
    
    # Descomente a linha abaixo para enviar notificações
    send_notification "$message_body"
}

# ========================================
# Limpeza
# ========================================

cleanup() {
    return 0
}

# ========================================
# MAIN - Execução Principal
# ========================================

trap cleanup EXIT INT TERM

log_message "=== Monitor da Lua Iniciado ==="

log_message "Verificando conexão com a internet..."
if ! check_internet_connection; then
    log_message "❌ ERRO: Sem conexão com a internet. Não é possível obter os dados."
    send_notification "⚠️ ERRO: Falha ao obter dados da lua por falta de internet."
    exit 1
fi
log_message "✅ Conexão estabelecida."

if extract_moon_info; then
    format_and_display
    log_message "🎉 Sucesso total!"
else
    log_message "❌ Erro final no processamento."
    send_notification "⚠️ ERRO: Falha grave ao processar dados da lua."
    exit 1
fi

log_message "=== Monitor da Lua Finalizado ==="