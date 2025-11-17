#!/bin/sh

# ==============================================================================
# 1. VARIÁVEIS GLOBAIS
# ==============================================================================

# Garante que o script execute a partir de seu próprio diretório
cd "$(dirname "$0")" || exit 1

# --- Configurações de Nomes e Caminhos ---
NOME_SCRIPT="$(basename "$0" .sh)"
DIR="$(pwd)"
LOG_FILE="$DIR/$NOME_SCRIPT.log"
DB_PATH="$DIR/${NOME_SCRIPT}.db"
LOCKFILE="/tmp/${NOME_SCRIPT}.lock"
SEND_WHATSAPP="$DIR/send_whatsapp.sh"

# --- Configurações de Comportamento ---
DEBUG=false
INTERVAL=1                  # Intervalo em segundos entre cada verificação
MIN_OFFLINE_TIME=5          # Tempo mínimo de queda (em segundos) para enviar notificação
MAX_CONNECTION_ATTEMPTS=60  # Nº máximo de tentativas para aguardar a conexão inicial

# --- Configurações de Rede ---
TRACEROUTE_TARGET="1.1.1.1" # Alvo para o traceroute inicial
TRACEROUTE_TIMEOUT=5        # Timeout para o traceroute

# ==============================================================================
# 2. FUNÇÕES
# ==============================================================================

log_msg() {
    # Formato: [DATA HORA] [NÍVEL] MENSAGEM
    printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
    # Se for um erro, exibe também no console (stderr)
    [ "$1" = "ERROR" ] && printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
}

debug_log() {
    [ "$DEBUG" = "true" ] && log_msg "DEBUG" "$*"
}

verifica_conexao() {
    ping -c 1 -W 2 "$TRACEROUTE_TARGET" >/dev/null 2>&1
}

aguarda_conexao() {
    attempt=0
    log_msg "INFO" "Aguardando conexão com internet para detectar servidores..."
    while [ "$attempt" -lt "$MAX_CONNECTION_ATTEMPTS" ]; do
        if verifica_conexao; then
            log_msg "INFO" "Conexão detectada após $attempt tentativas"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    log_msg "ERROR" "Timeout: não foi possível estabelecer conexão após $MAX_CONNECTION_ATTEMPTS tentativas"
    return 1
}

get_ping_servers() {
    if ! aguarda_conexao; then
        log_msg "ERROR" "Usando servidores fallback devido à falta de conexão"
        echo "186.232.8.82 186.232.10.81"
        return
    fi
    
    servers=$(traceroute -n -m 10 -w "$TRACEROUTE_TIMEOUT" "$TRACEROUTE_TARGET" 2>/dev/null | \
              awk '/^[ ]*[0-9]+/ {
                  for(i=2; i<=NF; i++) {
                      if($i ~ /^186\./) {
                          print $i
                          break
                      }
                  }
              }' | \
              awk '!seen[$0]++')
    
    if [ -z "$servers" ]; then
        log_msg "ERROR" "Nenhum servidor 186.* encontrado no traceroute. Usando fallback."
        echo "186.232.8.82 186.232.10.81"
    else
        echo "$servers" | tr '\n' ' ' | sed 's/ $//'
    fi
}

