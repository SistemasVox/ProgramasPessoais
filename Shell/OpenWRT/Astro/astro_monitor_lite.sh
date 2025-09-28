#!/bin/sh

# ========================================
# Monitor Astro Lite (Sol & Lua) usando apenas v2.wttr.in e jq
# Inclui duração do dia e da noite!
# ========================================

DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_PREFIX=$(basename "$0" .sh)
LOG_FILE="$DIR/${SCRIPT_PREFIX}.log"

CITY="Uberlandia"
API_URL="http://v2.wttr.in/${CITY}?format=j1"

SECONDS_PER_HOUR=3600
SECONDS_PER_MINUTE=60
HOURS_PER_DAY=24
SECONDS_PER_DAY=$((HOURS_PER_DAY * SECONDS_PER_HOUR))

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

convert_to_24h() {
    local time_str="$1"
    [ -z "$time_str" ] && echo "00:00" && return
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
    [ -z "$h" ] && h=0
    [ -z "$m" ] && m=0
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

log_message "=== Monitor Astro Lite Iniciado ==="

json=$(curl -s "$API_URL")
if [ -z "$json" ]; then
    log_message "❌ ERRO: Falha ao obter dados de $API_URL"
    exit 1
fi

echo "$json" > "$DIR/.astro_wttr.json"

# Usando jq para extrair dados (compatível ash)
sunrise=$(echo "$json" | jq -r '.weather[0].astronomy[0].sunrise')
sunset=$(echo "$json" | jq -r '.weather[0].astronomy[0].sunset')
moonrise=$(echo "$json" | jq -r '.weather[0].astronomy[0].moonrise')
moonset=$(echo "$json" | jq -r '.weather[0].astronomy[0].moonset')
moon_phase=$(echo "$json" | jq -r '.weather[0].astronomy[0].moon_phase')
moon_illumination=$(echo "$json" | jq -r '.weather[0].astronomy[0].moon_illumination')

moonset_tomorrow=$(echo "$json" | jq -r '.weather[1].astronomy[0].moonset')
sunrise_tomorrow=$(echo "$json" | jq -r '.weather[1].astronomy[0].sunrise')

CURRENT_DATE=$(date '+%B %d, %Y')
CURRENT_TIME=$(date '+%I:%M:%S %p')

sunrise_sec=$(time_to_seconds "$(convert_to_24h "$sunrise")")
sunset_sec=$(time_to_seconds "$(convert_to_24h "$sunset")")
sunrise_tomorrow_sec=$(( $(time_to_seconds "$(convert_to_24h "$sunrise_tomorrow")") + SECONDS_PER_DAY ))
moonrise_sec=$(time_to_seconds "$(convert_to_24h "$moonrise")")
moonset_sec=0

# Duração do dia e da noite
day_duration_seconds=$((sunset_sec - sunrise_sec))
night_duration_seconds=$((SECONDS_PER_DAY - day_duration_seconds))
DAY_DURATION=$(format_duration $day_duration_seconds)
NIGHT_DURATION=$(format_duration $night_duration_seconds)

# Tratamento "No moonset"
if [ "$moonset" = "No moonset" ] && [ -n "$moonset_tomorrow" ] && [ "$moonset_tomorrow" != "No moonset" ]; then
    moonset="$moonset_tomorrow"
    moonset_sec=$(( $(time_to_seconds "$(convert_to_24h "$moonset_tomorrow")") + SECONDS_PER_DAY ))
else
    moonset_sec=$(time_to_seconds "$(convert_to_24h "$moonset")")
    [ "$moonset_sec" -le "$moonrise_sec" ] && moonset_sec=$((moonset_sec + SECONDS_PER_DAY))
fi

LUNAR_LIGHT_INFO="Total: 0h 0min\n• Sem luz lunar significativa"
DARKNESS_INFO="Total: $(format_duration $((sunrise_tomorrow_sec-sunset_sec)))\n• $(format_seconds_to_ampm $((sunset_sec % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((sunrise_tomorrow_sec % SECONDS_PER_DAY))): $(format_duration $((sunrise_tomorrow_sec-sunset_sec)))"

if [ -n "$moonrise" ] && [ -n "$moonset" ] && [ "$moonset" != "No moonset" ] && [ "$moonset_sec" -gt 0 ]; then
    if [ "$moonrise_sec" -le "$sunset_sec" ] && [ "$moonset_sec" -gt "$sunset_sec" ] && [ "$moonset_sec" -le "$sunrise_tomorrow_sec" ]; then
        lunar_start=$sunset_sec
        lunar_end=$moonset_sec
        darkness_start=$lunar_end
        darkness_end=$sunrise_tomorrow_sec
        lunar_light_seconds=$((lunar_end - lunar_start))
        darkness_seconds=$((darkness_end - darkness_start))
        LUNAR_LIGHT_INFO="Total: $(format_duration $lunar_light_seconds)\n• $(format_seconds_to_ampm $((lunar_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((lunar_end % SECONDS_PER_DAY))): $(format_duration $lunar_light_seconds)"
        DARKNESS_INFO="Total: $(format_duration $darkness_seconds)\n• $(format_seconds_to_ampm $((darkness_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((darkness_end % SECONDS_PER_DAY))): $(format_duration $darkness_seconds)"
    elif [ "$moonrise_sec" -gt "$sunset_sec" ] && [ "$moonrise_sec" -lt "$sunrise_tomorrow_sec" ] && [ "$moonset_sec" -gt "$moonrise_sec" ] && [ "$moonset_sec" -le "$sunrise_tomorrow_sec" ]; then
        lunar_start=$moonrise_sec
        lunar_end=$moonset_sec
        darkness1_start=$sunset_sec
        darkness1_end=$lunar_start
        darkness2_start=$lunar_end
        darkness2_end=$sunrise_tomorrow_sec
        lunar_light_seconds=$((lunar_end - lunar_start))
        darkness1_seconds=$((darkness1_end - darkness1_start))
        darkness2_seconds=$((darkness2_end - darkness2_start))
        total_darkness_seconds=$((darkness1_seconds + darkness2_seconds))
        LUNAR_LIGHT_INFO="Total: $(format_duration $lunar_light_seconds)\n• $(format_seconds_to_ampm $((lunar_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((lunar_end % SECONDS_PER_DAY))): $(format_duration $lunar_light_seconds)"
        DARKNESS_INFO="Total: $(format_duration $total_darkness_seconds)\n• $(format_seconds_to_ampm $((darkness1_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((darkness1_end % SECONDS_PER_DAY))): $(format_duration $darkness1_seconds)\n• $(format_seconds_to_ampm $((darkness2_start % SECONDS_PER_DAY))) às $(format_seconds_to_ampm $((darkness2_end % SECONDS_PER_DAY))): $(format_duration $darkness2_seconds)"
    fi
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

MESSAGE_BODY=$(cat << EOF

☀️ Informações Solares e Lunares - Uberlândia (Lite)
═══════════════════════
📅 Data: ${CURRENT_DATE}
🕐 Hora da consulta: ${CURRENT_TIME}

🌅 HORÁRIOS DO SOL:
• Nascer do sol: ${sunrise}
• Pôr do sol: ${sunset}

⏱️ DURAÇÃO:
• Duração do dia: ${DAY_DURATION}
• Duração da noite: ${NIGHT_DURATION}

🌙 Informações Lunares:
🌙 Fase: ${MOON_PHASE}
• Iluminação: ${moon_illumination}%
• Nascer da lua: ${moonrise}
• Pôr da lua: ${moonset}

🌃 TEMPO DE ESCURIDÃO:
$(echo -e "${DARKNESS_INFO}")

🌙 TEMPO DE LUZ LUNAR:
$(echo -e "${LUNAR_LIGHT_INFO}")

📊 Fonte: v2.wttr.in
EOF
)

echo "$MESSAGE_BODY"
log_message "=== Monitor Astro Lite Finalizado ==="
exit 0