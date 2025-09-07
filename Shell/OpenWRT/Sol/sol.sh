#!/bin/bash

# ========================================
# Monitor do Sol NOVO - APIs JSON (Versão Corrigida)
# ========================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PREFIX="$(basename "${BASH_SOURCE[0]%.*}")"
LOG_FILE="$DIR/${SCRIPT_PREFIX}.log"

# Coordenadas de Uberlândia-MG
LATITUDE="-18.9113"
LONGITUDE="-48.2622"

# APIs JSON
API_URLS=(
    "https://api.sunrise-sunset.org/json?lat=${LATITUDE}&lng=${LONGITUDE}&formatted=0"
    "http://api.sunrise-sunset.org/json?lat=${LATITUDE}&lng=${LONGITUDE}&formatted=0"
)

TEMP_DATA="$DIR/.sun_api_data_novo"

# ========================================
# Funções Básicas
# ========================================

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$1"
}

send_notification() {
    local script_name message
    script_name=$(basename "$0")
    message=$(printf "[%s]\n%s" "$script_name" "$1")
    
    log_message "Enviando notificação via WhatsApp..."
    "$DIR/send_whatsapp.sh" "$message" >/dev/null 2>&1
    "$DIR/send_whatsapp_2.sh" "$message" >/dev/null 2>&1
    log_message "Notificação enviada."
}

check_internet_connection() {
    ping -c 1 -W 2 "1.1.1.1" >/dev/null 2>&1
}

# ========================================
# Função de Conversão UTC para Local (CORRIGIDA)
# ========================================

