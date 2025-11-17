#!/bin/bash

# ============================================================================
# Monitor de Quedas de Energia v2.0 - PRONTO PARA PRODUÇÃO
# ============================================================================
# Melhorias implementadas:
# - Separação de fallback e NTP (evita conflito)
# - Watchdog externo para detectar travamentos
# - Melhor tratamento de estado pendente
# - Logs mais detalhados para diagnóstico
# - Proteção contra múltiplas instâncias
# - Recuperação automática de falhas
# ============================================================================

# --- Configuração Avançada ---
DIR="$(dirname "$(readlink -f "$0")")"
SCRIPT_NAME="$(basename "${0%.*}")"
HEARTBEAT_FILE="$DIR/.${SCRIPT_NAME}_heartbeat"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
LOG_FILE="$DIR/${SCRIPT_NAME}.log"
CSV_FILE="$DIR/${SCRIPT_NAME}.csv"
PENDING_FILE="/tmp/${SCRIPT_NAME}.pending"
STATE_FILE="/tmp/${SCRIPT_NAME}.state"
WATCHDOG_MARKER="/tmp/${SCRIPT_NAME}.watchdog"

HEARTBEAT_INTERVAL=5
NTP_SERVER="a.st1.ntp.br"
PING_TARGETS=("1.1.1.1" "8.8.8.8")
FALLBACK_MARGIN=180              # 3 minutos (aumentado de 120s)
NTP_MAX_ATTEMPTS=3
NTP_WAIT_TIME=2
WATCHDOG_TIMEOUT=300             # 5 minutos sem heartbeat = problema
MAX_CONSECUTIVE_FAILURES=3
OFFLINE_THRESHOLD=$((HEARTBEAT_INTERVAL + 5))

# --- Controle de Instância Única ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    exit 0
fi

# --- Variáveis de Estado (persistentes entre ciclos) ---
CONSECUTIVE_NTP_FAILURES=0
LAST_FALLBACK_TIME=0

# --- Limpeza na Saída ---
trap 'cleanup; exit' SIGTERM SIGINT EXIT

cleanup() {
    rm -f "$LOCK_FILE" "$WATCHDOG_MARKER"
    [ -f "$STATE_FILE" ] && rm -f "$STATE_FILE"
}

# --- Funções Auxiliares ---
log() {
    local level="$1"
    local msg="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] $msg" | tee -a "$LOG_FILE"
}

log_debug() {
    [ "${DEBUG_MODE:-0}" == "1" ] && log "DEBUG" "$1"
}

send_notification() {
    local msg="[$(basename "$0")]"$'\n'"$1"
    if [ -f "$DIR/send_whatsapp.sh" ]; then
        "$DIR/send_whatsapp.sh" "$msg" &>/dev/null &
    fi
    log "NOTIFY" "$1"
}

update_watchdog() {
    echo "$(date +%s)" > "$WATCHDOG_MARKER"
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
            log_debug "Internet OK (ping $target)"
            return 0
        fi
    done
    log_debug "Internet falhou (todos os targets indisponíveis)"
    return 1
}

