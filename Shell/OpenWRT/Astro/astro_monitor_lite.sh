#!/bin/sh

# ========================================
# Monitor Astro Lite (Sol & Lua) usando apenas v2.wttr.in e jq
# Inclui duração do dia e da noite!
# ========================================

DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_PREFIX=$(basename "$0" .sh)
LOG_FILE="$DIR/${SCRIPT_PREFIX}.log"

CIDADE="Uberlandia"
API_URL="http://v2.wttr.in/${CIDADE}?format=j1"

SEGUNDOS_POR_HORA=3600
SEGUNDOS_POR_MINUTO=60
HORAS_POR_DIA=24
SEGUNDOS_POR_DIA=$((HORAS_POR_DIA * SEGUNDOS_POR_HORA))

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

converter_para_24h() {
    local horario="$1"
    [ -z "$horario" ] && echo "00:00" && return
    local parte_hora=$(echo "$horario" | cut -d' ' -f1)
    local ampm=$(echo "$horario" | cut -d' ' -f2)
    local hora=$(echo "$parte_hora" | cut -d: -f1 | sed 's/^0*//')
    local min=$(echo "$parte_hora" | cut -d: -f2 | sed 's/^0*//')
    [ -z "$hora" ] && hora=0
    [ -z "$min" ] && min=0
    case "$ampm" in
        "PM") [ "$hora" -ne 12 ] && hora=$((hora + 12)) ;;
        "AM") [ "$hora" -eq 12 ] && hora=0 ;;
    esac
    printf "%02d:%02d" "$hora" "$min"
}

hora_para_segundos() {
    local hora_24h="$1"
    [ -z "$hora_24h" ] && echo "0" && return
    local h=$(echo "$hora_24h" | cut -d: -f1 | sed 's/^0*//')
    local m=$(echo "$hora_24h" | cut -d: -f2 | sed 's/^0*//')
    [ -z "$h" ] && h=0
    [ -z "$m" ] && m=0
    echo $(( (h * SEGUNDOS_POR_HORA) + (m * SEGUNDOS_POR_MINUTO) ))
}

formata_duracao() {
    local s=${1:-0}
    [ "$s" -lt 0 ] && s=0
    local horas=$((s / SEGUNDOS_POR_HORA))
    local minutos=$(((s % SEGUNDOS_POR_HORA) / SEGUNDOS_POR_MINUTO))
    echo "${horas}h ${minutos}min"
}

formata_segundos_para_ampm() {
    local segundos=$1
    local hora24=$((segundos / SEGUNDOS_POR_HORA))
    local minutos=$(((segundos % SEGUNDOS_POR_HORA) / SEGUNDOS_POR_MINUTO))
    local hora12=$hora24
    local ampm="AM"
    if [ $hora24 -ge 12 ]; then
        ampm="PM"
        [ $hora24 -gt 12 ] && hora12=$((hora24 - 12))
    fi
    [ $hora12 -eq 0 ] && hora12=12
    printf "%02d:%02d %s" $hora12 $minutos $ampm
}

log_message "=== Monitor Astro Lite Iniciado ==="

json=$(curl -s "$API_URL")
if [ -z "$json" ]; then
    log_message "❌ ERRO: Falha ao obter dados de $API_URL"
    exit 1
fi

echo "$json" > "$DIR/.astro_wttr.json"

# Usando jq para extrair dados
nascer_sol=$(echo "$json" | jq -r '.weather[0].astronomy[0].sunrise')
por_sol=$(echo "$json" | jq -r '.weather[0].astronomy[0].sunset')
nascer_lua=$(echo "$json" | jq -r '.weather[0].astronomy[0].moonrise')
por_lua=$(echo "$json" | jq -r '.weather[0].astronomy[0].moonset')
fase_lua=$(echo "$json" | jq -r '.weather[0].astronomy[0].moon_phase')
iluminacao_lua=$(echo "$json" | jq -r '.weather[0].astronomy[0].moon_illumination')

por_lua_amanha=$(echo "$json" | jq -r '.weather[1].astronomy[0].moonset')
nascer_sol_amanha=$(echo "$json" | jq -r '.weather[1].astronomy[0].sunrise')

DATA_ATUAL=$(date '+%d/%m/%Y')
HORA_ATUAL=$(date '+%H:%M:%S')

nascer_sol_seg=$(hora_para_segundos "$(converter_para_24h "$nascer_sol")")
por_sol_seg=$(hora_para_segundos "$(converter_para_24h "$por_sol")")
nascer_sol_amanha_seg=$(( $(hora_para_segundos "$(converter_para_24h "$nascer_sol_amanha")") + SEGUNDOS_POR_DIA ))
nascer_lua_seg=$(hora_para_segundos "$(converter_para_24h "$nascer_lua")")

# Duração do dia e da noite
duracao_dia_segundos=$((por_sol_seg - nascer_sol_seg))
duracao_noite_segundos=$((SEGUNDOS_POR_DIA - duracao_dia_segundos))
DURACAO_DIA=$(formata_duracao $duracao_dia_segundos)
DURACAO_NOITE=$(formata_duracao $duracao_noite_segundos)

# --- Cálculo fiel da luz lunar e escuridão ---
INFO_LUZ_LUNAR="Total: 0h 0min\n• Sem luz lunar significativa"
INFO_ESCURIDAO="Dados insuficientes para cálculo."

# Intervalo noturno
noite_inicio=$por_sol_seg
noite_fim=$nascer_sol_amanha_seg

