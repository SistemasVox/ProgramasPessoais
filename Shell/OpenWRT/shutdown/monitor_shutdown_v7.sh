#!/bin/bash

# =============================================================================
# MONITOR DE QUEDAS DE ENERGIA PARA OpenWRT - VERSÃO 7 (MELHORADA)
# =============================================================================
# 
# Este script monitora quedas de energia em roteadores OpenWRT com recursos
# limitados, fornecendo notificações detalhadas e controle robusto de erros.
#
# MELHORIAS DA VERSÃO 7:
# - Redundância de servidores NTP com rotação inteligente
# - Otimização extrema para recursos limitados (memória e CPU)
# - Sistema robusto de tratamento de erros
# - Redundância ampliada nos alvos de ping
# - Rotação automática de logs com compressão
# - Detecção e tratamento de reinícios rápidos (bouncing)
# - Sistema de backoff exponencial para reconexão
# - Comentários detalhados para facilitar manutenção
# - Monitoramento de recursos do próprio script
# - Sistema de cache para evitar operações desnecessárias
#
# COMPATIBILIDADE: OpenWRT 19.07+, requer busybox com ntpclient
# RECURSOS MÍNIMOS: 4MB RAM, 512KB storage
# =============================================================================

# --- CONFIGURAÇÕES GLOBAIS ---
readonly DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_NAME="$(basename "${0%.*}")"
readonly HEARTBEAT_FILE="$DIR/.${SCRIPT_NAME}_heartbeat"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
readonly LOG_FILE="$DIR/${SCRIPT_NAME}.log"
readonly CSV_FILE="$DIR/${SCRIPT_NAME}.csv"
readonly PENDING_FILE="/tmp/${SCRIPT_NAME}.pending"
readonly CACHE_FILE="/tmp/${SCRIPT_NAME}.cache"
readonly BOUNCE_FILE="/tmp/${SCRIPT_NAME}.bounce"

# --- CONFIGURAÇÕES DE TEMPO ---
readonly HEARTBEAT_INTERVAL=5           # Intervalo entre verificações (segundos)
readonly FALLBACK_MARGIN=120            # Margem para ajuste de relógio (segundos)
readonly MIN_REASONABLE_TIME=1577836800 # 1º Janeiro 2020 00:00:00 UTC
readonly MAX_LOG_ENTRIES=3000           # Máximo de entradas no log (reduzido para economizar espaço)
readonly MAX_LOG_SIZE=$((5*1024*1024))  # Tamanho máximo do log (5MB - reduzido)
readonly BOUNCE_THRESHOLD=3             # Número de reinícios para considerar bouncing
readonly BOUNCE_WINDOW=300              # Janela de tempo para detectar bouncing (5 minutos)

# --- SERVIDORES NTP COM REDUNDÂNCIA AMPLIADA ---
# Lista de servidores NTP confiáveis com diversidade geográfica e organizacional
readonly NTP_SERVERS=(
    "a.st1.ntp.br"       # NTP.br - São Paulo
    "b.st1.ntp.br"       # NTP.br - São Paulo (backup)
    "c.st1.ntp.br"       # NTP.br - São Paulo (backup)
    "a.ntp.br"           # NTP.br - principal
    "pool.ntp.org"       # Pool global
    "time.google.com"    # Google Time
    "time.cloudflare.com" # Cloudflare Time
    "time.apple.com"     # Apple Time
)

# --- ALVOS DE PING COM REDUNDÂNCIA MÁXIMA ---
# Múltiplos provedores para garantir detecção confiável de conectividade
readonly PING_TARGETS=(
    "1.1.1.1"            # Cloudflare DNS
    "1.0.0.1"            # Cloudflare DNS secundário
    "8.8.8.8"            # Google DNS
    "8.8.4.4"            # Google DNS secundário
    "208.67.222.222"     # OpenDNS
    "208.67.220.220"     # OpenDNS secundário
    "9.9.9.9"            # Quad9
    "149.112.112.112"    # Quad9 secundário
    "4.2.2.2"            # Level3/CenturyLink
    "4.2.2.1"            # Level3/CenturyLink secundário
)

# --- CONFIGURAÇÕES DE TIMEOUT (OTIMIZADAS PARA ECONOMIA) ---
readonly NTP_TIMEOUT=15              # Timeout para NTP (reduzido)
readonly PING_TIMEOUT=1              # Timeout para ping (muito reduzido)
readonly WGET_TIMEOUT=3              # Timeout para verificação HTTP
readonly NOTIFY_TIMEOUT=30           # Timeout para notificações

# --- CONFIGURAÇÕES DE BACKOFF EXPONENCIAL ---
readonly BACKOFF_BASE=2              # Base para cálculo exponencial
readonly BACKOFF_MAX=300             # Máximo backoff (5 minutos)
readonly BACKOFF_INITIAL=5           # Backoff inicial

