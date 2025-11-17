#!/bin/sh
#
# Monitoramento de Conexão de Internet com SQLite, robusto e compatível POSIX
# Autor: SistemasVox / Copilot

# === CONFIGURAÇÕES ===
cd "$(dirname "$0")" || exit 1

NOME_SCRIPT="$(basename "$0" .sh)"
DIR="$(pwd)"
LOG_FILE="$DIR/$NOME_SCRIPT.log"
DB_PATH="$DIR/monitor.db"
LOCKFILE="/tmp/${NOME_SCRIPT}.lock"
DEBUG=false      # Ative para debug detalhado: true/false
INTERVAL=1       # Em segundos
MIN_OFFLINE_TIME=5  # Segundos
PING_SERVERS="1.1.1.1 9.9.9.9 8.8.8.8 172.217.28.131"
NUM_SERVERS=$(printf "%s\n" $PING_SERVERS | wc -w)
SEND_WHATSAPP="$DIR/send_whatsapp.sh"  # Script externo para notificações

# === FUNÇÕES DE LOG ===
log_msg() {
    # $1: nível (INFO/ERROR/DEBUG)
    # $2: mensagem
    printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
    [ "$1" = "ERROR" ] && printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
}

debug_log() {
    [ "$DEBUG" = "true" ] && log_msg "DEBUG" "$*"
}

# === CHECAGEM DE DEPENDÊNCIAS ===
check_dependencies() {
    for cmd in ping sqlite3 date awk cut grep printf; do
        command -v "$cmd" >/dev/null 2>&1 || {
            log_msg "ERROR" "Dependência '$cmd' não encontrada."
            exit 1
        }
    done
    [ -x "$SEND_WHATSAPP" ] || {
        log_msg "ERROR" "Script de notificação não encontrado ou não executável: $SEND_WHATSAPP"
        exit 1
    }
}

# === PROTEÇÃO CONTRA MÚLTIPLAS INSTÂNCIAS ROBUSTA ===
create_lockfile() {
    if [ -e "$LOCKFILE" ]; then
        old_pid=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log_msg "ERROR" "Outra instância está rodando (PID $old_pid). Abortando."
            exit 1
        else
            log_msg "INFO" "Lockfile antigo encontrado, mas processo não está ativo. Limpando lockfile."
            rm -f "$LOCKFILE"
        fi
    fi
    echo $$ > "$LOCKFILE"
}

clean_exit() {
    rm -f "$LOCKFILE"
    log_msg "INFO" "Saindo de forma limpa."
    exit 0
}

trap clean_exit INT TERM EXIT

# === FORMATAÇÃO DE DURAÇÃO EM SEGUNDOS ===
format_duration() {
    total_seconds=$1
    days=$((total_seconds / 86400))
    remaining=$((total_seconds % 86400))
    hours=$((remaining / 3600))
    remaining=$((remaining % 3600))
    minutes=$((remaining / 60))
    secs=$((remaining % 60))

    if [ "$days" -gt 0 ]; then
        printf "%d:%02d:%02d:%02d" "$days" "$hours" "$minutes" "$secs"
    else
        printf "%02d:%02d:%02d" "$hours" "$minutes" "$secs"
    fi
}

# === ENVIO DE NOTIFICAÇÃO ===
send_notification() {
    script_name=$(basename "$0")
    message=$(printf "[%s]\n⚠ OFF: %s\n⏱ %s\n✅ ON: %s" "$script_name" "$offline_start_str" "$formatted_duration" "$offline_end_str")
    log_msg "INFO" "Enviando notificação: $message"
    "$SEND_WHATSAPP" "$message" >/dev/null 2>&1
}

# === BANCO DE DADOS ===
save_status() {
    status=$1
    last_ping_value=$2
    datetime=$(date +"%Y-%m-%d %H:%M:%S")
    sqlite3 "$DB_PATH" "INSERT INTO ping_logs (data_hora, ping_anterior, status) VALUES ('$datetime', $last_ping_value, '$status');"
    if [ $? -eq 0 ]; then
        log_msg "INFO" "Registro inserido: $datetime, $last_ping_value, $status"
    else
        log_msg "ERROR" "Erro ao inserir no banco: $datetime, $last_ping_value, $status"
    fi
}

