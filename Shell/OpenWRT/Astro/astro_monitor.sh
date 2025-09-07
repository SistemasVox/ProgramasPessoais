#!/bin/sh

# ========================================
# Monitor Astro (Sol & Lua) para OpenWrt - VERSÃO FINAL (COM LOG E NOTIFICAÇÃO)
# ========================================

# --- Diretório e Arquivo de Log ---
# Usa $0 que é mais compatível com sh/ash do que BASH_SOURCE
DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_PREFIX=$(basename "$0" .sh)
LOG_FILE="$DIR/${SCRIPT_PREFIX}.log"

# --- Configuração ---
LATITUDE="-18.9113"
LONGITUDE="-48.2622"
TIMEZONE_OFFSET_HOURS=3 # Para America/Sao_Paulo (UTC-3)

# --- APIs ---
API_URL_SOL="https://api.sunrise-sunset.org/json?lat=${LATITUDE}&lng=${LONGITUDE}&formatted=0&date=today"
API_URL_LUA="http://v2.wttr.in/Uberlandia?format=j1"

# --- Funções ---

# Função de Log: Escreve no console e no arquivo de log
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Função de Notificação: Envia a mensagem para os scripts do WhatsApp
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

utc_to_local_manual() {
    local utc_str="$1"; if [ -z "$utc_str" ]; then echo ""; return; fi
    local date_part=$(echo "$utc_str" | cut -d' ' -f1); local time_part=$(echo "$utc_str" | cut -d' ' -f2)
    local hour=$(echo "$time_part" | cut -d: -f1); local rest_of_time=$(echo "$time_part" | cut -d: -f2,3)
    case "$hour" in 0?) hour=${hour#0};; esac
    local local_hour=$(($hour - TIMEZONE_OFFSET_HOURS))
    if [ "$local_hour" -lt 0 ]; then
        local_hour=$((local_hour + 24))
        local local_date_part=$(date -d "$date_part -1 day" "+%Y-%m-%d")
        echo "$local_date_part $local_hour:$rest_of_time"
    else
        echo "$date_part $local_hour:$rest_of_time"
    fi
}

convert_to_24h() {
    local time_str="$1"; if [ -z "$time_str" ]; then echo ""; return; fi
    local hour=$(echo "$time_str" | cut -d: -f1); local min_ampm=$(echo "$time_str" | cut -d: -f2)
    local min=$(echo "$min_ampm" | cut -d' ' -f1); local ampm=$(echo "$min_ampm" | cut -d' ' -f2)
    case "$hour" in 0?) hour=${hour#0};; esac
    case "$ampm" in
        "PM") if [ "$hour" -ne 12 ]; then hour=$((hour + 12)); fi ;;
        "AM") if [ "$hour" -eq 12 ]; then hour=0; fi ;;
    esac
    printf "%02d:%02d" "$hour" "$min"
}

time_to_seconds() {
    local time_24h="$1"; if [ -z "$time_24h" ]; then echo "0"; return; fi
    local h=$(echo "$time_24h" | cut -d: -f1); local m=$(echo "$time_24h" | cut -d: -f2)
    case "$h" in 0?) h=${h#0};; esac; case "$m" in 0?) m=${m#0};; esac
    echo $(( (h * 3600) + (m * 60) ))
}

format_duration() {
    local s=$1; if [ -z "$s" ] || [ "$s" -lt 0 ]; then s=0; fi
    echo "$((s / 3600))h $(((s % 3600) / 60))min"
}

format_for_display() {
    local time_str="$1"
    if echo "$time_str" | grep -q ':[0-9][0-9]:'; then
        local hour_min=$(echo "$time_str" | cut -d: -f1,2); local ampm=$(echo "$time_str" | cut -d' ' -f2)
        echo "$hour_min $ampm"
    else
        echo "$time_str"
    fi
}

# ========================================
# Programa Principal
# ========================================

log_message "=== Monitor Astro Iniciado ==="
. /usr/share/libubox/jshn.sh

# --- Processamento Solar ---
log_message "☀️ Buscando dados solares..."
json_sol_raw=$(curl -s -m 10 "$API_URL_SOL")
if ! echo "$json_sol_raw" | grep -q '"status":"OK"'; then log_message "❌ ERRO: Falha ao obter dados da API do Sol."; exit 1; fi

json_load "$json_sol_raw"; json_select results
json_get_vars sunrise sunset solar_noon day_length civil_twilight_begin civil_twilight_end
json_select ..

sunrise_utc=$(echo "$sunrise" | sed 's/T/ /; s/+00:00//'); sunset_utc=$(echo "$sunset" | sed 's/T/ /; s/+00:00//')
solar_noon_utc=$(echo "$solar_noon" | sed 's/T/ /; s/+00:00//'); civil_twilight_begin_utc=$(echo "$civil_twilight_begin" | sed 's/T/ /; s/+00:00//')
civil_twilight_end_utc=$(echo "$civil_twilight_end" | sed 's/T/ /; s/+00:00//')

sunrise_local=$(utc_to_local_manual "$sunrise_utc"); sunset_local=$(utc_to_local_manual "$sunset_utc")
solar_noon_local=$(utc_to_local_manual "$solar_noon_utc"); first_light_local=$(utc_to_local_manual "$civil_twilight_begin_utc")
last_light_local=$(utc_to_local_manual "$civil_twilight_end_utc")

