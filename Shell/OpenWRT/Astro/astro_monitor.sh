#!/bin/sh

# ========================================
# Monitor Astro (Sol & Lua) para OpenWrt - Lógica fiel, robusta e tratamento melhorado de "Sem pôr da lua"
# ========================================

# --- Diretório e Arquivo de Log ---
DIRETORIO=$(cd "$(dirname "$0")" && pwd)
PREFIXO_SCRIPT=$(basename "$0" .sh)
ARQUIVO_LOG="$DIRETORIO/${PREFIXO_SCRIPT}.log"

# --- Configuração ---
LATITUDE="-18.9113"
LONGITUDE="-48.2622"
FUSO_HORARIO=-3  # Horário de Brasília (BRT)

# --- APIs ---
API_URL_SOL="https://api.sunrise-sunset.org/json?lat=${LATITUDE}&lng=${LONGITUDE}&formatted=0&date="
API_URL_LUA="http://v2.wttr.in/Uberlandia?format=j1"

# --- Constantes ---
SEGUNDOS_POR_HORA=3600
SEGUNDOS_POR_MINUTO=60
HORAS_POR_DIA=24
SEGUNDOS_POR_DIA=$((HORAS_POR_DIA * SEGUNDOS_POR_HORA))
TEMPO_PING=2
TEMPO_SOL=10
TEMPO_LUA=15
TENTATIVA_ESPERA=30
ESPERA_CALCULO=2
MAX_TENTATIVAS_LUA=5

# --- Funções ---

mensagem_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$ARQUIVO_LOG"
}

enviar_notificacao() {
    local nome_script mensagem
    nome_script=$(basename "$0")
    mensagem=$(printf "[%s]\n%s" "$nome_script" "$1")
    mensagem_log "Enviando notificação via WhatsApp..."
    # Descomente as linhas abaixo para ativar o envio de notificações
    # "$DIRETORIO/send_whatsapp.sh" "$mensagem" >/dev/null 2>&1
    # "$DIRETORIO/send_whatsapp_2.sh" "$mensagem" >/dev/null 2>&1
    mensagem_log "Notificação enviada."
}