sync_ntp() {
    local max_attempts=$1
    local attempts=0
    
    log_debug "Iniciando sincronização NTP (máximo $max_attempts tentativas)..."
    
    while [ $attempts -lt "$max_attempts" ]; do
        if ntpclient -h "$NTP_SERVER" -s >/dev/null 2>&1; then
            log "NTP" "Sincronização bem-sucedida (tentativa $((attempts+1))/$max_attempts)"
            CONSECUTIVE_NTP_FAILURES=0
            return 0
        fi
        log_debug "NTP falhou (tentativa $((attempts+1))/$max_attempts)"
        sleep "$NTP_WAIT_TIME"
        ((attempts++))
    done
    
    ((CONSECUTIVE_NTP_FAILURES++))
    log "WARN" "NTP falhou após $max_attempts tentativas (falhas consecutivas: $CONSECUTIVE_NTP_FAILURES)"
    
    if [ "$CONSECUTIVE_NTP_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        log "ERROR" "NTP falhou $MAX_CONSECUTIVE_FAILURES vezes consecutivas"
        send_notification "❌ NTP crítico: Falhou $MAX_CONSECUTIVE_FAILURES vezes"
        return 1
    fi
    
    return 1
}

# --- Aplicar Fallback (SEM chamar NTP imediatamente após) ---
apply_time_fallback() {
    local last_heartbeat="$1"
    local new_timestamp=$((last_heartbeat + FALLBACK_MARGIN))
    
    log_debug "Aplicando fallback: last_hb=$last_heartbeat, margin=$FALLBACK_MARGIN"
    
    if date -s "@$new_timestamp" >/dev/null 2>&1; then
        local new_date_human
        new_date_human=$(date -d "@$new_timestamp" '+%d/%m/%Y %H:%M:%S')
        
        log "FALLBACK" "Relógio ajustado para: $new_date_human"
        LAST_FALLBACK_TIME=$(date +%s)
        
        send_notification "⚠️ Hora resetada!
Ajustada para: $new_date_human
(Fallback - aguardando NTP próximo ciclo)"
        
        log_to_csv "N/A" "N/A" "$new_date_human" "N/A" "clock_reset_fallback"
        
        # Registra estado para sincronização NTP em próximo ciclo
        echo "$last_heartbeat" > "$PENDING_FILE"
        echo "fallback_applied:$LAST_FALLBACK_TIME" > "$STATE_FILE"
        
        return 0
    else
        log "ERROR" "Falha ao ajustar relógio via fallback"
        send_notification "❌ ERRO: Falha ao ajustar relógio via fallback"
        log_to_csv "N/A" "N/A" "$(date '+%d/%m/%Y %H:%M:%S')" "N/A" "fallback_failed"
        return 1
    fi
}

# --- Resolver Cálculo Pendente (com NTP agora em outro ciclo) ---
resolve_pending_check() {
    [ ! -f "$PENDING_FILE" ] && return
    
    if ! check_internet_connection; then
        log_debug "Internet indisponível - aguardando próximo ciclo para resolver pending"
        return
    fi

    log "PENDING" "Iniciando resolução de cálculo pendente..."
    
    if ! sync_ntp "$NTP_MAX_ATTEMPTS"; then
        log "WARN" "NTP falhou durante resolução pendente"
        return
    fi

    local last_heartbeat
    last_heartbeat=$(cat "$PENDING_FILE" 2>/dev/null)
    local now
    now=$(date +%s)
    
    if [[ "$last_heartbeat" =~ ^[0-9]+$ ]]; then
        local uptime_seconds
        uptime_seconds=$(printf "%.0f" "$(cut -d' ' -f1 /proc/uptime)")

        local boot_time=$((now - uptime_seconds))
        local powered_off_duration=$((boot_time - last_heartbeat))
        [ "$powered_off_duration" -lt 0 ] && powered_off_duration=0

        local total_duration=$((now - last_heartbeat))

        local duration_total_human=$(printf "%02d:%02d:%02d" $((total_duration / 3600)) $(((total_duration % 3600) / 60)) $((total_duration % 60)))
        local duration_off_human=$(printf "%02d:%02d:%02d" $((powered_off_duration / 3600)) $(((powered_off_duration % 3600) / 60)) $((powered_off_duration % 60)))
        local duration_wait_human=$(printf "%02d:%02d:%02d" $((uptime_seconds / 3600)) $(((uptime_seconds % 3600) / 60)) $((uptime_seconds % 60)))

        local last_seen
        last_seen=$(date -d "@$last_heartbeat" '+%d/%m/%Y %H:%M:%S')
        local restart_time
        restart_time=$(date -d "@$now" '+%d/%m/%Y %H:%M:%S')

        send_notification "⚡ REINÍCIO DETALHADO (PÓS-FALLBACK)
⏱️ Total Interrupção: $duration_total_human
📌 Tempo Desligado: $duration_off_human
⏳ Ligado/Aguardando: $duration_wait_human
💡 Parou: $last_seen
✅ Voltou: $restart_time"
        
        log "PENDING_RESOLVED" "Total=${total_duration}s, Desligado=${powered_off_duration}s, Aguardando=${uptime_seconds}s"
    else
        log "ERROR" "Timestamp inválido no arquivo pendente"
    fi
    
    rm -f "$PENDING_FILE" "$STATE_FILE"
}

# --- Lógica Principal de Verificação ---
check_power_outage() {
    local now
    now=$(date +%s)
    
    update_watchdog

    # Inicialização se necessário
    if [ ! -f "$HEARTBEAT_FILE" ] || [ ! -s "$HEARTBEAT_FILE" ]; then
        log "INFO" "=== Monitor iniciado (PID: $$) ==="
        send_notification "✅ Monitor iniciado"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi

    local last_heartbeat
    last_heartbeat=$(cat "$HEARTBEAT_FILE" 2>/dev/null)

    # Verifica se heartbeat é válido
    if ! [[ "$last_heartbeat" =~ ^[0-9]+$ ]]; then
        log "WARN" "Heartbeat inválido: $last_heartbeat. Reiniciando monitor"
        send_notification "🔄 Reiniciando monitor (heartbeat inválido)"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi

    # --- DETECÇÃO DE RESET DE RELÓGIO (PRIORIDADE MÁXIMA) ---
    if [ "$now" -lt "$last_heartbeat" ]; then
        local time_diff=$((last_heartbeat - now))
        log "CRITICAL" "Reset de relógio detectado: $time_diff segundos para trás"
        
        # Aplica fallback APENAS (NTP vira no próximo ciclo)
        if apply_time_fallback "$last_heartbeat"; then
            now=$(date +%s)
        else
            log "ERROR" "Falha crítica no fallback"
            send_notification "❌ CRÍTICO: Falha ao aplicar fallback"
        fi
    fi

    # --- VERIFICAÇÃO DE REINÍCIO ---
    local offline_time=$((now - last_heartbeat))
    
    if [ $offline_time -le $OFFLINE_THRESHOLD ]; then
        log_debug "Monitor rodando normalmente (offline_time: ${offline_time}s)"
        return
    fi

    log "INFO" "Reinício detectado (offline_time: ${offline_time}s)"

    # Reinício COM internet: processa com precisão
    if check_internet_connection; then
        log_debug "Internet disponível - sincronizando NTP para precisão"
        
        if sync_ntp "$NTP_MAX_ATTEMPTS"; then
            now=$(date +%s)
            offline_time=$((now - last_heartbeat))
        fi
        
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
        
        log "RESTART" "Reinício normal: $duration (${offline_time}s)"
        log_to_csv "$offline_time" "$last_seen" "$restart_time" "$duration" "normal_restart"
        
        # Limpa arquivo pendente se estava sobrando
        rm -f "$PENDING_FILE" "$STATE_FILE"
    else
        # Reinício SEM internet: apenas registra (NTP virá depois)
        log "INFO" "Reinício sem internet - hora já ajustada via fallback (se aplicável)"
        send_notification "⚠️ Reinício detectado sem internet
(Aguardando internet para sincronização NTP)"
        
        echo "$last_heartbeat" > "$PENDING_FILE"
    fi
}

# --- THREAD DE WATCHDOG (SUBPROCESSO) ---
watchdog_thread() {
    log "DEBUG" "Watchdog iniciado (timeout: ${WATCHDOG_TIMEOUT}s)"
    
    while true; do
        sleep "$WATCHDOG_TIMEOUT"
        
        if [ ! -f "$WATCHDOG_MARKER" ]; then
            continue
        fi
        
        local last_update
        last_update=$(cat "$WATCHDOG_MARKER" 2>/dev/null)
        local now
        now=$(date +%s)
        local time_since_update=$((now - last_update))
        
        if [ "$time_since_update" -gt "$WATCHDOG_TIMEOUT" ]; then
            log "CRITICAL" "Watchdog: Monitor travado por ${time_since_update}s - REINICIANDO"
            send_notification "🚨 WATCHDOG: Monitor travado - reiniciando"
            
            # Mata o processo principal e deixa systemd reiniciar
            pkill -P $$ -f "$SCRIPT_NAME"
            exit 99
        fi
    done
}

# --- Inicialização ---
log "INFO" "=== Iniciando monitor de quedas de energia v2.0 ==="
check_power_outage

# Inicia watchdog em background
watchdog_thread &
WATCHDOG_PID=$!

# --- LOOP PRINCIPAL ---
LOOP_COUNT=0
while true; do
    ((LOOP_COUNT++))
    
    # Atualiza heartbeat
    echo "$(date +%s)" > "$HEARTBEAT_FILE"
    update_watchdog
    
    # Processa cálculos pendentes
    resolve_pending_check
    
    # Verifica por reinícios
    check_power_outage
    
    # Logging de debug a cada 100 ciclos
    if [ $((LOOP_COUNT % 100)) -eq 0 ]; then
        log_debug "Loop #$LOOP_COUNT - Estado OK"
    fi
    
    sleep "$HEARTBEAT_INTERVAL"
done