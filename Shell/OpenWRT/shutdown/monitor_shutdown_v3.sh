#!/bin/bash

# --- Configuração Avançada ---
DIR="$(dirname "$(readlink -f "$0")")"
SCRIPT_NAME="$(basename "${0%.*}")"
HEARTBEAT_FILE="$DIR/.${SCRIPT_NAME}_heartbeat"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
LOG_FILE="$DIR/${SCRIPT_NAME}.log"
CSV_FILE="$DIR/${SCRIPT_NAME}.csv"
PENDING_FILE="/tmp/${SCRIPT_NAME}.pending"
HEARTBEAT_INTERVAL=5
NTP_SERVER="a.st1.ntp.br"
PING_TARGETS=("1.1.1.1" "8.8.8.8")
FALLBACK_MARGIN=120

# --- Controle de Instância Única ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    exit 0
fi

# --- Limpeza na Saída ---
trap 'cleanup; exit' SIGTERM SIGINT EXIT

cleanup() {
    rm -f "$LOCK_FILE" "$PENDING_FILE"
}

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
    for target in "${PING_TARGETS[@]}"; do
        if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

sync_ntp() {
    local max_attempts=3
    local attempts=0
    log "Tentando sincronização NTP..."
    
    while [ $attempts -lt $max_attempts ]; do
        if ntpclient -h "$NTP_SERVER" -s >/dev/null 2>&1; then
            log "Sincronização NTP bem-sucedida."
            return 0
        fi
        sleep 2
        ((attempts++))
    done
    
    log "ERRO: Falha na sincronização NTP após $max_attempts tentativas."
    return 1
}

# --- Ajuste de Horário com Fallback (Prioritário) ---
apply_time_fallback() {
    local last_heartbeat="$1"
    local new_timestamp=$((last_heartbeat + FALLBACK_MARGIN))
    
    if date -s "@$new_timestamp" >/dev/null 2>&1; then
        local new_date_human
        new_date_human=$(date -d "@$new_timestamp" '+%d/%m/%Y %H:%M:%S')
        log "Relógio ajustado para: $new_date_human via fallback"
        send_notification "⚠️ Relógio resetado! Ajustado para $new_date_human via fallback"
        log_to_csv "N/A" "N/A" "$new_date_human" "N/A" "clock_reset_fallback"
        return 0
    else
        log "ERRO: Falha ao ajustar relógio via fallback"
        send_notification "❌ ERRO: Falha ao ajustar relógio via fallback"
        log_to_csv "N/A" "N/A" "$(date '+%d/%m %H:%M:%S')" "N/A" "fallback_failed"
        return 1
    fi
}

# --- Lógica de Resolução Pendente ---
resolve_pending_check() {
    [ ! -f "$PENDING_FILE" ] && return

    if check_internet_connection; then
        log "Conexão restaurada. Resolvendo cálculo pendente"
        sync_ntp

        local last_heartbeat
        last_heartbeat=$(cat "$PENDING_FILE")
        local now
        now=$(date +%s)
        
        if [[ "$last_heartbeat" =~ ^[0-9]+$ ]]; then
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
            log "Reinício resolvido: $duration (${offline_time}s)"
            log_to_csv "$offline_time" "$last_seen" "$restart_time" "$duration" "delayed_restart_calc"
        else
            log "ERRO: Timestamp inválido no arquivo pendente"
        fi
        
        rm -f "$PENDING_FILE"
    fi
}

# --- Lógica Principal de Verificação ---
check_power_outage() {
    local now
    now=$(date +%s)

    # Inicialização se necessário
    if [ ! -f "$HEARTBEAT_FILE" ] || [ ! -s "$HEARTBEAT_FILE" ]; then
        log "=== Monitor iniciado (PID: $$) ==="
        send_notification "✅ Monitor iniciado"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi

    local last_heartbeat
    last_heartbeat=$(cat "$HEARTBEAT_FILE" 2>/dev/null)

    # Verifica se heartbeat é válido
    if ! [[ "$last_heartbeat" =~ ^[0-9]+$ ]]; then
        log "Heartbeat inválido. Reiniciando monitor"
        send_notification "🔄 Reiniciando monitor (heartbeat inválido)"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi

    # Detecção de reset de relógio - PRIORIDADE MÁXIMA
    if [ "$now" -lt "$last_heartbeat" ]; then
        log "Detectado reset de relógio (atual: $now < último: $last_heartbeat)"
        
        # Ajusta o relógio independentemente de ter internet
        if apply_time_fallback "$last_heartbeat"; then
            now=$(date +%s)
        else
            # Se falhou no ajuste, mantém o horário atual mas registra o problema
            echo "$last_heartbeat" > "$PENDING_FILE"
        fi
    fi

    # Verificação de reinício
    local offline_time=$((now - last_heartbeat))
    
    # Margem para evitar falsos positivos
    if [ $offline_time -le $((HEARTBEAT_INTERVAL + 5)) ]; then
        return
    fi

    # Reinício detectado
    if check_internet_connection; then
        # Com internet: sincroniza NTP e calcula duração precisa
        sync_ntp
        now=$(date +%s)
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
        log "Reinício detectado: $duration (${offline_time}s)"
        log_to_csv "$offline_time" "$last_seen" "$restart_time" "$duration" "normal_restart"
    else
        # Sem internet: apenas registra para cálculo posterior
        log "Reinício sem internet. Horário já ajustado via fallback"
        send_notification "⚠️ Reinício detectado. Horário ajustado via fallback"
        echo "$last_heartbeat" > "$PENDING_FILE"
    fi
}

# --- Execução Principal ---
log "=== Iniciando monitor de quedas de energia ==="
check_power_outage

# Loop principal
while true; do
    echo "$(date +%s)" > "$HEARTBEAT_FILE"
    resolve_pending_check
    sleep $HEARTBEAT_INTERVAL
done