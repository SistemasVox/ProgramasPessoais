#!/bin/sh

# Monitor Astro (Sol & Lua) para OpenWrt usando jq - Versão totalmente corrigida

DIRETORIO=$(cd "$(dirname "$0")" && pwd)
PREFIXO_SCRIPT=$(basename "$0" .sh)
ARQUIVO_LOG="$DIRETORIO/${PREFIXO_SCRIPT}.log"

LATITUDE="-18.9113"
LONGITUDE="-48.2622"
FUSO_HORARIO=-3  # Horário de Brasília (BRT)

API_URL_SOL="https://api.sunrise-sunset.org/json?lat=${LATITUDE}&lng=${LONGITUDE}&formatted=0&date=today"
API_URL_LUA="https://v2.wttr.in/Uberlandia?format=j1"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

SEGUNDOS_POR_HORA=3600
SEGUNDOS_POR_MINUTO=60
HORAS_POR_DIA=24
SEGUNDOS_POR_DIA=$((HORAS_POR_DIA * SEGUNDOS_POR_HORA))
DEBUG=1  # Ativar depuração

mensagem_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$ARQUIVO_LOG"
}

debug_log() {
    [ "$DEBUG" -eq 1 ] && mensagem_log "[DEBUG] $1" || return 0
}

enviar_notificacao() {
    local nome_script mensagem
    nome_script=$(basename "$0")
    mensagem=$(printf "[%s]\n%s" "$nome_script" "$1")
    mensagem_log "Enviando notificação via WhatsApp..."
    "$DIRETORIO/send_whatsapp.sh" "$mensagem" >/dev/null 2>&1
    "$DIRETORIO/send_whatsapp_2.sh" "$mensagem" >/dev/null 2>&1
    mensagem_log "Notificação enviada."
}

verifica_conexao() {
    ping -c 1 -W 2 "1.1.1.1" >/dev/null 2>&1
}

utc_para_local_manual() {
    local utc_str="$1"
    [ -z "$utc_str" ] && echo "" && return
    local parte_data=$(echo "$utc_str" | cut -d' ' -f1)
    local parte_hora=$(echo "$utc_str" | cut -d' ' -f2)
    local hora=$(echo "$parte_hora" | cut -d: -f1 | sed 's/^0*//')
    local resto_hora=$(echo "$parte_hora" | cut -d: -f2,3)
    local hora_local=$((hora + FUSO_HORARIO))
    if [ "$hora_local" -lt 0 ]; then
        hora_local=$((hora_local + 24))
        local parte_data_local=$(date -d "$parte_data -1 day" "+%Y-%m-%d")
        echo "$parte_data_local $(printf "%02d" $hora_local):$resto_hora"
    elif [ "$hora_local" -ge 24 ]; then
        hora_local=$((hora_local - 24))
        local parte_data_local=$(date -d "$parte_data +1 day" "+%Y-%m-%d")
        echo "$parte_data_local $(printf "%02d" $hora_local):$resto_hora"
    else
        echo "$parte_data $(printf "%02d" $hora_local):$resto_hora"
    fi
}