# Intervalo lunar
por_lua_seg=0
if [ "$por_lua" = "No moonset" ] && [ -n "$por_lua_amanha" ] && [ "$por_lua_amanha" != "No moonset" ]; then
    por_lua_seg=$(( $(hora_para_segundos "$(converter_para_24h "$por_lua_amanha")") + SEGUNDOS_POR_DIA ))
else
    por_lua_seg=$(hora_para_segundos "$(converter_para_24h "$por_lua")")
    [ "$por_lua_seg" -le "$nascer_lua_seg" ] && por_lua_seg=$((por_lua_seg + SEGUNDOS_POR_DIA))
fi

# Interseção dos intervalos [noite] ∩ [lua acima do horizonte]
luz_lunar_inicio=$((nascer_lua_seg > noite_inicio ? nascer_lua_seg : noite_inicio))
luz_lunar_fim=$((por_lua_seg < noite_fim ? por_lua_seg : noite_fim))

if [ "$luz_lunar_fim" -gt "$luz_lunar_inicio" ]; then
    luz_lunar_segundos=$((luz_lunar_fim - luz_lunar_inicio))
    INFO_LUZ_LUNAR="Total: $(formata_duracao $luz_lunar_segundos)\n• $(formata_segundos_para_ampm $((luz_lunar_inicio % SEGUNDOS_POR_DIA))) às $(formata_segundos_para_ampm $((luz_lunar_fim % SEGUNDOS_POR_DIA))): $(formata_duracao $luz_lunar_segundos)"
    # Escuridão antes e depois da luz lunar
    escuridao1_inicio=$noite_inicio
    escuridao1_fim=$luz_lunar_inicio
    escuridao2_inicio=$luz_lunar_fim
    escuridao2_fim=$noite_fim
    escuridao1_segundos=$((escuridao1_fim - escuridao1_inicio))
    escuridao2_segundos=$((escuridao2_fim - escuridao2_inicio))
    total_escuridao_segundos=$(( (escuridao1_segundos > 0 ? escuridao1_segundos : 0) + (escuridao2_segundos > 0 ? escuridao2_segundos : 0) ))
    INFO_ESCURIDAO="Total: $(formata_duracao $total_escuridao_segundos)"
    [ "$escuridao1_segundos" -gt 0 ] && INFO_ESCURIDAO="${INFO_ESCURIDAO}\n• $(formata_segundos_para_ampm $((escuridao1_inicio % SEGUNDOS_POR_DIA))) às $(formata_segundos_para_ampm $((escuridao1_fim % SEGUNDOS_POR_DIA))): $(formata_duracao $escuridao1_segundos)"
    [ "$escuridao2_segundos" -gt 0 ] && INFO_ESCURIDAO="${INFO_ESCURIDAO}\n• $(formata_segundos_para_ampm $((escuridao2_inicio % SEGUNDOS_POR_DIA))) às $(formata_segundos_para_ampm $((escuridao2_fim % SEGUNDOS_POR_DIA))): $(formata_duracao $escuridao2_segundos)"
else
    # Toda a noite é escura
    escuridao_segundos=$((noite_fim - noite_inicio))
    INFO_ESCURIDAO="Total: $(formata_duracao $escuridao_segundos)\n• $(formata_segundos_para_ampm $((noite_inicio % SEGUNDOS_POR_DIA))) às $(formata_segundos_para_ampm $((noite_fim % SEGUNDOS_POR_DIA))): $(formata_duracao $escuridao_segundos)"
    INFO_LUZ_LUNAR="Total: 0h 0min\n• Sem luz lunar significativa"
fi

case "$fase_lua" in
    "New Moon")          FASE_LUA="🌑 Lua Nova" ;;
    "Waxing Crescent")   FASE_LUA="🌒 Crescente Côncava" ;;
    "First Quarter")     FASE_LUA="🌓 Quarto Crescente" ;;
    "Waxing Gibbous")    FASE_LUA="🌔 Gibosa Crescente" ;;
    "Full Moon")         FASE_LUA="🌕 Lua Cheia" ;;
    "Waning Gibbous")    FASE_LUA="🌖 Gibosa Minguante" ;;
    "Last Quarter")      FASE_LUA="🌗 Quarto Minguante" ;;
    "Waning Crescent")   FASE_LUA="🌘 Minguante Côncava" ;;
    *)                   FASE_LUA="🌙 $fase_lua" ;;
esac

MENSAGEM=$(cat << EOF

☀️ Informações Solares e Lunares - Uberlândia (Lite)
═══════════════════════
📅 Data: ${DATA_ATUAL}
🕐 Hora da consulta: ${HORA_ATUAL}

🌅 HORÁRIOS DO SOL:
• Nascer do sol: ${nascer_sol}
• Pôr do sol: ${por_sol}

⏱️ DURAÇÃO:
• Duração do dia: ${DURACAO_DIA}
• Duração da noite: ${DURACAO_NOITE}

🌙 Informações Lunares:
🌙 Fase: ${FASE_LUA}
• Iluminação: ${iluminacao_lua}%
• Nascer da lua: ${nascer_lua}
• Pôr da lua: ${por_lua}

🌃 TEMPO DE ESCURIDÃO:
$(echo -e "${INFO_ESCURIDAO}")

🌙 TEMPO DE LUZ LUNAR:
$(echo -e "${INFO_LUZ_LUNAR}")

📊 Fonte: v2.wttr.in
EOF
)

echo "$MENSAGEM"
log_message "=== Monitor Astro Lite Finalizado ==="
exit 0