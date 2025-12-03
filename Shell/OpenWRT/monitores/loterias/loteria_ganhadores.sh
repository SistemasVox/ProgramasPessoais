#!/bin/sh

JOGOS="megasena maismilionaria lotomania quina lotofacil supersete duplasena diadesorte"

DIRETORIO=$(cd "$(dirname "$0")" && pwd)
PREFIXO_SCRIPT=$(basename "$0" .sh)
ARQUIVO_LOG="$DIRETORIO/${PREFIXO_SCRIPT}.log"
API_BASE_URL="https://servicebus2.caixa.gov.br/portaldeloterias/api"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
DESTINATARIOS="553491509513 553496668954 553496620667 553491139301 553598949320 553491053894 553492345200 553491149891"
# DESTINATARIOS="553491509513"

# Configurações de timeout
MAX_TENTATIVAS=155
INTERVALO_TENTATIVA=60

mensagem_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$ARQUIVO_LOG"
}

verifica_conexao() {
    ping -c 1 -W 2 "1.1.1.1" >/dev/null 2>&1
}

# Verifica se a data do concurso é de hoje
eh_data_atual() {
    local data_concurso="$1"
    
    # Data de hoje no formato DD/MM/YYYY (mesmo formato que a API retorna)
    local data_hoje=$(date '+%d/%m/%Y')
    
    # Compara as datas
    if [ "$data_concurso" = "$data_hoje" ]; then
        return 0
    fi
    
    # Fallback: converte ambas para timestamp e compara apenas o dia
    local timestamp_concurso=$(date -d "$(echo $data_concurso | awk -F'/' '{print $3"-"$2"-"$1}')" '+%Y%m%d' 2>/dev/null)
    local timestamp_hoje=$(date '+%Y%m%d')
    
    [ "$timestamp_concurso" = "$timestamp_hoje" ]
}

enviar_whatsapp() {
    local mensagem="$1"
    local nome_script=$(basename "$0")
    
    if [ ! -x "$DIRETORIO/send_whatsapp.sh" ]; then
        mensagem_log "Erro: send_whatsapp.sh não encontrado."
        return 1
    fi

    for numero in $DESTINATARIOS; do
        local msg_completa=$(printf "[%s]\n%s" "$nome_script" "$mensagem")
        "$DIRETORIO/send_whatsapp.sh" "$numero" "$msg_completa" >/dev/null 2>&1
        sleep 1
    done
}

formatar_valor() {
    local valor_int=$(echo "$1" | cut -d'.' -f1)
    
    if [ "$valor_int" -ge 1000000 ]; then
        local milhoes=$((valor_int / 1000000))
        local resto=$((valor_int % 1000000))
        local centenas=$((resto / 100000))
        [ "$centenas" -gt 0 ] && echo "${milhoes},${centenas}M" || echo "${milhoes}M"
    elif [ "$valor_int" -ge 1000 ]; then
        echo "$((valor_int / 1000))k"
    else
        echo "$valor_int"
    fi
}

formatar_numeros() {
    local numeros="$1"
    echo "$numeros" | tr '\n' ' ' | sed 's/ $//' | sed 's/ / - /g'
}