check_dependencies() {
    for cmd in ping sqlite3 date awk cut grep printf traceroute; do
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

init_database() {
    if [ ! -f "$DB_PATH" ]; then
        log_msg "INFO" "Banco de dados não encontrado. Criando: $DB_PATH"
    fi
    
    sqlite3 "$DB_PATH" <<EOF
CREATE TABLE IF NOT EXISTS ping_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    data_hora TEXT NOT NULL,
    ping_anterior TEXT,
    status TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_data_hora ON ping_logs(data_hora);
CREATE INDEX IF NOT EXISTS idx_status ON ping_logs(status);
EOF
    
    if [ $? -eq 0 ]; then
        log_msg "INFO" "Banco de dados inicializado com sucesso: $DB_PATH"
        table_check=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='ping_logs';" 2>&1)
        if [ -z "$table_check" ]; then
            log_msg "ERROR" "Falha ao criar tabela ping_logs"
            exit 1
        fi
        log_msg "INFO" "Tabela ping_logs verificada e pronta para uso"
    else
        log_msg "ERROR" "Falha ao inicializar banco de dados: $DB_PATH"
        exit 1
    fi
}

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

send_notification() {
    script_name=$(basename "$0")
    message=$(printf "[%s]\nOFF: %s\nDuracao: %s\nON: %s" "$script_name" "$offline_start_str" "$formatted_duration" "$offline_end_str")
    log_msg "INFO" "Enviando notificação: $message"
    "$SEND_WHATSAPP" "$message" >/dev/null 2>&1
}

save_status() {
    status=$1
    last_ping_value=$2
    datetime=$(date +"%Y-%m-%d %H:%M:%S")
    
    if [ "$last_ping_value" = "NULL" ] || [ -z "$last_ping_value" ]; then
        ping_value="NULL"
    else
        ping_value="$last_ping_value"
    fi
    
    error_output=$(sqlite3 "$DB_PATH" "INSERT INTO ping_logs (data_hora, ping_anterior, status) VALUES ('$datetime', '$ping_value', '$status');" 2>&1)
    
    if [ $? -eq 0 ]; then
        debug_log "Registro inserido: $datetime, $ping_value, $status"
    else
        log_msg "ERROR" "Erro ao inserir no banco: $datetime, $ping_value, $status"
        log_msg "ERROR" "Detalhes do erro SQLite: $error_output"
        log_msg "INFO" "Tentando reinicializar o banco de dados..."
        init_database
    fi
}

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
                    send_notification
                else
                    log_msg "INFO" "Notificação suprimida: tempo offline ($offline_duration s) < mínimo ($MIN_OFFLINE_TIME s)"
                fi
                offline_start=0
                offline_type=""
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

        if [ "$new_status" != "$last_status" ]; then
            debug_log "Mudança de estado: $last_status -> $new_status"
            case "$new_status" in
                "success")
                    if [ "$last_status" = "ping_fall" ] || [ "$last_status" = "internet_fall" ] || [ "$last_status" = "initial" ]; then
                        check_connection "reconnection" "$current_ping"
                        log_msg "INFO" "Conexão restaurada: $(date '+%Y-%m-%d %H:%M:%S')"
                        log_msg "INFO" "Status anterior: $last_status | Novo status: $new_status"
                    fi
                    ;;
                "ping_fall")
                    if [ "$last_status" = "internet_fall" ]; then
                        check_connection "reconnection" "$current_ping"
                        log_msg "INFO" "Conexão parcialmente restaurada (de queda total para parcial): $(date '+%Y-%m-%d %H:%M:%S')"
                        log_msg "INFO" "Status anterior: $last_status | Novo status: $new_status"
                    else
                        check_connection "ping_fall" "$current_ping"
                        log_msg "INFO" "Falha parcial detectada: $(date '+%Y-%m-%d %H:%M:%S')"
                        log_msg "INFO" "Status anterior: $last_status | Novo status: $new_status"
                    fi
                    ;;
                "internet_fall")
                    check_connection "internet_fall" "$current_ping"
                    log_msg "INFO" "Falha total detectada: $(date '+%Y-%m-%d %H:%M:%S')"
                    log_msg "INFO" "Status anterior: $last_status | Novo status: $new_status"
                    ;;
            esac
        else
            debug_log "Sem mudança de estado ($new_status)"
        fi

        [ -n "$current_ping" ] && [ "$current_ping" != "NULL" ] && last_ping=$current_ping
        sleep $INTERVAL
    done
}

# ==============================================================================
# 3. EXECUÇÃO PRINCIPAL (MAIN)
# ==============================================================================

main() {
    # --- Gerenciamento de sinais para saída limpa ---
    trap clean_exit INT TERM EXIT

    # --- Verificação de ajuda ---
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        echo "Uso: $0"
        echo "Monitoramento robusto de conexão de internet com log e banco SQLite."
        exit 0
    fi

    # --- Inicialização ---
    check_dependencies
    create_lockfile
    init_database # O log é iniciado aqui pela primeira vez
    
    log_msg "INFO" "==== Iniciando $NOME_SCRIPT ===="
    
    # --- Obtenção dos servidores de ping ---
    PING_SERVERS=$(get_ping_servers)
    NUM_SERVERS=$(printf "%s\n" $PING_SERVERS | wc -w)
    log_msg "INFO" "Servidores de ping detectados: $PING_SERVERS ($NUM_SERVERS servidores)"

    # --- Início do monitoramento ---
    monitor_internet
}

# --- Ponto de Entrada do Script ---
# Executa a função principal passando todos os argumentos recebidos pelo script
main "$@"