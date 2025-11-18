#!/bin/sh

################################################################################
# Monitor de Loterias da Caixa Econômica Federal
################################################################################
#
# Descrição: Monitora sorteios de loterias e envia alertas via WhatsApp
#            quando o prêmio estimado atinge o valor mínimo configurado
#
# Autor: [Seu Nome/GitHub]
# Versão: 2.1.0
# Licença: MIT
#
# Compatibilidade:
#   - OpenWrt/BusyBox
#   - POSIX shell (/bin/sh, ash, dash)
#   - Linux embedded systems
#
# Dependências:
#   - curl (para chamadas à API)
#   - jq (para processar JSON)
#   - ping (para verificar conectividade)
#   - gerar_jogos_loteria.sh (opcional, para sugestões de jogos)
#   - send_whatsapp.sh (para enviar notificações)
#
# Uso:
#   ./loteria_monitor.sh
#
# Configuração via cron (executa diariamente às 8h):
#   0 8 * * * /root/home/monitores/loteria/loteria_monitor.sh
#
################################################################################

set -e  # Sai se houver erro

# --- CONFIGURAÇÕES DO USUÁRIO ---

# Defina os jogos para monitorar e o prêmio mínimo desejado (em números inteiros)
# Formato: "NOME_JOGO:VALOR_MINIMO"
#
# Nomes de jogo válidos (da API da Caixa):
#   megasena, lotofacil, quina, lotomania, timemania, duplasena, federal,
#   loteca, diadesorte, supersete, maismilionaria
#
# Valores em números inteiros (sem pontos ou vírgulas):
#   1.000.000 = 1000000
#   50.000.000 = 50000000
#
# Exemplo: Monitorar Mega-Sena acima de 80 milhões
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

# Constantes
VERSION="2.1.0"
DIRETORIO=$(cd "$(dirname "$0")" && pwd)
PREFIXO_SCRIPT=$(basename "$0" .sh)
ARQUIVO_LOG="$DIRETORIO/${PREFIXO_SCRIPT}.log"

# API da Caixa
API_BASE_URL="https://servicebus2.caixa.gov.br/portaldeloterias/api"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

# Modo de depuração (0=desativado, 1=ativado)
DEBUG=0

# --- FUNÇÕES DE LOG ---

# Registra mensagem no log com timestamp
# Argumentos: $1 = mensagem
mensagem_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$ARQUIVO_LOG"
}

# Registra mensagem de debug (somente se DEBUG=1)
# Argumentos: $1 = mensagem
debug_log() {
    [ "$DEBUG" -eq 1 ] && mensagem_log "[DEBUG] $1" || return 0
}

# --- FUNÇÕES DE COMUNICAÇÃO ---

# Envia notificação via WhatsApp
# Argumentos: $1 = mensagem a ser enviada
enviar_notificacao() {
    nome_script=$(basename "$0")
    mensagem=$(printf "[%s]\n%s" "$nome_script" "$1")
    
    mensagem_log "Enviando notificação via WhatsApp..."

    # Tenta enviar via scripts de WhatsApp (se existirem)
    notificacao_enviada=0
    
    if [ -f "$DIRETORIO/send_whatsapp.sh" ]; then
        if "$DIRETORIO/send_whatsapp.sh" "$mensagem" >/dev/null 2>&1; then
            notificacao_enviada=1
        fi
    fi
    
    if [ -f "$DIRETORIO/send_whatsapp_2.sh" ]; then
        if "$DIRETORIO/send_whatsapp_2.sh" "$mensagem" >/dev/null 2>&1; then
            notificacao_enviada=1
        fi
    fi
    
    if [ $notificacao_enviada -eq 1 ]; then
        mensagem_log "Notificação enviada com sucesso."
    else
        mensagem_log "⚠️  Aviso: Nenhum script de WhatsApp disponível ou falha no envio."
    fi
}

# Verifica conectividade com a internet
# Retorno: 0 se conectado, 1 se desconectado
verifica_conexao() {
    ping -c 1 -W 2 "1.1.1.1" >/dev/null 2>&1
}

# --- FUNÇÕES DE FORMATAÇÃO ---