SUNRISE=$(date -d "$sunrise_local" "+%I:%M:%S %p"); SUNSET=$(date -d "$sunset_local" "+%I:%M:%S %p")
SOLAR_NOON=$(date -d "$solar_noon_local" "+%I:%M:%S %p"); FIRST_LIGHT=$(date -d "$first_light_local" "+%I:%M:%S %p")
LAST_LIGHT=$(date -d "$last_light_local" "+%I:%M:%S %p")
DAY_LENGTH=$(format_duration "$day_length"); CURRENT_DATE=$(date '+%B %d, %Y'); CURRENT_TIME=$(date '+%I:%M:%S %p')
log_message "✅ Dados solares processados."

# --- Processamento Lunar ---
log_message "🌙 Buscando dados lunares..."
json_lua_raw=$(curl -s -m 15 "$API_URL_LUA")
if [ -z "$json_lua_raw" ]; then log_message "❌ ERRO: Falha ao obter dados da API da Lua."; exit 1; fi

json_load "$json_lua_raw"; json_select weather; json_select 1; json_select astronomy; json_select 1
json_get_vars moon_phase moon_illumination moonrise moonset
json_select ..; json_select ..; json_select ..; json_select ..;
if [ -z "$moon_phase" ]; then log_message "❌ ERRO: Não foi possível extrair dados lunares do JSON."; exit 1; fi

case "$moon_phase" in
    "New Moon")          MOON_PHASE="🌑 Lua Nova" ;; "Waxing Crescent")   MOON_PHASE="🌒 Crescente Côncava" ;;
    "First Quarter")     MOON_PHASE="🌓 Quarto Crescente" ;; "Waxing Gibbous")    MOON_PHASE="🌔 Gibosa Crescente" ;;
    "Full Moon")         MOON_PHASE="🌕 Lua Cheia" ;; "Waning Gibbous")    MOON_PHASE="🌖 Gibosa Minguante" ;;
    "Last Quarter")      MOON_PHASE="🌗 Quarto Minguante" ;; "Waning Crescent")   MOON_PHASE="🌘 Minguante Côncava" ;;
    *)                   MOON_PHASE="🌙 $moon_phase" ;;
esac
log_message "✅ Dados lunares processados."

# --- Lógica de Escuridão ---
log_message "⏳ Calculando tempo de escuridão..."
sleep 2
json_sol_tomorrow_raw=$(curl -s -m 10 "$(echo $API_URL_SOL | sed 's/today/tomorrow/')")
first_light_tomorrow_24h=""
if echo "$json_sol_tomorrow_raw" | grep -q '"status":"OK"'; then
    json_load "$json_sol_tomorrow_raw"; json_select results
    json_get_var civil_twilight_begin_tomorrow civil_twilight_begin
    json_select ..
    if [ -n "$civil_twilight_begin_tomorrow" ]; then
        tomorrow_utc=$(echo "$civil_twilight_begin_tomorrow" | sed 's/T/ /; s/+00:00//')
        tomorrow_local=$(utc_to_local_manual "$tomorrow_utc")
        first_light_tomorrow_24h=$(date -d "$tomorrow_local" "+%H:%M")
    fi
else
    log_message "⚠️ AVISO: Falha ao obter dados solares para amanhã."
fi
last_light_sec=$(time_to_seconds "$(convert_to_24h "$LAST_LIGHT")"); moonrise_sec=$(time_to_seconds "$(convert_to_24h "$moonrise")")
moonset_sec=$(time_to_seconds "$(convert_to_24h "$moonset")"); first_light_tomorrow_sec=$(time_to_seconds "$first_light_tomorrow_24h")
darkness_seconds=0; DARKNESS_INFO="N/D"
if [ "$first_light_tomorrow_sec" -gt 0 ] && [ "$last_light_sec" -gt 0 ]; then
    darkness_start_display=""; darkness_end_display=""
    if [ "$moonset_sec" -lt "$moonrise_sec" ]; then
        if [ "$first_light_tomorrow_sec" -gt "$moonset_sec" ]; then
            darkness_seconds=$((first_light_tomorrow_sec - moonset_sec))
            darkness_start_display=$(format_for_display "$moonset")
            darkness_end_display=$(date -d "$first_light_tomorrow_24h" "+%I:%M %p")
        fi
    else
        darkness_start_sec=$last_light_sec; darkness_start_display=$(format_for_display "$LAST_LIGHT")
        if [ "$moonset_sec" -gt "$last_light_sec" ]; then
            darkness_start_sec=$moonset_sec; darkness_start_display=$(format_for_display "$moonset")
        fi
        darkness_seconds=$((86400 - darkness_start_sec + first_light_tomorrow_sec))
        darkness_end_display=$(date -d "$first_light_tomorrow_24h" "+%I:%M %p")
    fi
    if [ "$darkness_seconds" -gt 60 ]; then
        duration_str=$(format_duration "$darkness_seconds")
        DARKNESS_INFO="${duration_str} (das ${darkness_start_display} às ${darkness_end_display})"
    else
        DARKNESS_INFO=$(format_duration "$darkness_seconds")
    fi
else
    DARKNESS_INFO="Cálculo indisponível"
fi
log_message "✅ Cálculo de escuridão finalizado."

# --- Exibir informações e Notificar ---
# Armazena a mensagem final em uma variável
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
• Período e Duração: ${DARKNESS_INFO}
  (Intervalo sem luz solar ou lunar)

───────────────────
📊 Fontes: sunrise-sunset.org, v2.wttr.in
✅ Dados obtidos com sucesso!
EOF
)

# Exibe a mensagem no console
echo "$MESSAGE_BODY"

# Envia a notificação
send_notification "$MESSAGE_BODY"

log_message "=== Monitor Astro Finalizado ==="
exit 0