#!/bin/sh

# ========================================
# Monitor Astro (Sol & Lua) para OpenWrt - VERSÃO FINAL CONSOLIDADA
# ========================================

# --- Diretório e Arquivo de Log ---
DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_PREFIX=$(basename "$0" .sh)
LOG_FILE="$DIR/${SCRIPT_PREFIX}.log"

# --- Configuração ---
LATITUDE="-18.9113"
LONGITUDE="-48.2622"
TIMEZONE_OFFSET_HOURS=-3  # Fuso horário de Brasília (BRT)

# --- APIs ---
API_URL_SOL="https://api.sunrise-sunset.org/json?lat=${LATITUDE}&lng=${LONGITUDE}&formatted=0&date=" # A data será 'today' ou 'tomorrow'
API_URL_LUA="http://v2.wttr.in/Uberlandia?format=j1"

# --- Constantes ---
SECONDS_PER_HOUR=3600
SECONDS_PER_MINUTE=60
HOURS_PER_DAY=24
SECONDS_PER_DAY=$((HOURS_PER_DAY * SECONDS_PER_HOUR))
PING_TIMEOUT=2
CURL_TIMEOUT_SOL=10
CURL_TIMEOUT_LUA=15
RETRY_DELAY=30
CALCULATION_DELAY=2
MAX_LUA_RETRIES=5 # <<< ÚNICA LINHA ADICIONADA AQUI

# --- Funções ---

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

send_notification() {
    local script_name message
    script_name=$(basename "$0")
    message=$(printf "[%s]\n%s" "$script_name" "$1")
    log_message "Enviando notificação via WhatsApp..."
    # Descomente as linhas abaixo para ativar o envio de notificações
    # "$DIR/send_whatsapp.sh" "$message" >/dev/null 2>&1
    # "$DIR/send_whatsapp_2.sh" "$message" >/dev/null 2>&1
    log_message "Notificação enviada."
}

check_internet_connection() {
    ping -c 1 -W $PING_TIMEOUT "1.1.1.1" >/dev/null 2>&1
}

utc_to_local_manual() {
    local utc_str="$1"
    [ -z "$utc_str" ] && echo "" && return
    local date_part=$(echo "$utc_str" | cut -d' ' -f1)
    local time_part=$(echo "$utc_str" | cut -d' ' -f2)
    local hour=$(echo "$time_part" | cut -d: -f1 | sed 's/^0*//')
    local rest_of_time=$(echo "$time_part" | cut -d: -f2,3)
    local local_hour=$((hour + TIMEZONE_OFFSET_HOURS))
    
    if [ "$local_hour" -lt 0 ]; then
        local_hour=$((local_hour + HOURS_PER_DAY))
        local local_date_part=$(date -d "$date_part -1 day" "+%Y-%m-%d")
        echo "$local_date_part $(printf "%02d" $local_hour):$rest_of_time"
    elif [ "$local_hour" -ge "$HOURS_PER_DAY" ]; then
        local_hour=$((local_hour - HOURS_PER_DAY))
        local local_date_part=$(date -d "$date_part +1 day" "+%Y-%m-%d")
        echo "$local_date_part $(printf "%02d" $local_hour):$rest_of_time"
    else
        echo "$date_part $(printf "%02d" $local_hour):$rest_of_time"
    fi
}

convert_to_24h() {
    local time_str="$1"
    [ -z "$time_str" ] && echo "" && return
    local time_part=$(echo "$time_str" | cut -d' ' -f1)
    local ampm=$(echo "$time_str" | cut -d' ' -f2)
    local hour=$(echo "$time_part" | cut -d: -f1 | sed 's/^0*//')
    local min=$(echo "$time_part" | cut -d: -f2 | sed 's/^0*//')
    
    case "$ampm" in
        "PM") [ "$hour" -ne 12 ] && hour=$((hour + 12)) ;;
        "AM") [ "$hour" -eq 12 ] && hour=0 ;;
    esac
    printf "%02d:%02d" "$hour" "$min"
}

