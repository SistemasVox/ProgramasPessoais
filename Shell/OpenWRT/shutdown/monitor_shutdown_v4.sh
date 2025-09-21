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
# Tempo mínimo considerado razoável para o sistema (ex: 1 de janeiro de 2020) date -d "2025-08-12" +%s
MIN_REASONABLE_TIME=1754967600

# --- Controle de Instância Única ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    # Outra instância está rodando ou lock file está preso
    # Verifica se o processo que criou o lock ainda existe
    if [ -s "$LOCK_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_FILE")
        if kill -0 "$LOCK_PID" 2>/dev/null; then
            # Processo ainda existe
            exit 0
        else
            # Processo não existe, assumir que o lock está preso e tentar limpá-lo
            # (Esta parte é delicada e pode variar; simplificando, apenas saímos)
            exit 0
        fi
    else
        exit 0
    fi
fi
# Registra o PID atual no lock file para depuração
echo $$ > "$LOCK_FILE"

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
        timeout 30 "$DIR/send_whatsapp.sh" "$msg" &>/dev/null || log "Aviso: Notificação falhou ou excedeu o tempo limite."
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
        if timeout 30 ntpclient -h "$NTP_SERVER" -s >/dev/null 2>&1; then
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
    local current_time_guess="$2" # Tempo atual antes do reset detectado

    # Validações de sanidade
    if ! [[ "$last_heartbeat" =~ ^[0-9]+$ ]] || [ "$last_heartbeat" -lt "$MIN_REASONABLE_TIME" ]; then
        log "ERRO: last_heartbeat inválido ou abaixo do mínimo razoável para fallback. Valor: '$last_heartbeat'"
        log_to_csv "N/A" "N/A" "$(date '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo 'N/A')" "N/A" "fallback_failed_invalid_timestamp"
        send_notification "❌ ERRO: Falha ao ajustar relógio via fallback - timestamp inválido."
        return 1
    fi

    # Verifica se last_heartbeat não é irracionalmente no futuro
    local max_reasonable_future=$(( 3600 * 24 * 365 * 10 )) # 10 anos
    if [ "$last_heartbeat" -gt $((current_time_guess + max_reasonable_future)) ]; then
         log "ERRO: last_heartbeat ($last_heartbeat) parece inválido ou muito no futuro para o fallback. current_time_guess: $current_time_guess"
         log_to_csv "N/A" "N/A" "$(date '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo 'N/A')" "N/A" "fallback_failed_invalid_timestamp"
         send_notification "❌ ERRO: Falha ao ajustar relógio via fallback - timestamp inválido."
         return 1
    fi

    local new_timestamp=$((last_heartbeat + FALLBACK_MARGIN))
    
    if date -s "@$new_timestamp" >/dev/null 2>&1; then
        local new_date_human
        new_date_human=$(date -d "@$new_timestamp" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
        if [ "$new_date_human" != "N/A" ]; then
            log "Relógio ajustado para: $new_date_human via fallback"
            send_notification "⚠️ Relógio resetado! Ajustado para $new_date_human via fallback"
            log_to_csv "N/A" "N/A" "$new_date_human" "N/A" "clock_reset_fallback"
        else
            log "Relógio ajustado via fallback, mas falha ao formatar data para log."
            send_notification "⚠️ Relógio resetado via fallback."
            log_to_csv "N/A" "N/A" "N/A" "N/A" "clock_reset_fallback"
        fi
        return 0
    else
        log "ERRO: Falha ao ajustar relógio via fallback"
        send_notification "❌ ERRO: Falha ao ajustar relógio via fallback"
        log_to_csv "N/A" "N/A" "$(date '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo 'N/A')" "N/A" "fallback_failed"
        return 1
    fi
}


