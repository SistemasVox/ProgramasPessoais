#!/bin/sh

# ========================================
# Monitor Astro (Sol & Lua) para OpenWrt - Lógica fiel, robusta e upgrade para tratamento de moonset "No moonset"
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
API_URL_SOL="https://api.sunrise-sunset.org/json?lat=${LATITUDE}&lng=${LONGITUDE}&formatted=0&date="
API_URL_LUA="http://v2.wttr.in/Uberlandia?format=j1"

# --- Constantes ---
SECONDS_PER_HOUR=3600
SECONDS_PER_MINUTE=60
HOURS_PER_DAY=24
SECONDS_PER_DAY=$((HOURS_PER_DAY * SECONDS_PER_HOUR))
PING_TIMEOUT=2
CURL_TIMEOUT_SOL=10
CURL_TIMEOUT_LUA=15
RETRY_DELAY=3
CALCULATION_DELAY=2
MAX_LUA_RETRIES=10

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
    [ -z "$hour" ] && hour=0
    [ -z "$min" ] && min=0
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
    local s=$(echo "$time_24h" | cut -d: -f3 | sed 's/^0*//')
    [ -z "$h" ] && h=0
    [ -z "$m" ] && m=0
    [ -z "$s" ] && s=0
    echo $(( (h * SECONDS_PER_HOUR) + (m * SECONDS_PER_MINUTE) + s ))
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

# --- Processamento Lunar (LÓGICA DE RETENTATIVA CORRIGIDA + "No moonset" UPGRADE) ---
log_message "🌙 Buscando dados lunares..."
LUA_RETRY_COUNT=0
moon_phase=""
moonset=""
moonrise=""
moonset_tomorrow=""

while [ -z "$moon_phase" ] && [ "$LUA_RETRY_COUNT" -lt "$MAX_LUA_RETRIES" ]; do
    LUA_RETRY_COUNT=$((LUA_RETRY_COUNT + 1))
    if [ "$LUA_RETRY_COUNT" -gt 1 ]; then
        log_message " Tentativa ${LUA_RETRY_COUNT}/${MAX_LUA_RETRIES} para a API da Lua. Resposta anterior inválida ou falha no download. Aguardando $RETRY_DELAY segundos..."
        sleep $RETRY_DELAY
    fi

    json_lua_raw=$(curl -s -m $CURL_TIMEOUT_LUA "$API_URL_LUA")
    if [ -n "$json_lua_raw" ]; then
        json_load "$json_lua_raw"
        # Pega o dia de hoje (weather[0])
        json_select weather
        json_select 1
        json_select astronomy
        json_select 1
        json_get_vars moon_phase moon_illumination moonrise moonset
        json_select ..; json_select ..; json_select ..; json_select ..
        # Se moonset for "No moonset", tenta pegar do próximo dia!
        if [ "$moonset" = "No moonset" ]; then
            json_select weather
            json_select 2
            json_select astronomy
            json_select 1
            json_get_var moonset_tomorrow moonset
            json_select ..; json_select ..; json_select ..; json_select ..
            # Só usa se for até meio-dia (ajuste conforme desejado)
            moonset_tomorrow_24h=$(convert_to_24h "$moonset_tomorrow")
            moonset_tomorrow_sec=$(time_to_seconds "$moonset_tomorrow_24h")
            if [ "$moonset_tomorrow_sec" -le $((12 * 3600)) ]; then
                moonset="$moonset_tomorrow"
            fi
        fi
    fi
done

if [ -z "$moon_phase" ]; then
    log_message "❌ ERRO: Falha ao obter e processar dados da API da Lua após $MAX_LUA_RETRIES tentativas."
    send_notification "Erro crítico ao obter dados lunares após $MAX_LUA_RETRIES tentativas. O script será encerrado."
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

# --- Lógica fiel de escuridão e luz lunar --- (VERSÃO CORRIGIDA COMPLETA)
log_message "⏳ Calculando tempo de escuridão e luz lunar..."
sleep $CALCULATION_DELAY

