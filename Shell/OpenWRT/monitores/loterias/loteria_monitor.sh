#!/bin/sh

# Monitor de Loterias da Caixa (Mega-Sena, Lotofácil, Quina, etc.)
# Versão 2.3 - Compatível com BusyBox/OpenWrt
#
# Este script verifica a API da Caixa para sorteios no dia atual
# e envia notificações se o prêmio estimado for igual ou superior
# ao valor mínimo definido.
#
# Dependências: curl, jq

# --- CONFIGURAÇÕES DO USUÁRIO ---

# Defina os jogos para monitorar e o prêmio mínimo desejado (em números inteiros)
# Formato: "NOME_JOGO:VALOR_MINIMO"
# Nomes de jogo válidos (da API da Caixa):
# megasena, lotofacil, quina, lotomania, timemania, duplasena, federal,
# loteca, diadesorte, supersete, maismilionaria
#
# Exemplo: Monitorar Mega-Sena acima de 50 milhões E Lotofácil acima de 10 milhões
JOGOS_MONITORADOS="
megasena:80000000
maismilionaria:80000000
lotomania:8000000
quina:10000000
lotofacil:3000000
supersete:3000000
duplasena:3000000
diadesorte:3000000
"

# --- FIM DAS CONFIGURAÇÕES ---

DIRETORIO=$(cd "$(dirname "$0")" && pwd)
PREFIXO_SCRIPT=$(basename "$0" .sh)
ARQUIVO_LOG="$DIRETORIO/${PREFIXO_SCRIPT}.log"

# API Base da Caixa
API_BASE_URL="https://servicebus2.caixa.gov.br/portaldeloterias/api"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

DEBUG=0 # Ativar depuração (1=sim, 0=não)

# --- FUNÇÕES AUXILIARES ---

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

    # Assumindo que os scripts de envio existem no mesmo diretório
    if [ -f "$DIRETORIO/send_whatsapp.sh" ]; then
        "$DIRETORIO/send_whatsapp.sh" "$mensagem" >/dev/null 2>&1
    fi
    if [ -f "$DIRETORIO/send_whatsapp_2.sh" ]; then
        "$DIRETORIO/send_whatsapp_2.sh" "$mensagem" >/dev/null 2>&1
    fi

    mensagem_log "Notificação enviada."
}

verifica_conexao() {
    ping -c 1 -W 2 "1.1.1.1" >/dev/null 2>&1
}

# Sanitiza o nome do jogo de forma compatível com BusyBox
sanitizar_nome() {
    local nome="$1"
    # Remove espaços em branco (tabs, espaços, newlines)
    nome=$(echo "$nome" | tr -d ' \t\n\r')
    # Converte para minúsculas
    nome=$(echo "$nome" | tr 'A-Z' 'a-z')
    echo "$nome"
}

# Valida se o nome do jogo é suportado
validar_nome_jogo() {
    local jogo="$1"
    case "$jogo" in
        megasena|maismilionaria|lotofacil|quina|lotomania|duplasena|diadesorte|supersete)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# --- FUNÇÕES PRINCIPAIS DO SCRIPT ---

# Formata o número (prêmio) para um formato legível
formatar_premio() {
    local valor="$1"
    
    # Remove decimais se houver
    local valor_int=$(echo "$valor" | cut -d'.' -f1)
    
    # Adiciona "Milhões" ou "Mil" para facilitar
    if [ "$valor_int" -ge 1000000 ]; then
        local milhoes=$((valor_int / 1000000))
        local resto=$((valor_int % 1000000))
        local centenas=$((resto / 100000))
        if [ "$centenas" -gt 0 ]; then
            echo "R$ ${milhoes},${centenas} Milhões"
        else
            echo "R$ ${milhoes} Milhões"
        fi
    elif [ "$valor_int" -ge 1000 ]; then
        echo "R$ $((valor_int / 1000)) Mil"
    else
        echo "R$ $valor_int"
    fi
}

# Converte data DD/MM/YYYY para YYYY-MM-DD para comparação
converter_data() {
    local data_ddmmyyyy="$1"
    local dia=$(echo "$data_ddmmyyyy" | cut -d'/' -f1)
    local mes=$(echo "$data_ddmmyyyy" | cut -d'/' -f2)
    local ano=$(echo "$data_ddmmyyyy" | cut -d'/' -f3)
    echo "${ano}-${mes}-${dia}"
}