analisar_jogo() {
    local jogo="$1"
    
    local json=$(curl -s -L -H "User-Agent: $USER_AGENT" "${API_BASE_URL}/${jogo}/")
    
    if [ -z "$json" ]; then
        return 1
    fi
    
    local nome=$(echo "$json" | jq -r '.tipoJogo // .nome // empty')
    local concurso=$(echo "$json" | jq -r '.numero // empty')
    local data=$(echo "$json" | jq -r '.dataApuracao // .dataSorteio // empty')
    local ganhadores=$(echo "$json" | jq -r '.listaRateioPremio[0].numeroDeGanhadores // 0')
    
    if [ -z "$nome" ] || [ -z "$concurso" ]; then
        return 1
    fi
    
    # Verifica se a data é de hoje
    if ! eh_data_atual "$data"; then
        mensagem_log "📅 [$jogo] Data do concurso: $data | Hoje: $(date '+%d/%m/%Y') - API não atualizou"
        return 4  # Data antiga - API não atualizou
    fi
    
    # Só processa se teve ganhadores
    if [ "$ganhadores" -gt 0 ]; then
        local valor_total=$(echo "$json" | jq -r '.listaRateioPremio[0].valorPremio // 0')
        local numeros=$(echo "$json" | jq -r '.listaDezenas[]?' | sort -n)
        local numeros_formatados=$(formatar_numeros "$numeros")
        
        local cidades=$(echo "$json" | jq -r '
            .listaMunicipioUFGanhadores[]? | 
            select(.posicao == 1) | 
            "\(.municipio)/\(.uf)"
        ' | head -10)
        
        local mensagem="┌─────────────────────────────────┐
🎰 $nome - Concurso $concurso
📅 $data

🏆 PRÊMIO PRINCIPAL:
   💥 $ganhadores ganhador(es)
   💰 R$ $(formatar_valor "$valor_total") cada

🎲 NÚMEROS: $numeros_formatados"
        
        if [ -n "$cidades" ]; then
            local total_cidades=$(echo "$cidades" | wc -l)
            mensagem="${mensagem}

📍 CIDADES ($total_cidades):"
            
            while IFS= read -r cidade; do
                mensagem="${mensagem}
   • $cidade"
            done << EOF
$cidades
EOF
        fi
        
        echo "$mensagem"
        return 0
    fi
    
    # Retorna o nome do jogo para lista de sem ganhadores
    echo "$nome"
    return 2  # Sem ganhadores
}

# ============================================
# INÍCIO DO SCRIPT PRINCIPAL
# ============================================

mensagem_log "=== Análise de Ganhadores Iniciada ==="

# Verifica conexão
while ! verifica_conexao; do
    mensagem_log "🔌 Sem conexão. Tentando em 3s..."
    sleep 3
done
mensagem_log "✅ Conexão estabelecida."

tentativa=1

while [ $tentativa -le $MAX_TENTATIVAS ]; do
    mensagem_completa=""
    tem_ganhadores=0
    tem_data_antiga=0
    jogos_sem_ganhadores=""
    
    for jogo in $JOGOS; do
        mensagem_log "Verificando [$jogo]..."
        
        resultado=$(analisar_jogo "$jogo")
        status=$?
        
        if [ $status -eq 0 ]; then
            # Encontrou ganhador novo
            [ $tem_ganhadores -eq 0 ] && mensagem_completa="🏆 GANHADORES RECENTES 🏆

"
            mensagem_completa="${mensagem_completa}${resultado}

"
            tem_ganhadores=$((tem_ganhadores + 1))
            
        elif [ $status -eq 2 ]; then
            # Sem ganhadores - adiciona à lista
            jogos_sem_ganhadores="${jogos_sem_ganhadores}   • $resultado
"
            
        elif [ $status -eq 4 ]; then
            # Data antiga - precisa continuar tentando
            tem_data_antiga=1
        fi
        
        sleep 2
    done
    
    # Se encontrou ganhadores, envia e encerra
    if [ $tem_ganhadores -gt 0 ]; then
        mensagem_completa="${mensagem_completa}└─────────────────────────────────┘"
        echo "┌─────────────────────────────────┐"
        echo "✅ $tem_ganhadores jogo(s) com ganhadores encontrados!"
        echo "└─────────────────────────────────┘"
        
        mensagem_log "✅ $tem_ganhadores jogo(s) com ganhadores. Enviando WhatsApp..."
        enviar_whatsapp "$mensagem_completa"
        
        if [ $? -eq 0 ]; then
            mensagem_log "✅ Notificações enviadas com sucesso."
        else
            mensagem_log "❌ Erro ao enviar notificações."
        fi
        
        mensagem_log "=== Análise de Ganhadores Finalizada ==="
        exit 0
    fi
    
    # Se não tem data antiga, encerra (dados atualizados mas sem ganhadores)
    if [ $tem_data_antiga -eq 0 ]; then
        echo "┌─────────────────────────────────┐"
        echo "ℹ️  Nenhum prêmio principal foi ganho nos sorteios de hoje."
        echo "└─────────────────────────────────┘"
        
        # Se tem jogos sem ganhadores, envia a lista
        if [ -n "$jogos_sem_ganhadores" ]; then
            mensagem_completa="📊 SORTEIOS DE HOJE - $(date '+%d/%m/%Y')

Nenhum prêmio principal foi ganho em:

${jogos_sem_ganhadores}
⏰ Próximos sorteios em breve!"
            
            mensagem_log "Enviando lista de jogos sem ganhadores..."
            enviar_whatsapp "$mensagem_completa"
            
            if [ $? -eq 0 ]; then
                mensagem_log "✅ Notificação de jogos sem ganhadores enviada."
            else
                mensagem_log "❌ Erro ao enviar notificação."
            fi
        fi
        
        mensagem_log "Nenhum ganhador encontrado (dados atualizados)."
        mensagem_log "=== Análise de Ganhadores Finalizada ==="
        exit 0
    fi
    
    # Tem data antiga, continua tentando
    if [ $tentativa -lt $MAX_TENTATIVAS ]; then
        mensagem_log "⏳ API com dados antigos. Tentativa $tentativa/$MAX_TENTATIVAS. Aguardando ${INTERVALO_TENTATIVA}s..."
        sleep $INTERVALO_TENTATIVA
    fi
    
    tentativa=$((tentativa + 1))
done

# Esgotou tentativas
echo "┌─────────────────────────────────┐"
echo "⏱️  Timeout: API não atualizada após $MAX_TENTATIVAS tentativas"
echo "└─────────────────────────────────┘"
mensagem_log "⏱️  Timeout após $MAX_TENTATIVAS tentativas."
mensagem_log "=== Análise de Ganhadores Finalizada ==="
exit 0