# --- Lógica de Resolução Pendente ---
resolve_pending_check() {
    [ ! -f "$PENDING_FILE" ] && return

    if check_internet_connection; then
        log "Conexão restaurada. Resolvendo cálculo pendente com detalhamento."
        sync_ntp

        local last_heartbeat_raw
        last_heartbeat_raw=$(cat "$PENDING_FILE")
        local now
        now=$(date +%s)
        
        # Validação rigorosa do timestamp pendente
        if ! [[ "$last_heartbeat_raw" =~ ^[0-9]+$ ]] || [ "$last_heartbeat_raw" -lt "$MIN_REASONABLE_TIME" ]; then
            log "ERRO: Timestamp inválido ou abaixo do mínimo no arquivo pendente ($PENDING_FILE). Valor: '$last_heartbeat_raw'"
            rm -f "$PENDING_FILE"
            return 1
        fi
        local last_heartbeat=$last_heartbeat_raw

        # 1. Obter o uptime em segundos a partir do sistema
        local uptime_seconds_raw
        uptime_seconds_raw=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
        if [ -z "$uptime_seconds_raw" ]; then
            log "ERRO: Falha ao ler uptime de /proc/uptime."
            rm -f "$PENDING_FILE"
            return 1
        fi

        if ! [[ "$uptime_seconds_raw" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            log "ERRO: Formato inválido do uptime obtido de /proc/uptime. Valor: '$uptime_seconds_raw'"
            rm -f "$PENDING_FILE"
            return 1
        fi
        local uptime_seconds
        uptime_seconds=$(printf "%.0f" "$uptime_seconds_raw" 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$uptime_seconds" ]; then
             log "ERRO: Falha ao converter uptime para inteiro. Valor: '$uptime_seconds_raw'"
             rm -f "$PENDING_FILE"
             return 1
        fi

        # 2. Calcular o tempo exato em que o roteador ligou (boot)
        local boot_time=$((now - uptime_seconds))

        # 3. Calcular a duração em que ficou efetivamente DESLIGADO
        local powered_off_duration=$((boot_time - last_heartbeat))
        # Garante que não seja um número negativo por pequenas variações de tempo
        [ "$powered_off_duration" -lt 0 ] && powered_off_duration=0

        # 4. Calcular a duração TOTAL da interrupção (opcional, mas útil)
        local total_duration=$((now - last_heartbeat))

        # Formata as durações para um formato legível (HH:MM:SS)
        local duration_total_human duration_off_human duration_wait_human
        duration_total_human=$(printf "%02d:%02d:%02d" $((total_duration / 3600)) $(((total_duration % 3600) / 60)) $((total_duration % 60)) 2>/dev/null || echo "N/A")
        duration_off_human=$(printf "%02d:%02d:%02d" $((powered_off_duration / 3600)) $(((powered_off_duration % 3600) / 60)) $((powered_off_duration % 60)) 2>/dev/null || echo "N/A")
        duration_wait_human=$(printf "%02d:%02d:%02d" $((uptime_seconds / 3600)) $(((uptime_seconds % 3600) / 60)) $((uptime_seconds % 60)) 2>/dev/null || echo "N/A")

        local last_seen restart_time
        last_seen=$(date -d "@$last_heartbeat" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
        restart_time=$(date -d "@$now" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")

        # Envia uma notificação muito mais detalhada
        send_notification "⚡ REINÍCIO DETALHADO
⏱️ Total Interrupção: $duration_total_human
🔌 Tempo Desligado: $duration_off_human
⏳ Ligado/Aguardando: $duration_wait_human
💡 Parou: $last_seen
✅ Voltou: $restart_time"
        
        log "Reinício detalhado: Total=${total_duration}s, Desligado=${powered_off_duration}s, Aguardando=${uptime_seconds}s"
        
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

    local last_heartbeat_raw
    last_heartbeat_raw=$(cat "$HEARTBEAT_FILE" 2>/dev/null)
    local last_heartbeat

    # Verifica se heartbeat é válido
    if ! [[ "$last_heartbeat_raw" =~ ^[0-9]+$ ]] || [ "$last_heartbeat_raw" -lt "$MIN_REASONABLE_TIME" ]; then
        log "Heartbeat inválido ou abaixo do mínimo. Reiniciando monitor. Valor: '$last_heartbeat_raw'"
        send_notification "🔄 Reiniciando monitor (heartbeat inválido)"
        echo "$now" > "$HEARTBEAT_FILE"
        return
    fi
    last_heartbeat=$last_heartbeat_raw

    # Detecção de reset de relógio - PRIORIDADE MÁXIMA
    # Caso 1: Relógio foi para trás
    if [ "$now" -lt "$last_heartbeat" ]; then
        log "Detectado reset de relógio (atual: $now < último: $last_heartbeat)"
        
        # Ajusta o relógio independentemente de ter internet
        if apply_time_fallback "$last_heartbeat" "$now"; then
            # Relógio ajustado com sucesso, atualiza `now`
            now=$(date +%s)
        else
            # Se falhou no ajuste, registra para cálculo posterior
            # Mas só registra se o valor for válido
             if [[ "$last_heartbeat" =~ ^[0-9]+$ ]] && [ "$last_heartbeat" -ge "$MIN_REASONABLE_TIME" ]; then
                 echo "$last_heartbeat" > "$PENDING_FILE"
             fi
        fi
        # Retorna para evitar processamento adicional nesta iteração
        return
    fi
    
    # Caso 2: Relógio foi para frente (anomalia, mas não detectada por now < last)
    # Verifica se a diferença é irracionalmente grande (ex: mais de 1 ano)
    local max_expected_offline=$(( 3600 * 24 * 365 * 1 )) # 1 ano
    local offline_time_tmp=$((now - last_heartbeat))
    if [ "$offline_time_tmp" -gt "$max_expected_offline" ]; then
         log "Detectada anomalia de tempo (offline_time muito grande: $offline_time_tmp s). last_heartbeat: $last_heartbeat, now: $now"
         # Trata como um possível reset para o futuro
         if apply_time_fallback "$last_heartbeat" "$now"; then
             now=$(date +%s)
         else
             if [[ "$last_heartbeat" =~ ^[0-9]+$ ]] && [ "$last_heartbeat" -ge "$MIN_REASONABLE_TIME" ]; then
                 echo "$last_heartbeat" > "$PENDING_FILE"
             fi
         fi
         return
    fi

    # Verificação de reinício normal
    local offline_time=$((now - last_heartbeat))
    
    # Margem para evitar falsos positivos, aumentada um pouco para sistemas sobrecarregados
    if [ $offline_time -le $((HEARTBEAT_INTERVAL + 15)) ]; then
        return
    fi

    # Reinício detectado
    if check_internet_connection; then
        # Com internet: sincroniza NTP e calcula duração precisa
        sync_ntp
        now=$(date +%s)
        offline_time=$((now - last_heartbeat))
        
        local duration last_seen restart_time
        duration=$(printf "%02d:%02d:%02d" $((offline_time / 3600)) $(((offline_time % 3600) / 60)) $((offline_time % 60)) 2>/dev/null || echo "N/A")
        last_seen=$(date -d "@$last_heartbeat" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
        restart_time=$(date -d "@$now" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")

        send_notification "⚡ REINÍCIO DETECTADO
⏱️ Duração: $duration
💡 Parou: $last_seen
✅ Voltou: $restart_time"
        log "Reinício detectado: $duration (${offline_time}s)"
        log_to_csv "$offline_time" "$last_seen" "$restart_time" "$duration" "normal_restart"
    else
        # Sem internet: apenas registra para cálculo posterior
        log "Reinício sem internet. Horário ajustado via fallback ou registrado para cálculo futuro."
        send_notification "⚠️ Reinício detectado. Aguardando internet para cálculo detalhado."
        # Registra apenas se o valor for válido
        if [[ "$last_heartbeat" =~ ^[0-9]+$ ]] && [ "$last_heartbeat" -ge "$MIN_REASONABLE_TIME" ]; then
            echo "$last_heartbeat" > "$PENDING_FILE"
        fi
    fi
}

# --- Execução Principal ---
log "=== Iniciando monitor de quedas de energia (PID: $$) ==="
check_power_outage

# Loop principal
while true; do
    echo "$(date +%s)" > "$HEARTBEAT_FILE"
    resolve_pending_check
    sleep $HEARTBEAT_INTERVAL
done