time_to_seconds() {
    local time_24h="$1"
    [ -z "$time_24h" ] && echo "0" && return
    local h=$(echo "$time_24h" | cut -d: -f1 | sed 's/^0*//')
    local m=$(echo "$time_24h" | cut -d: -f2 | sed 's/^0*//')
    echo $(( (h * SECONDS_PER_HOUR) + (m * SECONDS_PER_MINUTE) ))
}

format_duration() {
    local s=${1:-0}
    [ "$s" -lt 0 ] && s=0
    local hours=$((s / SECONDS_PER_HOUR))
    local minutes=$(((s % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE))
    echo "${hours}h ${minutes}min"
}

format_seconds_to_ampm() {
    local seconds=$1
    local hour24=$((seconds / SECONDS_PER_HOUR))
    local minutes=$(((seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE))
    local hour12=$hour24
    local ampm="AM"

    if [ $hour24 -ge 12 ]; then
        ampm="PM"
        [ $hour24 -gt 12 ] && hour12=$((hour24 - 12))
    fi
    [ $hour12 -eq 0 ] && hour12=12
    printf "%02d:%02d %s" $hour12 $minutes $ampm
}

# ========================================
# Programa Principal
# ========================================

log_message "=== Monitor Astro Iniciado ==="
. /usr/share/libubox/jshn.sh

# --- Verificação de Conexão com a Internet ---
while ! check_internet_connection; do
    log_message "🔌 Sem conexão com a internet. Tentando novamente em $RETRY_DELAY segundos..."
    sleep $RETRY_DELAY
done
log_message "✅ Conexão com a internet estabelecida."

# --- Processamento Solar ---
log_message "☀️ Buscando dados solares..."
json_sol_raw=$(curl -s -m $CURL_TIMEOUT_SOL "${API_URL_SOL}today")
if ! echo "$json_sol_raw" | grep -q '"status":"OK"'; then
    log_message "❌ ERRO: Falha ao obter dados da API do Sol."
    send_notification "Erro ao obter dados solares. O script será encerrado."
    exit 1
fi

json_load "$json_sol_raw"
json_select results
json_get_vars sunrise sunset solar_noon day_length civil_twilight_begin civil_twilight_end
json_select ..

sunrise_utc=$(echo "$sunrise" | sed 's/T/ /; s/+00:00//')
sunset_utc=$(echo "$sunset" | sed 's/T/ /; s/+00:00//')
solar_noon_utc=$(echo "$solar_noon" | sed 's/T/ /; s/+00:00//')
civil_twilight_begin_utc=$(echo "$civil_twilight_begin" | sed 's/T/ /; s/+00:00//')
civil_twilight_end_utc=$(echo "$civil_twilight_end" | sed 's/T/ /; s/+00:00//')

sunrise_local=$(utc_to_local_manual "$sunrise_utc")
sunset_local=$(utc_to_local_manual "$sunset_utc")
solar_noon_local=$(utc_to_local_manual "$solar_noon_utc")
first_light_local=$(utc_to_local_manual "$civil_twilight_begin_utc")
last_light_local=$(utc_to_local_manual "$civil_twilight_end_utc")

SUNRISE=$(date -d "$sunrise_local" "+%I:%M:%S %p")
SUNSET=$(date -d "$sunset_local" "+%I:%M:%S %p")
SOLAR_NOON=$(date -d "$solar_noon_local" "+%I:%M:%S %p")
FIRST_LIGHT=$(date -d "$first_light_local" "+%I:%M:%S %p")
LAST_LIGHT=$(date -d "$last_light_local" "+%I:%M:%S %p")
DAY_LENGTH=$(format_duration "$day_length")
CURRENT_DATE=$(date '+%B %d, %Y')
CURRENT_TIME=$(date '+%I:%M:%S %p')
log_message "✅ Dados solares processados."

# --- Processamento Lunar (INÍCIO DA SEÇÃO MODIFICADA) ---
log_message "🌙 Buscando dados lunares..."
LUA_RETRY_COUNT=0
json_lua_raw=""

while [ -z "$json_lua_raw" ] && [ "$LUA_RETRY_COUNT" -lt "$MAX_LUA_RETRIES" ]; do
    LUA_RETRY_COUNT=$((LUA_RETRY_COUNT + 1))
    if [ "$LUA_RETRY_COUNT" -gt 1 ]; then
        log_message " Tentativa ${LUA_RETRY_COUNT}/${MAX_LUA_RETRIES} para a API da Lua após falha. Aguardando $RETRY_DELAY segundos..."
        sleep $RETRY_DELAY
    fi
    json_lua_raw=$(curl -s -m $CURL_TIMEOUT_LUA "$API_URL_LUA")
done

if [ -z "$json_lua_raw" ]; then
    log_message "❌ ERRO: Falha ao obter dados da API da Lua após $MAX_LUA_RETRIES tentativas."
    send_notification "Erro ao obter dados lunares após $MAX_LUA_RETRIES tentativas. O script será encerrado."
    exit 1
fi

json_load "$json_lua_raw"
json_select weather; json_select 1; json_select astronomy; json_select 1
json_get_vars moon_phase moon_illumination moonrise moonset
json_select ..; json_select ..; json_select ..; json_select ..

if [ -z "$moon_phase" ]; then
    log_message "❌ ERRO: Não foi possível extrair dados lunares do JSON. A resposta da API pode estar malformada."
    send_notification "Erro ao extrair dados lunares do JSON. O script será encerrado."
    exit 1
fi

case "$moon_phase" in
    "New Moon")          MOON_PHASE="🌑 Lua Nova" ;;
    "Waxing Crescent")   MOON_PHASE="🌒 Crescente Côncava" ;;
    "First Quarter")     MOON_PHASE="🌓 Quarto Crescente" ;;
    "Waxing Gibbous")    MOON_PHASE="🌔 Gibosa Crescente" ;;
    "Full Moon")         MOON_PHASE="🌕 Lua Cheia" ;;
    "Waning Gibbous")    MOON_PHASE="🌖 Gibosa Minguante" ;;
    "Last Quarter")      MOON_PHASE="🌗 Quarto Minguante" ;;
    "Waning Crescent")   MOON_PHASE="🌘 Minguante Côncava" ;;
    *)                   MOON_PHASE="🌙 $moon_phase" ;;