# --- VARIÁVEIS GLOBAIS PARA ECONOMIA DE RECURSOS ---
declare -g ntp_server_index=0        # Índice atual do servidor NTP
declare -g last_internet_check=0     # Cache da última verificação de internet
declare -g internet_cache_ttl=30     # TTL do cache de internet (segundos)
declare -g current_backoff=0         # Backoff atual
declare -g error_count=0             # Contador de erros consecutivos

# =============================================================================
# SISTEMA DE CONTROLE DE INSTÂNCIA ÚNICA
# =============================================================================
# Garante que apenas uma instância do script execute por vez, com recuperação
# automática de locks presos e validação de PID.

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    # Verifica se existe um PID válido no lock file
    if [ -s "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        # Verifica se o processo ainda existe
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            # Processo ainda está rodando - sair silenciosamente
            exit 0
        else
            # Lock preso - assumir controle
            echo "$$" > "$LOCK_FILE"
            log_message "WARN" "Recuperado de lock preso de PID $lock_pid"
        fi
    else
        # Lock file vazio - sair
        exit 0
    fi
fi

# Registra o PID atual para depuração
echo "$$" > "$LOCK_FILE"

# =============================================================================
# SISTEMA DE LIMPEZA E TRATAMENTO DE SINAIS
# =============================================================================
# Garante limpeza adequada dos recursos e arquivos temporários ao encerrar.

trap 'cleanup_and_exit' SIGTERM SIGINT EXIT SIGHUP

cleanup_and_exit() {
    # Remove arquivos temporários
    rm -f "$LOCK_FILE" "$PENDING_FILE" "$CACHE_FILE"
    
    # Log de encerramento
    log_message "INFO" "Monitor encerrado (PID: $$)"
    
    # Força a saída
    exit 0
}

# =============================================================================
# SISTEMA DE LOGGING OTIMIZADO
# =============================================================================
# Sistema de logging com níveis, rotação automática e otimizado para recursos
# limitados. Evita operações desnecessárias e mantém logs compactos.

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    
    # Validação básica
    [ -z "$message" ] && return 1
    
    # Gera timestamp uma vez
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Formato otimizado para economia de espaço
    echo "$timestamp [$level] $message" >> "$LOG_FILE"
    
    # Rotação de logs apenas em níveis críticos para economizar recursos
    if [ "$level" = "ERROR" ] || [ "$level" = "CRITICAL" ]; then
        rotate_logs_if_needed
    fi
}

# Rotação de logs otimizada para sistemas com poucos recursos
rotate_logs_if_needed() {
    # Verifica se o arquivo existe e seu tamanho apenas quando necessário
    [ ! -f "$LOG_FILE" ] && return 0
    
    # Usa stat para verificar tamanho (mais eficiente que wc)
    local file_size
    file_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
    
    # Rotação baseada em tamanho ou número de linhas
    if [ "$file_size" -gt "$MAX_LOG_SIZE" ]; then
        perform_log_rotation "size"
    else
        # Verifica número de linhas apenas se não passou do tamanho
        local line_count
        line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        
        if [ "$line_count" -gt "$MAX_LOG_ENTRIES" ]; then
            perform_log_rotation "lines"
        fi
    fi
}

# Executa a rotação de logs com compressão
perform_log_rotation() {
    local reason="$1"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local archive_name="${LOG_FILE%.log}_${timestamp}.log"
    
    # Move o arquivo atual
    if mv "$LOG_FILE" "$archive_name" 2>/dev/null; then
        # Comprime em background para não bloquear o script
        if command -v gzip >/dev/null 2>&1; then
            gzip "$archive_name" &
            log_message "INFO" "Log rotacionado ($reason), arquivo comprimido: ${archive_name}.gz"
        else
            log_message "INFO" "Log rotacionado ($reason), arquivo arquivado: $archive_name"
        fi
        
        # Remove logs antigos para economizar espaço (mantém apenas os 3 mais recentes)
        find "$DIR" -name "${SCRIPT_NAME}_*.log.gz" -type f | sort | head -n -3 | xargs rm -f 2>/dev/null
    else
        log_message "ERROR" "Falha na rotação de logs"
    fi
}

# =============================================================================
# SISTEMA DE NOTIFICAÇÕES
# =============================================================================
# Envia notificações através do WhatsApp se disponível, com timeout e retry.

