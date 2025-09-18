#!/bin/bash

#
# Monitor de queda de energia com fallback de horário ativo.
# Desenvolvido para resiliência em sistemas como OpenWrt.
#

# --- Seção de Configuração e Variáveis Globais ---

# Define o diretório de trabalho do script.
DIR="$(dirname "$(readlink -f "$0")")"
# Define o nome base do script para usar nos arquivos.
SCRIPT_NAME="$(basename "${0%.*}")"

# Define o caminho para o arquivo que armazena o último registro de atividade (timestamp).
HEARTBEAT_FILE="$DIR/.${SCRIPT_NAME}_heartbeat"
# Define o arquivo de lock para garantir que apenas uma instância do script execute.
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
# Define o arquivo de log para registrar eventos.
LOG_FILE="$DIR/${SCRIPT_NAME}.log"
# Define o arquivo CSV para um histórico estruturado das quedas.
CSV_FILE="$DIR/${SCRIPT_NAME}.csv"
# Define o intervalo em segundos entre cada atualização do heartbeat.
HEARTBEAT_INTERVAL=5

# --- Controle de Instância Única ---

# Abre o arquivo de lock e o mantém aberto.
exec 200>"$LOCK_FILE"
# Tenta obter um bloqueio exclusivo no arquivo sem esperar. Se falhar, outra instância já está rodando.
if ! flock -n 200; then
    exit 0
fi

# --- Limpeza na Saída ---

# Garante que o arquivo de lock seja removido quando o script for encerrado.
trap 'rm -f "$LOCK_FILE"; exit' SIGTERM SIGINT EXIT

# --- Funções Auxiliares ---

# Função para registrar mensagens no arquivo de log com data e hora.
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Função para formatar e enviar notificações.
send_notification() {
    local msg="[$(basename "$0")]"$'
'"$1"
    # Tenta executar o script de envio de notificação, se ele existir.
    if [ -f "$DIR/send_whatsapp.sh" ]; then
        "$DIR/send_whatsapp.sh" "$msg" &>/dev/null
    fi
    log "Notificação enviada: $1"
}

# Função para registrar os eventos de queda em um arquivo CSV.
log_to_csv() {
    local offline_time="$1"
    local last_seen="$2"
    local restart_time="$3"
    local duration="$4"
    local reason="$5"

    # Cria o cabeçalho do CSV se o arquivo não existir.
    if [ ! -f "$CSV_FILE" ]; then
        echo "timestamp_unix,duration_seconds,last_seen,restart_time,duration_human,reason" > "$CSV_FILE"
    fi

    # Adiciona a nova linha de dados ao arquivo CSV.
    echo "$(date +%s),\"$offline_time\",\"$last_seen\",\"$restart_time\",\"$duration\",\"$reason\"" >> "$CSV_FILE"
}

# Função para verificar a conexão com a internet usando ping.
check_internet_connection() {
    ping -c 1 -W 1 -w 1 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 -w 1 8.8.8.8 >/dev/null 2>&1
}

# Função para tentar sincronizar o relógio do sistema via NTP.
sync_ntp() {
    local max_attempts=3
    local attempts=0
    log "Tentando sincronização NTP..."

    while [ $attempts -lt $max_attempts ]; do
        if ntpclient -h a.st1.ntp.br -s >/dev/null 2>&1; then
            log "Sincronização NTP bem-sucedida."
            return 0
        fi
        sleep 2
        ((attempts++))
    done

    log "ERRO: Falha na sincronização NTP após $max_attempts tentativas."
    return 1
}

# --- Lógica Principal de Verificação ---