verifica_conexao() {
    ping -c 1 -W $TEMPO_PING "1.1.1.1" >/dev/null 2>&1
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
        hora_local=$((hora_local + HORAS_POR_DIA))
        local parte_data_local=$(date -d "$parte_data -1 day" "+%Y-%m-%d")
        echo "$parte_data_local $(printf "%02d" $hora_local):$resto_hora"
    elif [ "$hora_local" -ge "$HORAS_POR_DIA" ]; then
        hora_local=$((hora_local - HORAS_POR_DIA))
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

# ========================================
# Programa Principal
# ========================================

mensagem_log "=== Monitor Astro Iniciado ==="
. /usr/share/libubox/jshn.sh

# --- Verificação de Conexão com a Internet ---
while ! verifica_conexao; do
    mensagem_log "🔌 Sem conexão com a internet. Tentando novamente em $TENTATIVA_ESPERA segundos..."
    sleep $TENTATIVA_ESPERA
done
mensagem_log "✅ Conexão com a internet estabelecida."

# --- Processamento Solar ---
mensagem_log "☀️ Buscando dados solares..."
json_sol_raw=$(curl -s -m $TEMPO_SOL "${API_URL_SOL}today")
if ! echo "$json_sol_raw" | grep -q '"status":"OK"'; then
    mensagem_log "❌ ERRO: Falha ao obter dados da API do Sol."
    enviar_notificacao "Erro ao obter dados solares. O script será encerrado."
    exit 1
fi

json_load "$json_sol_raw"
json_select results
json_get_vars sunrise sunset solar_noon day_length civil_twilight_begin civil_twilight_end
json_select ..

nascer_sol_utc=$(echo "$sunrise" | sed 's/T/ /; s/+00:00//')
por_sol_utc=$(echo "$sunset" | sed 's/T/ /; s/+00:00//')
meio_dia_utc=$(echo "$solar_noon" | sed 's/T/ /; s/+00:00//')
primeira_luz_utc=$(echo "$civil_twilight_begin" | sed 's/T/ /; s/+00:00//')
ultima_luz_utc=$(echo "$civil_twilight_end" | sed 's/T/ /; s/+00:00//')

nascer_sol_local=$(utc_para_local_manual "$nascer_sol_utc")
por_sol_local=$(utc_para_local_manual "$por_sol_utc")
meio_dia_local=$(utc_para_local_manual "$meio_dia_utc")
primeira_luz_local=$(utc_para_local_manual "$primeira_luz_utc")
ultima_luz_local=$(utc_para_local_manual "$ultima_luz_utc")

NASCER_SOL=$(date -d "$nascer_sol_local" "+%I:%M:%S %p")
POR_SOL=$(date -d "$por_sol_local" "+%I:%M:%S %p")
MEIO_DIA=$(date -d "$meio_dia_local" "+%I:%M:%S %p")
PRIMEIRA_LUZ=$(date -d "$primeira_luz_local" "+%I:%M:%S %p")
ULTIMA_LUZ=$(date -d "$ultima_luz_local" "+%I:%M:%S %p")
DURACAO_DIA=$(formata_duracao "$day_length")
DATA_ATUAL=$(date '+%d/%m/%Y')
HORA_ATUAL=$(date '+%H:%M:%S')
mensagem_log "✅ Dados solares processados."

# --- Processamento Lunar ("Sem pôr da lua" tratado) ---
mensagem_log "🌙 Buscando dados lunares..."
TENTATIVA_LUA=0
fase_lua=""
por_lua=""
nascer_lua=""
por_lua_amanha=""

while [ -z "$fase_lua" ] && [ "$TENTATIVA_LUA" -lt "$MAX_TENTATIVAS_LUA" ]; do
    TENTATIVA_LUA=$((TENTATIVA_LUA + 1))
    if [ "$TENTATIVA_LUA" -gt 1 ]; then
        mensagem_log " Tentativa ${TENTATIVA_LUA}/${MAX_TENTATIVAS_LUA} para a API da Lua. Resposta anterior inválida ou falha no download. Aguardando $TENTATIVA_ESPERA segundos..."
        sleep $TENTATIVA_ESPERA
    fi

    json_lua_raw=$(curl -s -m $TEMPO_LUA "$API_URL_LUA")
    if [ -n "$json_lua_raw" ]; then
        json_load "$json_lua_raw"
        json_select weather
        json_select 1
        json_select astronomy
        json_select 1
        json_get_vars moon_phase moon_illumination moonrise moonset
        json_select ..; json_select ..; json_select ..; json_select ..
        # Se por_lua for "No moonset", tenta pegar do próximo dia!
        if [ "$moonset" = "No moonset" ]; then
            json_select weather
            json_select 2
            json_select astronomy
            json_select 1
            json_get_var por_lua_amanha moonset
            json_select ..; json_select ..; json_select ..; json_select ..
            por_lua_amanha_24h=$(converter_para_24h "$por_lua_amanha")
            por_lua_amanha_seg=$(hora_para_segundos "$por_lua_amanha_24h")
            if [ "$por_lua_amanha_seg" -le $((12 * 3600)) ]; then
                moonset="$por_lua_amanha"
            fi
        fi
    fi
done

if [ -z "$moon_phase" ]; then
    mensagem_log "❌ ERRO: Falha ao obter e processar dados da API da Lua após $MAX_TENTATIVAS_LUA tentativas."
    enviar_notificacao "Erro crítico ao obter dados lunares após $MAX_TENTATIVAS_LUA tentativas. O script será encerrado."
    exit 1
fi

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

# --- Cálculo fiel de escuridão e luz lunar ---
mensagem_log "⏳ Calculando tempo de escuridão e luz lunar..."
sleep $ESPERA_CALCULO

INFO_ESCURIDAO="Dados insuficientes para cálculo."
INFO_LUZ_LUNAR="Dados insuficientes para cálculo."

if [ -n "$ULTIMA_LUZ" ] && [ -n "$PRIMEIRA_LUZ" ] && [ -n "$moonrise" ] && [ -n "$moonset" ] && [ "$moonset" != "No moonset" ]; then
    ultima_luz_seg=$(hora_para_segundos "$(converter_para_24h "$ULTIMA_LUZ")")
    primeira_luz_seg=$(hora_para_segundos "$(converter_para_24h "$PRIMEIRA_LUZ")")
    if [ "$primeira_luz_seg" -le "$ultima_luz_seg" ]; then
        noite_fim=$((primeira_luz_seg + SEGUNDOS_POR_DIA))
    else
        noite_fim=$primeira_luz_seg
    fi
    noite_inicio=$ultima_luz_seg

    nascer_lua_seg=$(hora_para_segundos "$(converter_para_24h "$moonrise")")
    por_lua_seg=$(hora_para_segundos "$(converter_para_24h "$moonset")")
    [ "$por_lua_seg" -le "$nascer_lua_seg" ] && por_lua_seg=$((por_lua_seg + SEGUNDOS_POR_DIA))

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
fi

mensagem_log "✅ Cálculo de escuridão e luz lunar finalizado."

# --- Exibir informações e Notificar ---
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