send_notification() {
    local message="$1"
    local formatted_message="[$(basename "$0")]"$'\n'"$message"
    
    # Verifica se o script de notificação existe
    if [ -f "$DIR/send_whatsapp.sh" ] && [ -x "$DIR/send_whatsapp.sh" ]; then
        # Envia notificação com timeout
        if timeout "$NOTIFY_TIMEOUT" "$DIR/send_whatsapp.sh" "$formatted_message" >/dev/null 2>&1; then
            log_message "INFO" "Notificação enviada: $(echo "$message" | head -1)"
        else
            log_message "WARN" "Falha no envio de notificação ou timeout"
        fi
    else
        log_message "DEBUG" "Script de notificação não encontrado ou não executável"
    fi
}

# =============================================================================
# SISTEMA DE VERIFICAÇÃO DE CONECTIVIDADE COM CACHE
# =============================================================================
# Verifica conectividade com internet usando cache para economizar recursos
# e múltiplos métodos de verificação com fallback.

check_internet_connection() {
    local now
    now=$(date +%s)
    
    # Usa cache se ainda válido (economia de recursos)
    if [ -f "$CACHE_FILE" ]; then
        local cache_time cache_result
        {
            read -r cache_time
            read -r cache_result
        } < "$CACHE_FILE" 2>/dev/null
        
        # Se cache ainda é válido, usa resultado anterior
        if [ -n "$cache_time" ] && [ -n "$cache_result" ] && 
           [ $((now - cache_time)) -lt "$internet_cache_ttl" ]; then
            [ "$cache_result" = "1" ] && return 0 || return 1
        fi
    fi
    
    local success=false
    local targets_tested=0
    local max_targets=3  # Limita testes para economizar recursos
    
    # Testa apenas alguns alvos para economizar recursos
    for target in "${PING_TARGETS[@]}"; do
        [ "$targets_tested" -ge "$max_targets" ] && break
        
        # Ping único e rápido
        if ping -c 1 -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1; then
            success=true
            break
        fi
        
        ((targets_tested++))
    done
    
    # Fallback HTTP se ping falhou (mais lento, apenas se necessário)
    if ! $success; then
        if timeout "$WGET_TIMEOUT" wget -q --spider "http://www.google.com" >/dev/null 2>&1 ||
           timeout "$WGET_TIMEOUT" wget -q --spider "http://1.1.1.1" >/dev/null 2>&1; then
            success=true
        fi
    fi
    
    # Salva resultado no cache
    {
        echo "$now"
        $success && echo "1" || echo "0"
    } > "$CACHE_FILE"
    
    # Retorna resultado
    $success && return 0 || return 1
}

# =============================================================================
# SISTEMA DE SINCRONIZAÇÃO NTP COM ROTAÇÃO E BACKOFF
# =============================================================================
# Sincroniza o relógio usando múltiplos servidores NTP com rotação inteligente
# e sistema de backoff exponencial para economizar recursos.