esac
log_message "✅ Dados lunares processados."
# --- Processamento Lunar (FIM DA SEÇÃO MODIFICADA) ---

# --- Lógica de Escuridão (Baseada em Janelas de Tempo) ---
log_message "⏳ Calculando tempo de escuridão..."
sleep $CALCULATION_DELAY

DARKNESS_INFO="Dados insuficientes para cálculo."
json_sol_tomorrow_raw=$(curl -s -m $CURL_TIMEOUT_SOL "${API_URL_SOL}tomorrow")

if echo "$json_sol_tomorrow_raw" | grep -q '"status":"OK"'; then
    json_load "$json_sol_tomorrow_raw"
    json_select results
    json_get_var civil_twilight_begin_tomorrow civil_twilight_begin
    json_select ..
    
    # --- CONVERSÃO PARA SEGUNDOS ABSOLUTOS ---
    tomorrow_utc=$(echo "$civil_twilight_begin_tomorrow" | sed 's/T/ /; s/+00:00//')
    tomorrow_local=$(utc_to_local_manual "$tomorrow_utc")
    first_light_tomorrow_24h=$(date -d "$tomorrow_local" "+%H:%M")

    night_start_sec=$(time_to_seconds "$(convert_to_24h "$LAST_LIGHT")")
    first_light_tomorrow_relative_sec=$(time_to_seconds "$first_light_tomorrow_24h")
    night_end_sec=$((first_light_tomorrow_relative_sec + SECONDS_PER_DAY))

    moonrise_relative_sec=$(time_to_seconds "$(convert_to_24h "$moonrise")")
    moonset_relative_sec=$(time_to_seconds "$(convert_to_24h "$moonset")")
    moonrise_abs_sec=$moonrise_relative_sec
    
    if [ "$moonset_relative_sec" -lt "$moonrise_relative_sec" ]; then
        moonset_abs_sec=$((moonset_relative_sec + SECONDS_PER_DAY))
    else
        moonset_abs_sec=$moonset_relative_sec
    fi

    # --- CÁLCULO DAS JANELAS DE ESCURIDÃO ---
    total_darkness_seconds=0
    darkness_details=""

    # 1. Janela da NOITE (entre crepúsculo e nascer da lua)
    evening_darkness_end_sec=$moonrise_abs_sec
    [ "$evening_darkness_end_sec" -gt "$night_end_sec" ] && evening_darkness_end_sec=$night_end_sec

    if [ "$evening_darkness_end_sec" -gt "$night_start_sec" ]; then
        duration=$((evening_darkness_end_sec - night_start_sec))
        total_darkness_seconds=$((total_darkness_seconds + duration))
        darkness_details="${darkness_details}• ${LAST_LIGHT} às ${moonrise}: $(format_duration $duration)\n"
    fi

    # 2. Janela da MANHÃ (entre pôr da lua e crepúsculo)
    morning_darkness_start_sec=$moonset_abs_sec
    [ "$morning_darkness_start_sec" -lt "$night_start_sec" ] && morning_darkness_start_sec=$night_start_sec
    
    if [ "$night_end_sec" -gt "$morning_darkness_start_sec" ]; then
        duration=$((night_end_sec - morning_darkness_start_sec))
        total_darkness_seconds=$((total_darkness_seconds + duration))
        end_time_str="$(format_seconds_to_ampm $first_light_tomorrow_relative_sec)"
        darkness_details="${darkness_details}• ${moonset} às ${end_time_str}: $(format_duration $duration)\n"
    fi

    # 3. Formatação da saída final
    total_duration_str=$(format_duration $total_darkness_seconds)
    if [ "$total_darkness_seconds" -gt 0 ]; then
        darkness_details=$(echo -e "$darkness_details" | sed '/^$/d' | sed '$ s/.$//')
        DARKNESS_INFO="Total: ${total_duration_str}\n${darkness_details}"
    else
        DARKNESS_INFO="Total: 0h 0min\n• Sem escuridão significativa"
    fi
