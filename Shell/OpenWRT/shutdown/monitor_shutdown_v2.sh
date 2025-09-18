#!/bin/bash

# --- Configuração ---
DIR="$(dirname "$(readlink -f "$0")")"
SCRIPT_NAME="$(basename "${0%.*}")"
HEARTBEAT_FILE="$DIR/.${SCRIPT_NAME}_heartbeat"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
LOG_FILE="$DIR/${SCRIPT_NAME}.log"
CSV_FILE="$DIR/${SCRIPT_NAME}.csv"
PENDING_FILE="/tmp/${SCRIPT_NAME}.pending"
HEARTBEAT_INTERVAL=5

# --- Controle de Instância Única ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    exit 0
fi

# --- Limpeza na Saída ---
trap 'rm -f "$LOCK_FILE" "$PENDING_FILE"; exit' SIGTERM SIGINT EXIT

# --- Funções Auxiliares ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

send_notification() {
    local msg="[$(basename "$0")]"$'
'"$1"
    if [ -f "$DIR/send_whatsapp.sh" ]; then
        "$DIR/send_whatsapp.sh" "$msg" &>/dev/null
    fi
    log "Notificação enviada: $1"
}

log_to_csv() {
    local offline_time="$1"
    local last_seen="$2"
    local restart_time="$3"
    local duration="$4"
    local reason="$5"

    if [ ! -f "$CSV_FILE" ]; then
        echo "timestamp_unix,duration_seconds,last_seen,restart_time,duration_human,reason" > "$CSV_FILE"
    fi
    echo "$(date +%s),\"$offline_time\",\"$last_seen\",\"$restart_time\",\"$duration\",\"$reason\"" >> "$CSV_FILE"
}

check_internet_connection() {
    ping -c 1 -W 1 -w 1 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 -w 1 8.8.8.8 >/dev/null 2>&1
}

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

# --- Lógica de Resolução do Cálculo Pendente ---
resolve_pending_check() {
    # Se não há cálculo pendente, não faz nada.
    [ ! -f "$PENDING_FILE" ] && return

    if check_internet_connection; then
        log "Conexão restaurada. Resolvendo cálculo de reinício pendente."
        sync_ntp

        local last_heartbeat
        last_heartbeat=$(cat "$PENDING_FILE")
        local now
        now=$(date +%s)
        
        # Garante que o timestamp lido é válido antes de prosseguir.
        if echo "$last_heartbeat" | grep -E "^[0-9]+$" >/dev/null; then
            local offline_time=$((now - last_heartbeat))
            local duration
            duration=$(printf "%02d:%02d:%02d" $((offline_time / 3600)) $(((offline_time % 3600) / 60)) $((offline_time % 60)))
            local last_seen
            last_seen=$(date -d "@$last_heartbeat" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
            local restart_time
            restart_time=$(date -d "@$now" '+%d/%m/%Y %H:%M:%S')

            send_notification "⚡ REINÍCIO RESOLVIDO
⏱️ Duração: $duration
💡 Parou: $last_seen
✅ Voltou: $restart_time"
            log "=== Reinício resolvido: $duration (${offline_time}s) ==="
            log_to_csv "$offline_time" "$last_seen" "$restart_time" "$duration" "delayed_restart_calc"
        else
            log "ERRO: Timestamp inválido no arquivo pendente. Não foi possível calcular a duração."
        fi
        
        # Limpa o arquivo pendente após a resolução.
        rm -f "$PENDING_FILE"
    fi
}

# --- Lógica Principal de Verificação (executada uma vez na inicialização) ---
check_power_outage() {
    local now
    now=$(date +%s)

    if [ ! -f "$HEARTBEAT_FILE" ] || [ ! -s "$HEARTBEAT_FILE" ]; then
        log "=== Monitor iniciado (PID: $$) ==="
        send_notification "✅ Monitor iniciado"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi

    local last_heartbeat
    last_heartbeat=$(cat "$HEARTBEAT_FILE" 2>/dev/null)

    if ! echo "$last_heartbeat" | grep -E "^[0-9]+$" >/dev/null; then
        log "=== Monitor reiniciado (heartbeat inválido) ==="
        send_notification "🔄 Monitor reiniciado (arquivo de heartbeat inválido)"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi

    local offline_time=$((now - last_heartbeat))
    
    # Se o tempo offline for menor que o intervalo, está tudo normal.
    if [ $offline_time -le $((HEARTBEAT_INTERVAL + 5)) ]; then
        return
    fi

    # Se chegou aqui, um reinício foi detectado.
    if check_internet_connection; then
        sync_ntp
        now=$(date +%s) # Atualiza 'now' após a sincronia para máxima precisão
        offline_time=$((now - last_heartbeat))
        
        local duration
        duration=$(printf "%02d:%02d:%02d" $((offline_time / 3600)) $(((offline_time % 3600) / 60)) $((offline_time % 60)))
        local last_seen
        last_seen=$(date -d "@$last_heartbeat" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
        local restart_time
        restart_time=$(date -d "@$now" '+%d/%m/%Y %H:%M:%S')

        send_notification "⚡ REINÍCIO DETECTADO
⏱️ Duração: $duration
💡 Parou: $last_seen
✅ Voltou: $restart_time"
        log "=== Reinício detectado: $duration (${offline_time}s) ==="
        log_to_csv "$offline_time" "$last_seen" "$restart_time" "$duration" "normal_restart"
    else
        # Sem internet, cria o arquivo pendente para resolver depois.
        log "REINÍCIO SEM INTERNET: Cálculo de duração pendente até a restauração da conexão."
        send_notification "⚠️ Reinício detectado sem internet. O cálculo da duração será feito quando a conexão voltar."
        echo "$last_heartbeat" > "$PENDING_FILE"
    fi
}

# --- Execução Principal ---

# Roda a checagem completa uma vez na inicialização.
check_power_outage

# Loop infinito que atualiza o heartbeat e verifica por cálculos pendentes.
while true; do
    echo "$(date +%s)" > "$HEARTBEAT_FILE"
    resolve_pending_check
    sleep $HEARTBEAT_INTERVAL
done