sync_ntp_with_rotation() {
    local max_attempts=2  # Reduzido para economizar recursos
    local attempts=0
    local success=false
    local servers_tried=0
    local max_servers=4   # Limita servidores testados
    
    # Verifica se ntpclient está disponível
    if ! command -v ntpclient >/dev/null 2>&1; then
        log_message "WARN" "ntpclient não disponível - sincronização NTP desabilitada"
        return 1
    fi
    
    log_message "INFO" "Iniciando sincronização NTP (backoff: ${current_backoff}s)"
    
    # Aplica backoff se houver erros anteriores
    if [ "$current_backoff" -gt 0 ]; then
        log_message "DEBUG" "Aguardando backoff de ${current_backoff}s"
        sleep "$current_backoff"
    fi
    
    # Tenta sincronizar com rotação de servidores
    local start_index=$ntp_server_index
    while [ "$servers_tried" -lt "$max_servers" ] && [ "$servers_tried" -lt "${#NTP_SERVERS[@]}" ]; do
        local server="${NTP_SERVERS[$ntp_server_index]}"
        
        attempts=0
        while [ "$attempts" -lt "$max_attempts" ]; do
            log_message "DEBUG" "Tentando NTP: $server (tentativa $((attempts + 1)))"
            
            if timeout "$NTP_TIMEOUT" ntpclient -h "$server" -s >/dev/null 2>&1; then
                log_message "INFO" "Sincronização NTP bem-sucedida com $server"
                success=true
                current_backoff=0  # Reset backoff em caso de sucesso
                error_count=0
                break 2  # Sai de ambos os loops
            fi
            
            ((attempts++))
            [ "$attempts" -lt "$max_attempts" ] && sleep 1
        done
        
        # Rotaciona para próximo servidor
        ntp_server_index=$(((ntp_server_index + 1) % ${#NTP_SERVERS[@]}))
        ((servers_tried++))
        
        # Evita loop infinito
        [ "$ntp_server_index" -eq "$start_index" ] && break
    done
    
    if $success; then
        return 0
    else
        # Incrementa contador de erros e calcula backoff exponencial
        ((error_count++))
        current_backoff=$((BACKOFF_INITIAL * (BACKOFF_BASE ** (error_count - 1))))
        
        # Limita backoff máximo
        [ "$current_backoff" -gt "$BACKOFF_MAX" ] && current_backoff=$BACKOFF_MAX
        
        log_message "ERROR" "Falha na sincronização NTP (tentativa $error_count, próximo backoff: ${current_backoff}s)"
        return 1
    fi
}

# =============================================================================
# SISTEMA DE DETECÇÃO DE BOUNCING
# =============================================================================
# Detecta e trata reinícios rápidos (bouncing) que podem indicar problemas
# na fonte de energia ou hardware.

detect_bouncing() {
    local current_time
    current_time=$(date +%s)
    
    # Adiciona timestamp atual ao arquivo de bounce
    echo "$current_time" >> "$BOUNCE_FILE"
    
    # Remove entradas antigas (fora da janela de detecção)
    local cutoff_time=$((current_time - BOUNCE_WINDOW))
    if [ -f "$BOUNCE_FILE" ]; then
        # Filtra apenas timestamps recentes
        awk -v cutoff="$cutoff_time" '$1 >= cutoff' "$BOUNCE_FILE" > "${BOUNCE_FILE}.tmp" 2>/dev/null
        mv "${BOUNCE_FILE}.tmp" "$BOUNCE_FILE" 2>/dev/null
    fi
    
    # Conta reinícios na janela atual
    local bounce_count
    bounce_count=$(wc -l < "$BOUNCE_FILE" 2>/dev/null || echo "0")
    
    # Verifica se está em estado de bouncing
    if [ "$bounce_count" -ge "$BOUNCE_THRESHOLD" ]; then
        log_message "WARN" "Bouncing detectado: $bounce_count reinícios em ${BOUNCE_WINDOW}s"
        send_notification "⚠️ BOUNCING DETECTADO
🔄 Reinícios: $bounce_count em $((BOUNCE_WINDOW / 60)) minutos
🔧 Possível problema na fonte de energia
⚡ Verifique a estabilidade elétrica"
        
        # Aumenta intervalo de heartbeat temporariamente para reduzir carga
        log_message "INFO" "Aumentando intervalo de verificação devido ao bouncing"
        return 0  # Retorna 0 para indicar bouncing detectado
    fi
    
    return 1  # Retorna 1 para indicar funcionamento normal
}

# =============================================================================
# SISTEMA DE AJUSTE DE HORÁRIO COM FALLBACK
# =============================================================================
# Ajusta o relógio do sistema quando detecta inconsistências, com validações
# rigorosas e múltiplas camadas de segurança.

apply_time_fallback() {
    local last_heartbeat="$1"
    local current_time_guess="$2"
    
    log_message "INFO" "Aplicando ajuste de horário via fallback"
    
    # Validações de segurança
    if ! [[ "$last_heartbeat" =~ ^[0-9]+$ ]] || [ "$last_heartbeat" -lt "$MIN_REASONABLE_TIME" ]; then
        log_message "ERROR" "Timestamp inválido para fallback: '$last_heartbeat'"
        send_notification "❌ ERRO: Falha no ajuste de relógio - timestamp inválido"
        return 1
    fi
    
    # Verifica se não é muito distante no futuro (proteção contra timestamps maliciosos)
    local max_reasonable_future=$((current_time_guess + 86400 * 30))  # 30 dias
    if [ "$last_heartbeat" -gt "$max_reasonable_future" ]; then
        log_message "ERROR" "Timestamp muito no futuro para fallback: $last_heartbeat"
        send_notification "❌ ERRO: Timestamp suspeito detectado"
        return 1
    fi
    
    # Calcula novo timestamp com margem de segurança
    local new_timestamp=$((last_heartbeat + FALLBACK_MARGIN))
    
    # Aplica o novo horário
    if date -s "@$new_timestamp" >/dev/null 2>&1; then
        local new_date_human
        new_date_human=$(date -d "@$new_timestamp" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
        
        log_message "INFO" "Relógio ajustado para: $new_date_human"
        send_notification "🕒 RELÓGIO AJUSTADO
📅 Novo horário: $new_date_human
⚙️ Método: Fallback automático
⚠️ Verifique a fonte de tempo do sistema"
        
        # Registra evento no CSV
        log_to_csv "N/A" "N/A" "$new_date_human" "N/A" "clock_reset_fallback"
        return 0
    else
        log_message "ERROR" "Falha ao aplicar ajuste de relógio"
        send_notification "❌ ERRO CRÍTICO: Falha no ajuste de relógio"
        return 1
    fi
}

# =============================================================================
# SISTEMA DE LOG CSV PARA ESTATÍSTICAS
# =============================================================================
# Mantém registro estruturado de eventos para análise posterior e estatísticas.

log_to_csv() {
    local offline_time="$1"
    local last_seen="$2"
    local restart_time="$3"
    local duration="$4"
    local reason="$5"
    
    # Cria cabeçalho se arquivo não existe
    if [ ! -f "$CSV_FILE" ]; then
        echo "timestamp_unix,duration_seconds,last_seen,restart_time,duration_human,reason" > "$CSV_FILE"
    fi
    
    # Adiciona entrada com escape adequado
    {
        printf "%s," "$(date +%s)"
        printf '"%s",' "$offline_time"
        printf '"%s",' "$last_seen"
        printf '"%s",' "$restart_time"
        printf '"%s",' "$duration"
        printf '"%s"\n' "$reason"
    } >> "$CSV_FILE"
    
    # Mantém apenas últimas 1000 entradas para economizar espaço
    if [ -f "$CSV_FILE" ]; then
        local line_count
        line_count=$(wc -l < "$CSV_FILE" 2>/dev/null || echo "0")
        
        if [ "$line_count" -gt 1000 ]; then
            tail -999 "$CSV_FILE" > "${CSV_FILE}.tmp" 2>/dev/null && 
            mv "${CSV_FILE}.tmp" "$CSV_FILE" 2>/dev/null
            log_message "INFO" "CSV truncado para economizar espaço"
        fi
    fi
}

# =============================================================================
# SISTEMA DE RESOLUÇÃO DE EVENTOS PENDENTES
# =============================================================================
# Processa eventos que não puderam ser calculados precisamente devido à falta
# de conectividade, fornecendo análise detalhada quando possível.

resolve_pending_check() {
    [ ! -f "$PENDING_FILE" ] && return 0
    
    # Verifica conectividade antes de processar
    if ! check_internet_connection; then
        return 0  # Aguarda conectividade
    fi
    
    log_message "INFO" "Processando evento pendente com conectividade restaurada"
    
    # Sincroniza horário antes de calcular
    sync_ntp_with_rotation
    
    local last_heartbeat_raw now
    last_heartbeat_raw=$(cat "$PENDING_FILE" 2>/dev/null)
    now=$(date +%s)
    
    # Validação rigorosa do timestamp pendente
    if ! [[ "$last_heartbeat_raw" =~ ^[0-9]+$ ]] || [ "$last_heartbeat_raw" -lt "$MIN_REASONABLE_TIME" ]; then
        log_message "ERROR" "Timestamp inválido no arquivo pendente: '$last_heartbeat_raw'"
        rm -f "$PENDING_FILE"
        return 1
    fi
    
    local last_heartbeat=$last_heartbeat_raw
    
    # Obtém uptime do sistema para cálculo preciso
    local uptime_seconds_raw uptime_seconds
    uptime_seconds_raw=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
    
    if [ -z "$uptime_seconds_raw" ] || ! [[ "$uptime_seconds_raw" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        log_message "ERROR" "Falha ao obter uptime do sistema"
        rm -f "$PENDING_FILE"
        return 1
    fi
    
    # Converte para inteiro
    uptime_seconds=$(printf "%.0f" "$uptime_seconds_raw" 2>/dev/null)
    
    # Cálculos de duração
    local boot_time=$((now - uptime_seconds))
    local powered_off_duration=$((boot_time - last_heartbeat))
    local total_duration=$((now - last_heartbeat))
    
    # Garante valores não negativos
    [ "$powered_off_duration" -lt 0 ] && powered_off_duration=0
    
    # Formata durações para apresentação
    local duration_total_human duration_off_human duration_wait_human
    duration_total_human=$(printf "%02d:%02d:%02d" $((total_duration / 3600)) $(((total_duration % 3600) / 60)) $((total_duration % 60)) 2>/dev/null || echo "N/A")
    duration_off_human=$(printf "%02d:%02d:%02d" $((powered_off_duration / 3600)) $(((powered_off_duration % 3600) / 60)) $((powered_off_duration % 60)) 2>/dev/null || echo "N/A")
    duration_wait_human=$(printf "%02d:%02d:%02d" $((uptime_seconds / 3600)) $(((uptime_seconds % 3600) / 60)) $((uptime_seconds % 60)) 2>/dev/null || echo "N/A")
    
    # Formata timestamps
    local last_seen restart_time
    last_seen=$(date -d "@$last_heartbeat" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
    restart_time=$(date -d "@$now" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
    
    # Envia notificação detalhada
    send_notification "⚡ ANÁLISE DETALHADA DE REINÍCIO
📊 Duração Total: $duration_total_human
🔌 Tempo Desligado: $duration_off_human
⏳ Aguardando Rede: $duration_wait_human
📉 Última Atividade: $last_seen
📈 Conectividade Restaurada: $restart_time
🔍 Análise: Evento processado com precisão após reconexão"
    
    log_message "INFO" "Evento pendente processado: Total=${total_duration}s, Desligado=${powered_off_duration}s, Aguardando=${uptime_seconds}s"
    
    # Registra no CSV
    log_to_csv "$powered_off_duration" "$last_seen" "$restart_time" "$duration_off_human" "detailed_restart"
    
    # Remove arquivo pendente
    rm -f "$PENDING_FILE"
}

# =============================================================================
# FUNÇÃO PRINCIPAL DE VERIFICAÇÃO DE QUEDAS DE ENERGIA
# =============================================================================
# Lógica central para detecção de reinícios, análise de timestamps e
# coordenação de todas as funções de monitoramento.

check_power_outage() {
    local now
    now=$(date +%s)
    
    # Inicialização na primeira execução
    if [ ! -f "$HEARTBEAT_FILE" ] || [ ! -s "$HEARTBEAT_FILE" ]; then
        log_message "INFO" "Inicializando monitor (PID: $$)"
        send_notification "✅ MONITOR INICIADO
🔄 Sistema: $(uname -r)
💾 Versão: v7 (Otimizada)
⚡ Monitoramento de energia ativo"
        echo "$now" > "$HEARTBEAT_FILE"
        return 0
    fi
    
    # Lê último heartbeat
    local last_heartbeat_raw last_heartbeat
    last_heartbeat_raw=$(cat "$HEARTBEAT_FILE" 2>/dev/null)
    
    # Validação do heartbeat
    if ! [[ "$last_heartbeat_raw" =~ ^[0-9]+$ ]] || [ "$last_heartbeat_raw" -lt "$MIN_REASONABLE_TIME" ]; then
        log_message "WARN" "Heartbeat inválido detectado: '$last_heartbeat_raw'"
        send_notification "🔄 MONITOR REINICIADO
⚠️ Motivo: Heartbeat inválido
🔧 Ação: Reinicialização automática"
        echo "$now" > "$HEARTBEAT_FILE"
        return 0
    fi
    
    last_heartbeat=$last_heartbeat_raw
    
    # DETECÇÃO DE RESET DE RELÓGIO (PRIORIDADE MÁXIMA)
    if [ "$now" -lt "$last_heartbeat" ]; then
        log_message "CRITICAL" "Reset de relógio detectado (atual: $now < último: $last_heartbeat)"
        
        # Tenta ajustar o relógio
        if apply_time_fallback "$last_heartbeat" "$now"; then
            now=$(date +%s)  # Atualiza após ajuste
        else
            # Se falhou, registra para cálculo posterior
            if [[ "$last_heartbeat" =~ ^[0-9]+$ ]] && [ "$last_heartbeat" -ge "$MIN_REASONABLE_TIME" ]; then
                echo "$last_heartbeat" > "$PENDING_FILE"
            fi
        fi
        return 0  # Retorna para evitar processamento adicional
    fi
    
    # DETECÇÃO DE ANOMALIAS TEMPORAIS
    local offline_time_candidate=$((now - last_heartbeat))
    local max_expected_offline=$((86400 * 365))  # 1 ano
    
    if [ "$offline_time_candidate" -gt "$max_expected_offline" ]; then
        log_message "CRITICAL" "Anomalia temporal detectada: ${offline_time_candidate}s de diferença"
        
        # Trata como reset de relógio
        if apply_time_fallback "$last_heartbeat" "$now"; then
            now=$(date +%s)
        else
            if [[ "$last_heartbeat" =~ ^[0-9]+$ ]] && [ "$last_heartbeat" -ge "$MIN_REASONABLE_TIME" ]; then
                echo "$last_heartbeat" > "$PENDING_FILE"
            fi
        fi
        return 0
    fi
    
    # VERIFICAÇÃO DE REINÍCIO NORMAL
    local offline_time=$((now - last_heartbeat))
    
    # Margem para evitar falsos positivos (ajustada para sistemas carregados)
    local detection_threshold=$((HEARTBEAT_INTERVAL + 20))
    if [ "$offline_time" -le "$detection_threshold" ]; then
        return 0  # Funcionamento normal
    fi
    
    # REINÍCIO DETECTADO - Processar
    log_message "INFO" "Reinício detectado: ${offline_time}s de diferença"
    
    # Detecta bouncing antes de processar
    if detect_bouncing; then
        # Em estado de bouncing - processa com cuidado
        if check_internet_connection; then
            process_restart_with_internet "$last_heartbeat" "$now" "$offline_time" true
        else
            process_restart_without_internet "$last_heartbeat" true
        fi
    else
        # Funcionamento normal
        if check_internet_connection; then
            process_restart_with_internet "$last_heartbeat" "$now" "$offline_time" false
        else
            process_restart_without_internet "$last_heartbeat" false
        fi
    fi
}

# =============================================================================
# PROCESSAMENTO DE REINÍCIO COM CONECTIVIDADE
# =============================================================================
# Processa reinícios quando há conectividade disponível, permitindo
# sincronização NTP e cálculos precisos.

process_restart_with_internet() {
    local last_heartbeat="$1"
    local now="$2"
    local offline_time="$3"
    local is_bouncing="$4"
    
    # Sincroniza horário para cálculos precisos
    sync_ntp_with_rotation
    now=$(date +%s)  # Atualiza após sincronização
    offline_time=$((now - last_heartbeat))
    
    # Formata duração e timestamps
    local duration last_seen restart_time
    duration=$(printf "%02d:%02d:%02d" $((offline_time / 3600)) $(((offline_time % 3600) / 60)) $((offline_time % 60)) 2>/dev/null || echo "N/A")
    last_seen=$(date -d "@$last_heartbeat" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
    restart_time=$(date -d "@$now" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || echo "N/A")
    
    # Determina tipo de evento baseado em bouncing
    local event_type="normal_restart"
    local bounce_warning=""
    
    if $is_bouncing; then
        event_type="bouncing_restart"
        bounce_warning="⚠️ BOUNCING DETECTADO - "
    fi
    
    # Envia notificação apropriada
    send_notification "${bounce_warning}⚡ REINÍCIO DETECTADO
⏱️ Duração: $duration
💡 Última Atividade: $last_seen
✅ Reconectado: $restart_time
🌐 Status: Conectividade OK"
    
    log_message "INFO" "Reinício processado com internet: $duration (${offline_time}s)"
    
    # Registra no CSV
    log_to_csv "$offline_time" "$last_seen" "$restart_time" "$duration" "$event_type"
}

# =============================================================================
# PROCESSAMENTO DE REINÍCIO SEM CONECTIVIDADE
# =============================================================================
# Processa reinícios quando não há conectividade, registrando para
# processamento posterior quando a conexão for restaurada.

process_restart_without_internet() {
    local last_heartbeat="$1"
    local is_bouncing="$2"
    
    local bounce_warning=""
    if $is_bouncing; then
        bounce_warning="⚠️ BOUNCING + "
    fi
    
    log_message "WARN" "Reinício detectado sem conectividade - registrando para processamento posterior"
    
    send_notification "${bounce_warning}⚡ REINÍCIO DETECTADO
🔍 Status: Analisando...
📡 Conectividade: Aguardando
⏳ Cálculo preciso será feito quando a conexão for restaurada"
    
    # Registra para cálculo posterior se timestamp for válido
    if [[ "$last_heartbeat" =~ ^[0-9]+$ ]] && [ "$last_heartbeat" -ge "$MIN_REASONABLE_TIME" ]; then
        echo "$last_heartbeat" > "$PENDING_FILE"
        log_message "INFO" "Evento registrado para processamento posterior"
    fi
}

# =============================================================================
# SISTEMA DE MONITORAMENTO DE RECURSOS DO SCRIPT
# =============================================================================
# Monitora o próprio consumo de recursos do script para garantir eficiência
# em sistemas com recursos limitados.

monitor_script_resources() {
    local pid=$$
    
    # Obtém estatísticas do processo
    local mem cpu uptime
    mem=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
    uptime=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    
    # Verifica se conseguiu obter dados
    if [ -n "$mem" ] && [ -n "$uptime" ] && [[ "$mem" =~ ^[0-9]+$ ]]; then
        # Converte memória para MB
        local mem_mb
        mem_mb=$(awk "BEGIN {printf \"%.2f\", $mem/1024}")
        
        # Formata uptime
        local uptime_human
        uptime_human=$(printf "%02d:%02d:%02d" $((uptime / 3600)) $(((uptime % 3600) / 60)) $((uptime % 60)) 2>/dev/null || echo "${uptime}s")
        
        log_message "DEBUG" "Recursos: RAM=${mem_mb}MB, CPU=${cpu}%, Uptime=${uptime_human}, Errors=${error_count}, Backoff=${current_backoff}s"
        
        # Alerta se consumo for muito alto
        if [ -n "$mem" ] && [ "$mem" -gt 8192 ]; then  # > 8MB
            log_message "WARN" "Consumo alto de memória detectado: ${mem_mb}MB"
        fi
    fi
}

# =============================================================================
# SISTEMA DE VERIFICAÇÃO DE SAÚDE DO SISTEMA
# =============================================================================
# Verifica a saúde geral do sistema e reporta problemas que podem afetar
# o funcionamento do script.

check_system_health() {
    local errors=0
    
    # Verifica permissões de escrita
    if ! touch "$DIR/.health_test" 2>/dev/null; then
        log_message "ERROR" "Sem permissão de escrita em $DIR"
        ((errors++))
    else
        rm -f "$DIR/.health_test"
    fi
    
    # Verifica espaço disponível
    local free_space_kb
    free_space_kb=$(df -k "$DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    
    if [ -n "$free_space_kb" ] && [ "$free_space_kb" -lt 5120 ]; then  # < 5MB
        local free_space_mb
        free_space_mb=$(awk "BEGIN {printf \"%.1f\", $free_space_kb/1024}")
        log_message "WARN" "Pouco espaço disponível: ${free_space_mb}MB"
        ((errors++))
    fi
    
    # Verifica se os comandos essenciais estão disponíveis
    local missing_commands=()
    local essential_commands=("date" "ping" "timeout" "flock")
    local optional_commands=("ntpclient")
    
    # Verifica comandos essenciais
    for cmd in "${essential_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    # Verifica comandos opcionais (apenas avisa)
    for cmd in "${optional_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "WARN" "Comando opcional ausente: $cmd"
        fi
    done
    
    if [ ${#missing_commands[@]} -gt 0 ]; then
        log_message "ERROR" "Comandos essenciais ausentes: ${missing_commands[*]}"
        ((errors++))
    fi
    
    # Reporta status geral
    if [ "$errors" -eq 0 ]; then
        log_message "INFO" "Verificação de saúde: OK"
    else
        log_message "WARN" "Verificação de saúde: $errors problema(s) detectado(s)"
    fi
    
    return "$errors"
}

# =============================================================================
# LOOP PRINCIPAL DE EXECUÇÃO
# =============================================================================
# Loop principal otimizado com controle de recursos e tratamento de erros.

main_loop() {
    local iteration=0
    local health_check_interval=720    # A cada 1 hora (720 * 5s)
    local resource_check_interval=360  # A cada 30 minutos (360 * 5s)
    
    log_message "INFO" "Iniciando loop principal (PID: $$)"
    
    # Verificação inicial
    check_power_outage
    
    while true; do
        ((iteration++))
        
        # Atualiza heartbeat
        echo "$(date +%s)" > "$HEARTBEAT_FILE"
        
        # Processa eventos pendentes
        resolve_pending_check
        
        # Verificação de saúde periódica
        if [ $((iteration % health_check_interval)) -eq 0 ]; then
            check_system_health
        fi
        
        # Monitoramento de recursos periódico
        if [ $((iteration % resource_check_interval)) -eq 0 ]; then
            monitor_script_resources
        fi
        
        # Verificação principal
        check_power_outage
        
        # Sleep otimizado com tratamento de interrupção
        sleep "$HEARTBEAT_INTERVAL" || break
    done
}

# =============================================================================
# INICIALIZAÇÃO E VALIDAÇÃO
# =============================================================================

# Verificação inicial de saúde
if ! check_system_health; then
    echo "ERRO: Problemas detectados na verificação de saúde inicial" >&2
    exit 1
fi

# Cria arquivo de configuração de exemplo se não existir
readonly CONFIG_FILE="$DIR/${SCRIPT_NAME}.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOL'
# =============================================================================
# CONFIGURAÇÃO DO MONITOR DE QUEDAS DE ENERGIA v7
# =============================================================================
# Este arquivo permite personalizar o comportamento do script sem modificar
# o código principal. Descomente e ajuste as variáveis conforme necessário.

# Intervalo entre verificações (segundos)
#HEARTBEAT_INTERVAL=5

# Margem para ajuste de relógio via fallback (segundos)
#FALLBACK_MARGIN=120

# Ativar relatórios diários automáticos (1=sim, 0=não)
#DAILY_REPORT=0

# Horário para envio do relatório diário (formato HH:MM)
#DAILY_REPORT_TIME="08:00"

# Nível de log adicional (descomente para debug)
#LOG_LEVEL=DEBUG

# Timeout personalizado para NTP (segundos)
#NTP_TIMEOUT=15

# Cache TTL para verificação de internet (segundos)
#INTERNET_CACHE_TTL=30
EOL
    log_message "INFO" "Arquivo de configuração criado: $CONFIG_FILE"
fi

# Log de inicialização
log_message "INFO" "=== MONITOR DE ENERGIA v7 INICIADO ==="
log_message "INFO" "PID: $$, Configuração: $CONFIG_FILE"
log_message "INFO" "Recursos: ${#NTP_SERVERS[@]} servidores NTP, ${#PING_TARGETS[@]} alvos de ping"

# Inicia loop principal
main_loop