DARKNESS_INFO="Dados insuficientes para cálculo."
LUNAR_LIGHT_INFO="Dados insuficientes para cálculo."

if [ -n "$LAST_LIGHT" ] && [ -n "$FIRST_LIGHT" ] && [ -n "$moonrise" ] && [ -n "$moonset" ] && [ "$moonset" != "No moonset" ]; then
    last_light_sec=$(time_to_seconds "$(convert_to_24h "$LAST_LIGHT")")
    first_light_sec=$(time_to_seconds "$(convert_to_24h "$FIRST_LIGHT")")
    if [ "$first_light_sec" -le "$last_light_sec" ]; then
        night_end=$((first_light_sec + SECONDS_PER_DAY))
    else
        night_end=$first_light_sec
    fi
    night_start=$last_light_sec

    moonrise_sec=$(time_to_seconds "$(convert_to_24h "$moonrise")")
    moonset_sec=$(time_to_seconds "$(convert_to_24h "$moonset")")
    [ "$moonset_sec" -le "$moonrise_sec" ] && moonset_sec=$((moonset_sec + SECONDS_PER_DAY))

    # Interseção dos intervalos [noite] ∩ [lua acima do horizonte]
    lunar_light_start=$((moonrise_sec > night_start ? moonrise_sec : night_start))
    lunar_light_end=$((moonset_sec < night_end ? moonset_sec : night_end))

    if [ "$lunar_light_end" -gt "$lunar_light_start" ]; then
        lunar_light_seconds=$((lunar_light_end - lunar_light_start))
        LUNAR_LIGHT_INFO="Total: $(format_duration $lunar_light_seconds)\n• $(format_seconds_to_ampm $((lunar_light_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((lunar_light_end % SECONDS_PER_DAY))): $(format_duration $lunar_light_seconds)"
        # A escuridão é o restante da noite antes e/ou depois da luz lunar
        darkness1_start=$night_start
        darkness1_end=$lunar_light_start
        darkness2_start=$lunar_light_end
        darkness2_end=$night_end
        darkness1_seconds=$((darkness1_end - darkness1_start))
        darkness2_seconds=$((darkness2_end - darkness2_start))
        total_darkness_seconds=$(( (darkness1_seconds > 0 ? darkness1_seconds : 0) + (darkness2_seconds > 0 ? darkness2_seconds : 0) ))
        DARKNESS_INFO="Total: $(format_duration $total_darkness_seconds)"
        [ "$darkness1_seconds" -gt 0 ] && DARKNESS_INFO="${DARKNESS_INFO}\n• $(format_seconds_to_ampm $((darkness1_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((darkness1_end % SECONDS_PER_DAY))): $(format_duration $darkness1_seconds)"
        [ "$darkness2_seconds" -gt 0 ] && DARKNESS_INFO="${DARKNESS_INFO}\n• $(format_seconds_to_ampm $((darkness2_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((darkness2_end % SECONDS_PER_DAY))): $(format_duration $darkness2_seconds)"
    else
        # Sem interseção: toda a noite é escura
        darkness_seconds=$((night_end - night_start))
        DARKNESS_INFO="Total: $(format_duration $darkness_seconds)\n• $(format_seconds_to_ampm $((night_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((night_end % SECONDS_PER_DAY))): $(format_duration $darkness_seconds)"
        LUNAR_LIGHT_INFO="Total: 0h 0min\n• Sem luz lunar significativa"
    fi
fi

log_message "✅ Cálculo de escuridão e luz lunar finalizado."

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

🌙 TEMPO DE LUZ LUNAR:
$(echo -e "${LUNAR_LIGHT_INFO}")
  (Intervalos noturnos com luz da lua)

───────────────────
📊 Fontes: sunrise-sunset.org, v2.wttr.in
✅ Dados obtidos com sucesso!
EOF
)

echo "$MESSAGE_BODY"
send_notification "$MESSAGE_BODY"
log_message "=== Monitor Astro Finalizado ==="
exit 0