# Formata valor monetário para formato legível
# Argumentos: $1 = valor em número inteiro
# Retorno: string formatada (ex: "R$ 50,5 Milhões")
formatar_premio() {
    valor="$1"
    
    # Remove decimais se houver
    valor_int=$(echo "$valor" | cut -d'.' -f1)
    
    # Formata baseado na magnitude
    if [ "$valor_int" -ge 1000000 ]; then
        milhoes=$((valor_int / 1000000))
        resto=$((valor_int % 1000000))
        centenas=$((resto / 100000))
        
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

# Converte data DD/MM/YYYY para YYYY-MM-DD
# Argumentos: $1 = data no formato DD/MM/YYYY
# Retorno: data no formato YYYY-MM-DD
converter_data() {
    data_ddmmyyyy="$1"
    dia=$(echo "$data_ddmmyyyy" | cut -d'/' -f1)
    mes=$(echo "$data_ddmmyyyy" | cut -d'/' -f2)
    ano=$(echo "$data_ddmmyyyy" | cut -d'/' -f3)
    echo "${ano}-${mes}-${dia}"
}

# --- FUNÇÃO PRINCIPAL ---

# Verifica todas as loterias configuradas
verificar_loterias() {
    DATA_ATUAL=$(date '+%d/%m/%Y')
    DATA_ATUAL_COMPARACAO=$(date '+%Y-%m-%d')
    
    mensagem_log "Iniciando verificação para a data: $DATA_ATUAL"
    debug_log "Data para comparação: $DATA_ATUAL_COMPARACAO"

    # Processa cada jogo configurado
    echo "$JOGOS_MONITORADOS" | while read -r linha; do
        # Ignora linhas em branco ou comentários
        [ -z "$linha" ] && continue
        echo "$linha" | grep -q "^#" && continue

        JOGO_NOME=$(echo "$linha" | cut -d':' -f1)
        VALOR_MINIMO=$(echo "$linha" | cut -d':' -f2)
        
        mensagem_log "Verificando [${JOGO_NOME}] (Mínimo: $(formatar_premio "$VALOR_MINIMO"))"
        
        API_URL="${API_BASE_URL}/${JOGO_NOME}/"
        
        # 1. Consultar API da Caixa
        json_data_raw=$(curl -s -L -H "User-Agent: $USER_AGENT" "$API_URL" --max-time 10)
        
        if [ -z "$json_data_raw" ]; then
            mensagem_log "❌ ERRO: Falha ao obter dados da API para [${JOGO_NOME}]."
            continue
        fi

        debug_log "JSON recebido (primeiros 500 chars): $(echo "$json_data_raw" | head -c 500)"

        # 2. Extrair dados do JSON com jq
        data_proximo=$(echo "$json_data_raw" | jq -r '.dataProximoConcurso // empty')
        valor_estimado=$(echo "$json_data_raw" | jq -r '.valorEstimadoProximoConcurso // 0')
        prox_concurso=$(echo "$json_data_raw" | jq -r '.numeroConcursoProximo // .proximoConcurso // empty')
        nome_jogo_api=$(echo "$json_data_raw" | jq -r '.tipoJogo // .nome // empty')
        
        debug_log "Data próximo: $data_proximo | Valor: $valor_estimado | Concurso: $prox_concurso"
        
        # Validar dados extraídos
        if [ -z "$data_proximo" ] || [ -z "$valor_estimado" ]; then
            mensagem_log "⚠️  Dados incompletos para [${JOGO_NOME}]. Pulando..."
            continue
        fi

        # 3. Converter e comparar datas
        data_proximo_comparacao=$(converter_data "$data_proximo")
        debug_log "Comparando datas: Atual=$DATA_ATUAL_COMPARACAO | Próximo=$data_proximo_comparacao"
        
        # 4. Verificar se é sorteio de hoje e se prêmio atende o mínimo
        valor_int=$(echo "$valor_estimado" | cut -d'.' -f1)
        
        if [ "$data_proximo_comparacao" = "$DATA_ATUAL_COMPARACAO" ]; then
            debug_log "✓ Sorteio é HOJE!"
            
            if [ "$valor_int" -ge "$VALOR_MINIMO" ]; then
                PREMIO_FORMATADO=$(formatar_premio "$valor_estimado")
                
                mensagem_log "🎰 ALERTA: [${nome_jogo_api}] tem sorteio HOJE com prêmio ALTO!"
                
                # 5. Gerar sugestões de jogos (se script disponível)
                SUGESTOES_JOGOS=""
                if [ -f "$DIRETORIO/gerar_jogos_loteria.sh" ]; then
                    debug_log "Gerando sugestões de jogos..."
                    SUGESTOES_JOGOS=$("$DIRETORIO/gerar_jogos_loteria.sh" "$JOGO_NOME" 2>/dev/null || echo "")
                    
                    if [ -n "$SUGESTOES_JOGOS" ]; then
                        SUGESTOES_JOGOS="
$SUGESTOES_JOGOS"
                        debug_log "Sugestões geradas com sucesso."
                    fi
                else
                    debug_log "Script gerar_jogos_loteria.sh não encontrado."
                fi
                
                # 6. Montar mensagem de notificação
                MENSAGEM_WHATSAPP=$(cat << EOF
🚨 Alerta de Loteria 🚨

Sorteio HOJE (${DATA_ATUAL})!

🎰 Jogo: ${nome_jogo_api}
💰 Prêmio Estimado: ${PREMIO_FORMATADO}
#️⃣ Concurso: ${prox_concurso}${SUGESTOES_JOGOS}

⏰ Não esqueça de fazer sua aposta!
EOF
)
                
                # 7. Enviar notificação
                enviar_notificacao "$MENSAGEM_WHATSAPP"
            else
                debug_log "Prêmio ($valor_int) abaixo do mínimo ($VALOR_MINIMO). Sem alerta."
            fi
        else
            debug_log "Sorteio em outra data ($data_proximo). Sem alerta."
        fi
        
        # Pausa entre requisições para não sobrecarregar a API
        sleep 2
        
    done
}

# --- EXECUÇÃO PRINCIPAL ---

mensagem_log "=== Monitor de Loterias Iniciado (v${VERSION}) ==="

# Aguarda conexão com a internet
tentativas_conexao=0
while ! verifica_conexao; do
    mensagem_log "🔌 Sem conexão com a internet. Tentando novamente em 3 segundos..."
    sleep 3
    tentativas_conexao=$((tentativas_conexao + 1))
    
    # Desiste após 10 tentativas (30 segundos)
    if [ $tentativas_conexao -ge 10 ]; then
        mensagem_log "❌ ERRO: Não foi possível estabelecer conexão com a internet após 10 tentativas."
        exit 1
    fi
done

mensagem_log "✅ Conexão com a internet estabelecida."

# Executa verificação das loterias
verificar_loterias

mensagem_log "=== Monitor de Loterias Finalizado ==="
exit 0