converter_para_24h() {
    local horario="$1"
    [ -z "$horario" ] && echo "" && return
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
    local s=$(echo "$hora_24h" | cut -d: -f3 | sed 's/^0*//')
    [ -z "$h" ] && h=0
    [ -z "$m" ] && m=0
    [ -z "$s" ] && s=0
    echo $(( (h * SEGUNDOS_POR_HORA) + (m * SEGUNDOS_POR_MINUTO) + s ))
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

mensagem_log "=== Monitor Astro Iniciado ==="

while ! verifica_conexao; do
    mensagem_log "🔌 Sem conexão com a internet. Tentando novamente em 3 segundos..."
    sleep 3
done
mensagem_log "✅ Conexão com a internet estabelecida."

# --- SOL ---
mensagem_log "☀️ Buscando dados solares..."
json_sol_raw=$(curl -s -L -H "User-Agent: $USER_AGENT" "$API_URL_SOL")

status=$(echo "$json_sol_raw" | jq -r '.status')
if [ "$status" != "OK" ]; then
    mensagem_log "❌ ERRO: Falha ao obter dados da API do Sol."
    enviar_notificacao "Erro ao obter dados solares. O script será encerrado."
    exit 1
fi

sunrise=$(echo "$json_sol_raw" | jq -r '.results.sunrise' | sed 's/T/ /; s/+00:00//')
sunset=$(echo "$json_sol_raw" | jq -r '.results.sunset' | sed 's/T/ /; s/+00:00//')
solar_noon=$(echo "$json_sol_raw" | jq -r '.results.solar_noon' | sed 's/T/ /; s/+00:00//')
civil_twilight_begin=$(echo "$json_sol_raw" | jq -r '.results.civil_twilight_begin' | sed 's/T/ /; s/+00:00//')
civil_twilight_end=$(echo "$json_sol_raw" | jq -r '.results.civil_twilight_end' | sed 's/T/ /; s/+00:00//')
day_length=$(echo "$json_sol_raw" | jq -r '.results.day_length')

nascer_sol_local=$(utc_para_local_manual "$sunrise")
por_sol_local=$(utc_para_local_manual "$sunset")
meio_dia_local=$(utc_para_local_manual "$solar_noon")
primeira_luz_local=$(utc_para_local_manual "$civil_twilight_begin")
ultima_luz_local=$(utc_para_local_manual "$civil_twilight_end")

NASCER_SOL=$(date -d "$nascer_sol_local" "+%I:%M:%S %p")
POR_SOL=$(date -d "$por_sol_local" "+%I:%M:%S %p")
MEIO_DIA=$(date -d "$meio_dia_local" "+%I:%M:%S %p")
PRIMEIRA_LUZ=$(date -d "$primeira_luz_local" "+%I:%M:%S %p")
ULTIMA_LUZ=$(date -d "$ultima_luz_local" "+%I:%M:%S %p")
DURACAO_DIA=$(formata_duracao "$day_length")
DATA_ATUAL=$(date '+%d/%m/%Y')
HORA_ATUAL=$(date '+%H:%M:%S')
mensagem_log "✅ Dados solares processados."

# --- LUA ---
mensagem_log "🌙 Buscando dados lunares..."
json_lua_raw=$(curl -s -L -H "User-Agent: $USER_AGENT" "$API_URL_LUA")
echo "$json_lua_raw" > /tmp/resposta_lua.txt

moon_phase=$(echo "$json_lua_raw" | jq -r '.weather[0].astronomy[0].moon_phase')
moon_illumination=$(echo "$json_lua_raw" | jq -r '.weather[0].astronomy[0].moon_illumination')
moonrise=$(echo "$json_lua_raw" | jq -r '.weather[0].astronomy[0].moonrise')
moonset=$(echo "$json_lua_raw" | jq -r '.weather[0].astronomy[0].moonset')

debug_log "Lua nasce: $moonrise, Lua se põe: $moonset"

FASE_LUA=""
case "$moon_phase" in
    "New Moon")          FASE_LUA="🌑 Lua Nova" ;;
    "Waxing Crescent")   FASE_LUA="🌒 Crescente Côncava" ;;
    "First Quarter")     FASE_LUA="🌓 Quarto Crescente" ;;
    "Waxing Gibbous")    FASE_LUA="🌔 Gibosa Crescente" ;;
    "Full Moon")         FASE_LUA="🌕 Lua Cheia" ;;
    "Waning Gibbous")    FASE_LUA="🌖 Gibosa Minguante" ;;
    "Last Quarter")      FASE_LUA="🌗 Quarto Minguante" ;;
    "Waning Crescent")   FASE_LUA="🌘 Minguante Côncava" ;;
    *)                   FASE_LUA="🌙 $moon_phase" ;;
esac
mensagem_log "✅ Dados lunares processados."

mensagem_log "⏳ Calculando tempo de escuridão e luz lunar..."
sleep 2

INFO_ESCURIDAO="Dados insuficientes para cálculo."
INFO_LUZ_LUNAR="Dados insuficientes para cálculo."

