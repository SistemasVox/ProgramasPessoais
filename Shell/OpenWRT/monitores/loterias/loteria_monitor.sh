#!/bin/sh

JOGOS_MONITORADOS="
megasena:80000000
maismilionaria:80000000
lotomania:8000000
quina:5000000
lotofacil:3000000
supersete:3000000
duplasena:3000000
diadesorte:3000000
"

DIRETORIO=$(cd "$(dirname "$0")" && pwd)
PREFIXO_SCRIPT=$(basename "$0" .sh)
ARQUIVO_LOG="$DIRETORIO/${PREFIXO_SCRIPT}.log"
API_BASE_URL="https://servicebus2.caixa.gov.br/portaldeloterias/api"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

mensagem_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$ARQUIVO_LOG"
}

enviar_notificacao() {
    local mensagem_base="$1"
    local sugestoes_fixas="$2"
    local tipo_jogo="$3"
    local nome_script=$(basename "$0")
    local DESTINATARIOS=""

    if [ ! -x "$DIRETORIO/send_whatsapp.sh" ]; then
        mensagem_log "Erro: send_whatsapp.sh não encontrado."
        return 1
    fi

    for numero in $DESTINATARIOS; do
        local conteudo_extra=""
        
        if [ -n "$tipo_jogo" ] && [ -x "$DIRETORIO/gerar_jogos_loteria.sh" ]; then
            conteudo_extra=$("$DIRETORIO/gerar_jogos_loteria.sh" "$tipo_jogo" 2>/dev/null)
        else
            conteudo_extra="$sugestoes_fixas"
        fi

        local msg_completa
        msg_completa=$(printf "[%s]\n%s\n\n%s" "$nome_script" "$mensagem_base" "$conteudo_extra")

        "$DIRETORIO/send_whatsapp.sh" "$numero" "$msg_completa" >/dev/null 2>&1
        sleep 1
    done
}

verifica_conexao() {
    ping -c 1 -W 2 "1.1.1.1" >/dev/null 2>&1
}

sanitizar_nome() {
    echo "$1" | tr -d ' \t\n\r' | tr 'A-Z' 'a-z'
}

validar_nome_jogo() {
    case "$1" in
        megasena|maismilionaria|lotofacil|quina|lotomania|duplasena|diadesorte|supersete)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

formatar_premio() {
    local valor_int=$(echo "$1" | cut -d'.' -f1)
    
    if [ "$valor_int" -ge 1000000 ]; then
        local milhoes=$((valor_int / 1000000))
        local resto=$((valor_int % 1000000))
        local centenas=$((resto / 100000))
        [ "$centenas" -gt 0 ] && echo "R$ ${milhoes},${centenas} Milhões" || echo "R$ ${milhoes} Milhões"
    elif [ "$valor_int" -ge 1000 ]; then
        echo "R$ $((valor_int / 1000)) Mil"
    else
        echo "R$ $valor_int"
    fi
}

converter_data() {
    local dia=$(echo "$1" | cut -d'/' -f1)
    local mes=$(echo "$1" | cut -d'/' -f2)
    local ano=$(echo "$1" | cut -d'/' -f3)
    echo "${ano}-${mes}-${dia}"
}

verificar_loterias() {
    local DATA_ATUAL=$(date '+%d/%m/%Y')
    local DATA_ATUAL_COMPARACAO=$(date '+%Y-%m-%d')
    
    mensagem_log "Iniciando verificação para a data: $DATA_ATUAL"

    echo "$JOGOS_MONITORADOS" | while read -r linha; do
        [ -z "$linha" ] && continue

        local JOGO_NOME=$(sanitizar_nome "$(echo "$linha" | cut -d':' -f1)")
        local VALOR_MINIMO=$(echo "$linha" | cut -d':' -f2)
        
        if ! validar_nome_jogo "$JOGO_NOME"; then
            mensagem_log "❌ Nome inválido: [$JOGO_NOME]. Pulando..."
            continue
        fi
        
        mensagem_log "Verificando [${JOGO_NOME}] (Mínimo: $(formatar_premio "$VALOR_MINIMO"))"
        
        local json_data=$(curl -s -L -H "User-Agent: $USER_AGENT" "${API_BASE_URL}/${JOGO_NOME}/")
        
        [ -z "$json_data" ] && mensagem_log "❌ ERRO: Falha ao obter dados para [${JOGO_NOME}]." && continue

        local data_proximo=$(echo "$json_data" | jq -r '.dataProximoConcurso // empty')
        local valor_estimado=$(echo "$json_data" | jq -r '.valorEstimadoProximoConcurso // 0')
        local prox_concurso=$(echo "$json_data" | jq -r '.numeroConcursoProximo // .proximoConcurso // empty')
        local nome_jogo_api=$(echo "$json_data" | jq -r '.tipoJogo // .nome // empty')
        
        [ -z "$data_proximo" ] || [ -z "$valor_estimado" ] && mensagem_log "⚠️ Dados incompletos para [${JOGO_NOME}]." && continue

        local data_proximo_comparacao=$(converter_data "$data_proximo")
        local valor_int=$(echo "$valor_estimado" | cut -d'.' -f1)
        
        if [ "$data_proximo_comparacao" = "$DATA_ATUAL_COMPARACAO" ] && [ "$valor_int" -ge "$VALOR_MINIMO" ]; then
            local PREMIO_FORMATADO=$(formatar_premio "$valor_estimado")
            
            mensagem_log "🎰 ALERTA: [${nome_jogo_api}] tem sorteio HOJE com prêmio ALTO!"
            
            local SUGESTOES_JOGOS=""
            if [ -f "$DIRETORIO/gerar_jogos_loteria.sh" ]; then
                SUGESTOES_JOGOS=$("$DIRETORIO/gerar_jogos_loteria.sh" "$JOGO_NOME" 2>/dev/null)
                [ $? -eq 0 ] && [ -n "$SUGESTOES_JOGOS" ] && SUGESTOES_JOGOS="
$SUGESTOES_JOGOS"
            fi
            
            local MENSAGEM=$(cat << EOF
🚨 Alerta de Loteria 🚨

Sorteio HOJE (${DATA_ATUAL})!

🎰 Jogo: ${nome_jogo_api}
💰 Prêmio Estimado: ${PREMIO_FORMATADO}
#️⃣ Concurso: ${prox_concurso}

⏰ Não esqueça de fazer sua aposta!
EOF
)
            enviar_notificacao "$MENSAGEM" "$SUGESTOES_JOGOS" "$JOGO_NOME"
        fi
        
        sleep 2
    done
}

mensagem_log "=== Monitor de Loterias Iniciado ==="

while ! verifica_conexao; do
    mensagem_log "🔌 Sem conexão. Tentando em 3s..."
    sleep 3
done
mensagem_log "✅ Conexão estabelecida."

verificar_loterias

mensagem_log "=== Monitor de Loterias Finalizado ==="
exit 0