else
    log_message "⚠️ AVISO: Falha ao obter dados solares para amanhã."
fi
log_message "✅ Cálculo de escuridão finalizado."

# --- Exibir informações e Notificar ---
MESSAGE_BODY=$(cat << EOF

☀️ Informações Solares - Uberlândia
═══════════════════════
📅 Data: ${CURRENT_DATE}
🕐 Hora da consulta: ${CURRENT_TIME}

🌅 HORÁRIOS DO SOL:
• Primeira luz: ${FIRST_LIGHT}
• Nascer do sol: ${SUNRISE}
• Meio-dia solar: ${SOLAR_NOON}
• Pôr do sol: ${SUNSET}
• Última luz: ${LAST_LIGHT}

⏱️ DURAÇÃO:
• Duração do dia: ${DAY_LENGTH}

🌙 Informações Lunares - Uberlândia
╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋
🌙 FASE DA LUA:
• Fase atual: ${MOON_PHASE}
• Iluminação: ${moon_illumination}%

🌇 HORÁRIOS DA LUA (horário local):
• Nascer da lua: ${moonrise}
• Pôr da lua: ${moonset}

🌃 TEMPO DE ESCURIDÃO:
$(echo -e "${DARKNESS_INFO}")
  (Intervalos sem luz solar ou lunar)

───────────────────
📊 Fontes: sunrise-sunset.org, v2.wttr.in
✅ Dados obtidos com sucesso!
EOF
)

echo "$MESSAGE_BODY"
send_notification "$MESSAGE_BODY"
log_message "=== Monitor Astro Finalizado ==="
exit 0