# Função central que detecta reinícios e gerencia o fallback de horário.
check_power_outage() {
    local now
    now=$(date +%s)

    # Caso 1: Primeira execução do script. Cria o arquivo de heartbeat.
    if [ ! -f "$HEARTBEAT_FILE" ] || [ ! -s "$HEARTBEAT_FILE" ]; then
        log "=== Monitor iniciado (PID: $$) ==="
        send_notification "✅ Monitor iniciado"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi

    # Caso 2: O arquivo de heartbeat está corrompido ou vazio.
    local last_heartbeat
    last_heartbeat=$(cat "$HEARTBEAT_FILE" 2>/dev/null)
    if [ -z "$last_heartbeat" ] || ! echo "$last_heartbeat" | grep -E "^[0-9]+$" >/dev/null; then
        log "=== Monitor reiniciado (timestamp inválido no heartbeat) ==="
        send_notification "🔄 Monitor reiniciado (arquivo de heartbeat inválido)"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi

    # Verifica se há conexão com a internet para decidir a estratégia.
    if check_internet_connection; then
        # Se tem internet, a prioridade é sincronizar o relógio para máxima precisão.
        sync_ntp
    else
        # Se NÃO tem internet, verifica se o relógio foi resetado (hora atual < última hora salva).
        if [ "$now" -lt "$last_heartbeat" ]; then
            log "=== SEM INTERNET: Horário do sistema resetado. Ativando fallback. ==="

            # Calcula um novo horário somando 2 minutos ao último registro válido.
            local new_timestamp=$((last_heartbeat + 120))
            local new_date_human
            new_date_human=$(date -d "@$new_timestamp" '+%d/%m/%Y %H:%M:%S')
            
            log "Ajustando relógio do sistema para: $new_date_human"
            
            # IMPORTANTE: Este comando exige permissão de root para alterar o relógio do sistema.
            if date -s "@$new_timestamp" >/dev/null 2>&1; then
                log "Relógio do sistema ajustado com sucesso via fallback."
                send_notification "⚠️ Reinício sem internet. Relógio ajustado para $new_date_human via fallback."
                log_to_csv "N/A" "N/A" "$new_date_human" "N/A" "no_internet_fallback_set"
                
                # Atualiza a variável 'now' com o novo horário corrigido.
                now=$(date +%s)
            else
                log "ERRO: Falha ao tentar ajustar o relógio. Verifique permissões (root/sudo)."
                send_notification "❌ ERRO: Falha ao ajustar relógio via fallback."
                log_to_csv "N/A" "N/A" "$(date '+%d/%m %H:%M:%S')" "N/A" "no_internet_fallback_failed"
                echo "$now" > "$HEARTBEAT_FILE"
                return
            fi
        fi
    fi

    # Caso 4: Com o horário já confiável, calcula o tempo offline.
    local offline_time=$((now - last_heartbeat))
    
    # Adiciona uma margem de 5s para evitar falsos positivos.
    if [ $offline_time -le $((HEARTBEAT_INTERVAL + 5)) ]; then
        # Se o tempo offline for menor que o intervalo, está tudo normal.
        return
    fi

    # Se chegou aqui, um reinício foi detectado. Calcula a duração e formata os dados.
    local duration
    duration=$(printf "%02d:%02d:%02d" $((offline_time / 3600)) $(((offline_time % 3600) / 60)) $((offline_time % 60)))
    local last_seen
    last_seen=$(date -d "@$last_heartbeat" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
    local restart_time
    restart_time=$(date -d "@$now" '+%d/%m/%Y %H:%M:%S')

    # Envia a notificação final com todos os detalhes.
    send_notification "⚡ REINÍCIO DETECTADO
⏱️ Duração: $duration
💡 Parou: $last_seen
✅ Voltou: $restart_time"
    log "=== Reinício detectado: $duration (${offline_time}s) ==="
    log_to_csv "$offline_time" "$last_seen" "$restart_time" "$duration" "normal_restart"
}


# --- Execução Principal ---

# Roda a checagem completa uma vez na inicialização do script.
check_power_outage

# Inicia o loop infinito que atualiza o arquivo de heartbeat a cada 5 segundos.
# É este loop que permite ao script saber quando o sistema esteve ativo pela última vez.
while true; do
    echo "$(date +%s)" > "$HEARTBEAT_FILE"
    sleep $HEARTBEAT_INTERVAL
done