# === CONTROLE DE CONEXÃO ===
check_connection() {
    status=$1
    last_ping_value=$2
    current_time=$(date +%s)

    case "$status" in
        "ping_fall"|"internet_fall")
            if [ "$offline_start" -eq 0 ]; then
                offline_start=$current_time
                offline_type=$status
                log_msg "INFO" "Início da queda: $(date -u -d "@$offline_start" +"%Y-%m-%d %H:%M:%S") - Tipo: $offline_type"
            fi
            save_status "$status" "$last_ping_value"
            ;;
        "reconnection")
            if [ "$offline_start" -gt 0 ]; then
                offline_end=$current_time
                offline_duration=$((offline_end - offline_start))
                formatted_duration=$(format_duration $offline_duration)
                save_status "$status" "$last_ping_value"
                if [ "$offline_duration" -ge "$MIN_OFFLINE_TIME" ]; then
                    offline_start_str=$(date -d "@$offline_start" +"%Y-%m-%d %H:%M:%S")
                    offline_end_str=$(date -d "@$offline_end" +"%Y-%m-%d %H:%M:%S")
                    unified_message="⚠️ Conexão PERDIDA em $offline_start_str\n⏱ Tempo offline: $formatted_duration\n✅ RESTAURADA em $offline_end_str"
                    send_notification "$unified_message"
                else
                    log_msg "INFO" "Notificação suprimida: tempo offline ($offline_duration s) < mínimo ($MIN_OFFLINE_TIME s)"
                fi
                offline_start=0; offline_type=""
            else
                save_status "$status" "$last_ping_value"
            fi
            ;;
        *)
            save_status "$status" "$last_ping_value"
            ;;
    esac

    last_status=$status
    last_ping=$last_ping_value
}

# === MONITORAMENTO PRINCIPAL ===
monitor_internet() {
    last_status="initial"
    last_ping="NULL"
    offline_start=0
    offline_type=""
    save_status "energy_fall" "NULL"

    while :; do
        ping_fail_count=0
        successful_ping=""
        current_ping="NULL"

        debug_log "Verificando conexão... last_status=$last_status"
        for SERVER in $PING_SERVERS; do
            # -w e -c são POSIX em ping do Busybox, iputils e BSD (ajuste se necessário para seu ambiente!)
            ping_result=$(ping -c 1 -w 1 "$SERVER" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | cut -d' ' -f1)
            if [ -z "$ping_result" ]; then
                ping_fail_count=$((ping_fail_count + 1))
                debug_log "Ping falhou: $SERVER"
            else
                successful_ping=$(printf '%.0f' "$ping_result" 2>/dev/null)
                debug_log "Ping OK: $SERVER: ${successful_ping}ms"
                if [ -z "$current_ping" ] || [ "$current_ping" = "NULL" ]; then
                    current_ping=$successful_ping
                fi
            fi
        done

        debug_log "ping_fail_count=$ping_fail_count, NUM_SERVERS=$NUM_SERVERS"

        # Determina novo status
        new_status=""
        if [ "$ping_fail_count" -eq 0 ]; then
            new_status="success"
            [ -n "$successful_ping" ] && current_ping=$successful_ping
        elif [ "$ping_fail_count" -eq "$NUM_SERVERS" ]; then
            new_status="internet_fall"
            current_ping="NULL"
        else
            new_status="ping_fall"
            [ -n "$successful_ping" ] && current_ping=$successful_ping || current_ping=$last_ping
        fi

        debug_log "new_status=$new_status, current_ping=$current_ping"

        # Processa mudança de estado
        if [ "$new_status" != "$last_status" ]; then
            debug_log "Mudança de estado: $last_status -> $new_status"
            case "$new_status" in
                "success")
                    if [ "$last_status" = "ping_fall" ] || [ "$last_status" = "internet_fall" ] || [ "$last_status" = "initial" ]; then
                        check_connection "reconnection" "$current_ping"
                        log_msg "INFO" "Conexão restaurada: $(date '+%Y-%m-%d %H:%M:%S')"
                    fi
                    ;;
                "ping_fall")
                    check_connection "ping_fall" "$current_ping"
                    log_msg "INFO" "Falha parcial detectada: $(date '+%Y-%m-%d %H:%M:%S')"
                    ;;
                "internet_fall")
                    check_connection "internet_fall" "$current_ping"
                    log_msg "INFO" "Falha total detectada: $(date '+%Y-%m-%d %H:%M:%S')"
                    ;;
            esac
        else
            debug_log "Sem mudança de estado ($new_status)"
        fi

        [ -n "$current_ping" ] && [ "$current_ping" != "NULL" ] && last_ping=$current_ping
        sleep $INTERVAL
    done
}

# === MAIN ===
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Uso: $0"
    echo "Monitoramento robusto de conexão de internet com log e banco SQLite."
    exit 0
fi

check_dependencies
create_lockfile
log_msg "INFO" "==== Iniciando $NOME_SCRIPT ===="
monitor_internet