verificar_loterias() {
    # Data atual no formato DD/MM/YYYY (formato da API)
    local DATA_ATUAL=$(date '+%d/%m/%Y')
    local DATA_ATUAL_COMPARACAO=$(date '+%Y-%m-%d')
    
    mensagem_log "Iniciando verificação para a data: $DATA_ATUAL"
    debug_log "Data para comparação: $DATA_ATUAL_COMPARACAO"

    # Itera sobre a lista de jogos configurada
    echo "$JOGOS_MONITORADOS" | while read -r linha; do
        # Ignora linhas em branco
        [ -z "$linha" ] && continue

        # Extrai nome e valor
        local JOGO_NOME_RAW=$(echo "$linha" | cut -d':' -f1)
        local VALOR_MINIMO=$(echo "$linha" | cut -d':' -f2)
        
        # Sanitiza o nome do jogo de forma segura
        local JOGO_NOME=$(sanitizar_nome "$JOGO_NOME_RAW")
        
        # Debug: mostra bytes em hexadecimal se houver diferença
        if [ "$JOGO_NOME" != "$JOGO_NOME_RAW" ]; then
            debug_log "Nome sanitizado: [$JOGO_NOME_RAW] -> [$JOGO_NOME]"
        fi
        
        # Valida se o nome é suportado
        if ! validar_nome_jogo "$JOGO_NOME"; then
            mensagem_log "❌ Nome inválido: [$JOGO_NOME] (original: [$JOGO_NOME_RAW]). Pulando..."
            debug_log "Hex do nome original: $(echo -n "$JOGO_NOME_RAW" | hexdump -C | head -1)"
            continue
        fi
        
        mensagem_log "Verificando [${JOGO_NOME}] (Mínimo: $(formatar_premio "$VALOR_MINIMO"))"
        
        local API_URL="${API_BASE_URL}/${JOGO_NOME}/"
        
        # 1. Obter dados da API
        local json_data_raw
        json_data_raw=$(curl -s -L -H "User-Agent: $USER_AGENT" "$API_URL")
        
        if [ -z "$json_data_raw" ]; then
            mensagem_log "❌ ERRO: Falha ao obter dados da API para [${JOGO_NOME}]."
            continue
        fi

        debug_log "JSON recebido (primeiros 500 chars): $(echo "$json_data_raw" | head -c 500)"

        # 2. Extrair dados relevantes com jq
        local data_proximo=$(echo "$json_data_raw" | jq -r '.dataProximoConcurso // empty')
        local valor_estimado=$(echo "$json_data_raw" | jq -r '.valorEstimadoProximoConcurso // 0')
        local prox_concurso=$(echo "$json_data_raw" | jq -r '.numeroConcursoProximo // .proximoConcurso // empty')
        local nome_jogo_api=$(echo "$json_data_raw" | jq -r '.tipoJogo // .nome // empty')
        
        debug_log "Data próximo: $data_proximo | Valor: $valor_estimado | Concurso: $prox_concurso"
        
        # Verifica se conseguimos extrair os dados
        if [ -z "$data_proximo" ] || [ -z "$valor_estimado" ]; then
            mensagem_log "⚠️  Dados incompletos para [${JOGO_NOME}]. Pulando..."
            continue
        fi

        # 3. Converter data para comparação (YYYY-MM-DD)
        local data_proximo_comparacao=$(converter_data "$data_proximo")
        debug_log "Comparando datas: Atual=$DATA_ATUAL_COMPARACAO | Próximo=$data_proximo_comparacao"
        
        # 4. Verificar se o sorteio é HOJE e se o prêmio atende o mínimo
        # Conversão para inteiro para comparação numérica
        local valor_int=$(echo "$valor_estimado" | cut -d'.' -f1)
        
        if [ "$data_proximo_comparacao" = "$DATA_ATUAL_COMPARACAO" ]; then
            debug_log "✓ Sorteio é HOJE!"
            
            if [ "$valor_int" -ge "$VALOR_MINIMO" ]; then
                local PREMIO_FORMATADO=$(formatar_premio "$valor_estimado")
                
                mensagem_log "🎰 ALERTA: [${nome_jogo_api}] tem sorteio HOJE com prêmio ALTO!"
                
                # 5. Gerar sugestões de jogos aleatórios (com validação robusta)
                local SUGESTOES_JOGOS=""
                if [ -f "$DIRETORIO/gerar_jogos_loteria.sh" ]; then
                    debug_log "Chamando gerador com jogo: [$JOGO_NOME]"
                    
                    # Captura a saída do gerador
                    SUGESTOES_JOGOS=$("$DIRETORIO/gerar_jogos_loteria.sh" "$JOGO_NOME" 2>&1)
                    local exit_code=$?
                    
                    if [ $exit_code -eq 0 ]; then
                        if [ -n "$SUGESTOES_JOGOS" ]; then
                            SUGESTOES_JOGOS="
$SUGESTOES_JOGOS"
                        fi
                    else
                        mensagem_log "⚠️  Erro ao gerar jogos para [$JOGO_NOME]: $SUGESTOES_JOGOS"
                        SUGESTOES_JOGOS=""
                    fi
                fi
                
                # 6. Montar e enviar a notificação
                local MENSAGEM_WHATSAPP
                MENSAGEM_WHATSAPP=$(cat << EOF
🚨 Alerta de Loteria 🚨

Sorteio HOJE (${DATA_ATUAL})!

🎰 Jogo: ${nome_jogo_api}
💰 Prêmio Estimado: ${PREMIO_FORMATADO}
#️⃣ Concurso: ${prox_concurso}${SUGESTOES_JOGOS}

⏰ Não esqueça de fazer sua aposta!
EOF
)
                enviar_notificacao "$MENSAGEM_WHATSAPP"
            else
                debug_log "Prêmio ($valor_int) abaixo do mínimo ($VALOR_MINIMO). Sem alerta."
            fi
        else
            debug_log "Sorteio em outra data ($data_proximo). Sem alerta."
        fi
        
        # Pequena pausa para não sobrecarregar a API
        sleep 2
        
    done
}

# --- EXECUÇÃO DO SCRIPT ---

mensagem_log "=== Monitor de Loterias Iniciado ==="

while ! verifica_conexao; do
    mensagem_log "🔌 Sem conexão com a internet. Tentando novamente em 3 segundos..."
    sleep 3
done
mensagem_log "✅ Conexão com a internet estabelecida."

verificar_loterias

mensagem_log "=== Monitor de Loterias Finalizado ==="
exit 0