if [ -n "$ULTIMA_LUZ" ] && [ -n "$PRIMEIRA_LUZ" ] && [ -n "$moonrise" ] && [ -n "$moonset" ] && [ "$moonset" != "No moonset" ]; then
    # Conversão para segundos
    ultima_luz_seg=$(hora_para_segundos "$(converter_para_24h "$ULTIMA_LUZ")")
    primeira_luz_seg=$(hora_para_segundos "$(converter_para_24h "$PRIMEIRA_LUZ")")
    nascer_lua_seg=$(hora_para_segundos "$(converter_para_24h "$moonrise")")
    por_lua_seg=$(hora_para_segundos "$(converter_para_24h "$moonset")")
    
    debug_log "Segundos - Última luz: $ultima_luz_seg, Primeira luz: $primeira_luz_seg, Nascer lua: $nascer_lua_seg, Pôr lua: $por_lua_seg"
    
    # Ajustar para a noite que cruza dias
    if [ "$primeira_luz_seg" -le "$ultima_luz_seg" ]; then
        noite_fim=$((primeira_luz_seg + SEGUNDOS_POR_DIA))
        debug_log "Noite cruza dias: primeira luz + 24h = $noite_fim"
    else
        noite_fim=$primeira_luz_seg
        debug_log "Noite no mesmo dia: $noite_fim"
    fi
    noite_inicio=$ultima_luz_seg
    
    # Ajustar para o nascer/por da lua que cruza dias
    if [ "$por_lua_seg" -le "$nascer_lua_seg" ]; then
        por_lua_seg=$((por_lua_seg + SEGUNDOS_POR_DIA))
        debug_log "Lua cruza dias: pôr lua + 24h = $por_lua_seg"
    fi
    
    # Se a lua nascer antes da noite e se pôr depois, ajuste para o dia seguinte
    if [ "$nascer_lua_seg" -lt "$noite_inicio" ] && [ "$por_lua_seg" -lt "$noite_inicio" ]; then
        nascer_lua_seg=$((nascer_lua_seg + SEGUNDOS_POR_DIA))
        por_lua_seg=$((por_lua_seg + SEGUNDOS_POR_DIA))
        debug_log "Lua do dia seguinte: nascer = $nascer_lua_seg, por = $por_lua_seg"
    fi
    
    debug_log "Intervalo noite: $noite_inicio até $noite_fim ($(formata_duracao $((noite_fim - noite_inicio))))"
    debug_log "Intervalo lua: $nascer_lua_seg até $por_lua_seg ($(formata_duracao $((por_lua_seg - nascer_lua_seg))))"
    
    # CORREÇÃO: Verificar interseção corretamente
    tem_luz_lunar=0
    
    # Se a lua nasce durante a noite
    if [ "$nascer_lua_seg" -ge "$noite_inicio" ] && [ "$nascer_lua_seg" -lt "$noite_fim" ]; then
        tem_luz_lunar=1
        debug_log "Caso 1: Lua nasce durante a noite"
    fi
    
    # Se a lua se põe durante a noite
    if [ "$por_lua_seg" -gt "$noite_inicio" ] && [ "$por_lua_seg" -le "$noite_fim" ]; then
        tem_luz_lunar=1
        debug_log "Caso 2: Lua se põe durante a noite"
    fi
    
    # Se a lua abrange toda a noite (nasce antes e se põe depois)
    if [ "$nascer_lua_seg" -le "$noite_inicio" ] && [ "$por_lua_seg" -ge "$noite_fim" ]; then
        tem_luz_lunar=1
        debug_log "Caso 3: Lua abrange toda a noite"
    fi
    
    if [ "$tem_luz_lunar" -eq 1 ]; then
        # Calcular período exato de luz lunar durante a noite
        luz_lunar_inicio=$noite_inicio
        [ "$nascer_lua_seg" -gt "$noite_inicio" ] && luz_lunar_inicio=$nascer_lua_seg
        
        luz_lunar_fim=$noite_fim
        [ "$por_lua_seg" -lt "$noite_fim" ] && luz_lunar_fim=$por_lua_seg
        
        luz_lunar_segundos=$((luz_lunar_fim - luz_lunar_inicio))
        debug_log "Luz lunar: $luz_lunar_inicio até $luz_lunar_fim = $(formata_duracao $luz_lunar_segundos)"
        
        INFO_LUZ_LUNAR="Total: $(formata_duracao $luz_lunar_segundos)\n• $(formata_segundos_para_ampm $((luz_lunar_inicio % SEGUNDOS_POR_DIA))) às $(formata_segundos_para_ampm $((luz_lunar_fim % SEGUNDOS_POR_DIA))): $(formata_duracao $luz_lunar_segundos)"
        
        # Calcular período de escuridão (sem lua)
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
        # Sem interseção: toda a noite é escura
        debug_log "Sem interseção: lua não cruza período noturno"
        escuridao_segundos=$((noite_fim - noite_inicio))
        INFO_ESCURIDAO="Total: $(formata_duracao $escuridao_segundos)\n• $(formata_segundos_para_ampm $((noite_inicio % SEGUNDOS_POR_DIA))) às $(formata_segundos_para_ampm $((noite_fim % SEGUNDOS_POR_DIA))): $(formata_duracao $escuridao_segundos)"
        INFO_LUZ_LUNAR="Total: 0h 0min\n• Sem luz lunar significativa"
    fi
fi

mensagem_log "✅ Cálculo de escuridão e luz lunar finalizado."

CORPO_MENSAGEM=$(cat << EOF

☀️ Informações Solares - Uberlândia
═══════════════════════
📅 Data: ${DATA_ATUAL}
🕐 Hora da consulta: ${HORA_ATUAL}

🌅 HORÁRIOS DO SOL:
• Primeira luz: ${PRIMEIRA_LUZ}
• Nascer do sol: ${NASCER_SOL}
• Meio-dia solar: ${MEIO_DIA}
• Pôr do sol: ${POR_SOL}
• Última luz: ${ULTIMA_LUZ}

⏱️ DURAÇÃO:
• Duração do dia: ${DURACAO_DIA}

🌙 Informações Lunares - Uberlândia
╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋╋
🌙 FASE DA LUA:
• Fase atual: ${FASE_LUA}
• Iluminação: ${moon_illumination}%

🌇 HORÁRIOS DA LUA (horário local):
• Nascer da lua: ${moonrise}
• Pôr da lua: ${moonset}

🌃 TEMPO DE ESCURIDÃO:
$(echo -e "${INFO_ESCURIDAO}")
  (Intervalos sem luz solar ou lunar)

🌙 TEMPO DE LUZ LUNAR:
$(echo -e "${INFO_LUZ_LUNAR}")
  (Intervalos noturnos com luz da lua)

───────────────────
📊 Fontes: sunrise-sunset.org, v2.wttr.in
✅ Dados obtidos com sucesso!
EOF
)

echo "$CORPO_MENSAGEM"
enviar_notificacao "$CORPO_MENSAGEM"
mensagem_log "=== Monitor Astro Finalizado ==="
exit 0