convert_utc_to_local() {
    local utc_time="$1"
    
    if [ -z "$utc_time" ]; then
        echo "N/D"
        return
    fi
    
    # Extrai componentes da data/hora UTC: 2025-09-04T09:16:52+00:00
    local time_part=$(echo "$utc_time" | sed 's/.*T//; s/+.*//; s/Z.*//')
    
    # Separa horas, minutos, segundos
    local hour_str=$(echo "$time_part" | cut -d':' -f1)
    local minute_str=$(echo "$time_part" | cut -d':' -f2) 
    local second_str=$(echo "$time_part" | cut -d':' -f3)
    
    # Remove zeros à esquerda para evitar interpretação octal
    local hour=$((10#$hour_str))
    local minute=$((10#$minute_str))
    local second=$((10#$second_str))
    
    # Converte para horário de Brasília (UTC-3)
    local local_hour=$((hour - 3))
    
    # Ajusta overflow/underflow
    if [ $local_hour -lt 0 ]; then
        local_hour=$((local_hour + 24))
    elif [ $local_hour -ge 24 ]; then
        local_hour=$((local_hour - 24))
    fi
    
    # Formatar para AM/PM
    if [ $local_hour -eq 0 ]; then
        printf "12:%02d:%02d AM" $minute $second
    elif [ $local_hour -lt 12 ]; then
        printf "%d:%02d:%02d AM" $local_hour $minute $second
    elif [ $local_hour -eq 12 ]; then
        printf "12:%02d:%02d PM" $minute $second
    else
        printf "%d:%02d:%02d PM" $((local_hour - 12)) $minute $second
    fi
}

# ========================================
# Busca de Dados via API
# ========================================

fetch_sun_data_api() {
    log_message "🌐 Buscando dados via API JSON..."
    
    local api_count=1
    for api_url in "${API_URLS[@]}"; do
        log_message "Testando API $api_count: $api_url"
        
        local json_response
        json_response=$(curl -s -m 10 \
                             -H "Accept: application/json" \
                             -H "User-Agent: SunMonitor/1.0" \
                             "$api_url" 2>/dev/null)
        
        # Verifica se o JSON é válido e contém dados esperados
        if [ -n "$json_response" ] && echo "$json_response" | grep -q '"sunrise"' && echo "$json_response" | grep -q '"sunset"'; then
            # Salva o JSON
            echo "$json_response" > "$TEMP_DATA"
            log_message "✅ API $api_count funcionou!"
            return 0
        fi
        
        log_message "❌ API $api_count falhou"
        api_count=$((api_count + 1))
        sleep 2
    done
    
    log_message "❌ Todas as APIs falharam"
    return 1
}

# ========================================
# Extração de Dados JSON
# ========================================

extract_sun_info_json() {
    if [ ! -f "$TEMP_DATA" ]; then
        log_message "ERRO: Arquivo de dados não encontrado"
        return 1
    fi
    
    local json_data=$(cat "$TEMP_DATA")
    
    log_message "📊 Processando dados JSON..."
    
    # Extração dos timestamps UTC
    local sunrise_utc=$(echo "$json_data" | grep -o '"sunrise":"[^"]*"' | cut -d'"' -f4)
    local sunset_utc=$(echo "$json_data" | grep -o '"sunset":"[^"]*"' | cut -d'"' -f4)
    local solar_noon_utc=$(echo "$json_data" | grep -o '"solar_noon":"[^"]*"' | cut -d'"' -f4)
    local civil_begin_utc=$(echo "$json_data" | grep -o '"civil_twilight_begin":"[^"]*"' | cut -d'"' -f4)
    local civil_end_utc=$(echo "$json_data" | grep -o '"civil_twilight_end":"[^"]*"' | cut -d'"' -f4)
    local day_length_seconds=$(echo "$json_data" | grep -o '"day_length":[0-9]*' | cut -d':' -f2)
    
    # Debug: mostra o que foi extraído
    log_message "Debug - Sunrise UTC: $sunrise_utc"
    log_message "Debug - Sunset UTC: $sunset_utc"
    
    # Conversões para horário local
    SUNRISE=$(convert_utc_to_local "$sunrise_utc")
    SUNSET=$(convert_utc_to_local "$sunset_utc")
    SOLAR_NOON=$(convert_utc_to_local "$solar_noon_utc")
    FIRST_LIGHT=$(convert_utc_to_local "$civil_begin_utc")
    LAST_LIGHT=$(convert_utc_to_local "$civil_end_utc")
    
    # Duração do dia
    if [ -n "$day_length_seconds" ] && [ "$day_length_seconds" -gt 0 ]; then
        local hours=$((day_length_seconds / 3600))
        local minutes=$(((day_length_seconds % 3600) / 60))
        DAY_LENGTH="${hours}h ${minutes}min"
    else
        DAY_LENGTH="N/D"
    fi
    
    # Dados adicionais
    CURRENT_DATE=$(date '+%B %d, %Y')
    CURRENT_TIME=$(date '+%I:%M:%S %p')
    DATA_SOURCE="🌐 API: sunrise-sunset.org"
    
    log_message "✅ Dados processados com sucesso"
    return 0
}

# ========================================
# Formatação Final
# ========================================

format_and_display() {
    local message_body
    
    message_body=$(cat << EOF
☀️ Informações Solares - Uberlândia
═══════════════════════════════════
📅 Data: ${CURRENT_DATE}
🕐 Hora atual: ${CURRENT_TIME}

🌅 HORÁRIOS DO SOL:
• Primeira luz: ${FIRST_LIGHT}
• Nascer do sol: ${SUNRISE}
• Meio-dia solar: ${SOLAR_NOON}
• Pôr do sol: ${SUNSET}
• Última luz: ${LAST_LIGHT}

⏱️ DURAÇÃO:
• Duração do dia: ${DAY_LENGTH}

───────────────────────────────────
📊 ${DATA_SOURCE}
✅ Dados obtidos com sucesso!
EOF
)
    
    echo ""
    echo "$message_body"
    
    send_notification "$message_body"
}

# ========================================
# Limpeza
# ========================================

cleanup() {
    [ -f "$TEMP_DATA" ] && rm -f "$TEMP_DATA"
}

# ========================================
# MAIN - Execução Principal
# ========================================

trap cleanup EXIT INT TERM

log_message "=== Monitor do Sol NOVO Iniciado ==="

# Testa conexão
log_message "Verificando internet..."
if ! check_internet_connection; then
    log_message "❌ Sem internet"
    send_notification "❌ ERRO: Sem conexão com a internet"
    exit 1
fi

log_message "✅ Internet OK"

# Busca dados
if fetch_sun_data_api; then
    if extract_sun_info_json; then
        format_and_display
        log_message "🎉 Sucesso total!"
    else
        log_message "❌ Erro na extração"
        send_notification "⚠️ ERRO: Falha ao processar dados"
        exit 1
    fi
else
    log_message "❌ APIs falharam"
    send_notification "❌ ERRO: APIs indisponíveis"
    exit 1
fi

log_message "=== Monitor do Sol NOVO Finalizado ==="