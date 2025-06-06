#!/bin/bash

# ==============================================================
#               SPEED TEST SCRIPT v5.3
#       (corrige numeração dos “#n” nos labels)
# ==============================================================

# --------------------------------------------------------------
#       CONFIGURAÇÕES GLOBAIS
# --------------------------------------------------------------
DEBUG=false

# User-Agent completo para evitar bloqueios
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/134.0.0.0 YaBrowser/25.4.0.0 Safari/537.36"

MAX_TIME=15       # segundos para cada download de teste
PING_TIMEOUT=5    # timeout para HEAD request

# URLs originais (HTTPS) para teste
TEST_FILE_URLS=(
    "https://download.manjaro.org/cinnamon/25.0.0/manjaro-cinnamon-25.0.0-250417-linux614.iso"
    "https://cdn.spring.io/spring-tools/release/STS4/4.30.0.RELEASE/dist/e4.35/spring-tools-for-eclipse-4.30.0.RELEASE-e4.35.0-win32.win32.x86_64.zip"
    "https://testfileorg.netwet.net/500MB-CZIPtestfile.org.zip"
    "https://speedtest3.serverius.net/files/100mb.bin"
)

# Cores para saída colorida
RED='\033[0;31m';    GREEN='\033[0;32m';    YELLOW='\033[1;33m';    BLUE='\033[0;34m';    NC='\033[0m'

# Variáveis auxiliares
declare -a test_labels
declare -a valid_urls
declare -a valid_labels
declare -a speed_results
declare -a test_ids


# --------------------------------------------------------------
#   FUNÇÃO: log_debug
#   Se DEBUG=true, imprime mensagem em stderr (para não poluir stdout)
# --------------------------------------------------------------
log_debug() {
    if [ "$DEBUG" = true ]; then
        echo -e "${YELLOW}[DEBUG] $1${NC}" >&2
    fi
}


# ==============================================================
#       FUNÇÃO: draw_header
#       Mostra cabeçalho colorido
# ==============================================================
draw_header() {
    echo -e "${YELLOW}"
    echo "   ███████╗██████╗ ███████╗███████╗██████╗"
    echo "   ██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗"
    echo "   ███████╗██████╔╝█████╗  █████╗  ██║  ██║"
    echo "   ╚════██║██╔═══╝ ██╔══╝  █╔══╝  ██║  ██║"
    echo "   ███████║██║     ███████╗███████╗██████╔╝"
    echo "   ╚══════╝╚═╝     ╚══════╝╚══════╝╚═════╝"
    echo -e "${NC}"
    echo -e "${BLUE}==============================================================${NC}"
}


# ==============================================================
#       FUNÇÃO: draw_separator
#       Mostra separador colorido
# ==============================================================
draw_separator() {
    echo -e "${BLUE}==============================================================${NC}"
}


# ==============================================================
#       FUNÇÃO: check_file_availability
#       Faz HEAD request com curl; retorna 0 se 2xx, senão 1
#       Imprime [OK] ou [FALHA: HTTP XXX]
# ==============================================================
check_file_availability() {
    local url="$1"
    local filename
    filename=$(basename "$url")
    echo -ne " ${BLUE}->${NC} Verificando: ${filename}... "

    # Tenta HEAD com timeout, user-agent e segue redirecionamento
    local http_code
    http_code=$(curl -I -s -L -A "$USER_AGENT" --max-time $PING_TIMEOUT \
                      -o /dev/null -w "%{http_code}" "$url")

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo -e "${GREEN}[OK]${NC}"
        return 0
    else
        echo -e "${RED}[FALHA: HTTP $http_code]${NC}"
        return 1
    fi
}


# ==============================================================
#       FUNÇÃO: check_connectivity
#       Tenta um HEAD rápido pra ver se há chance de baixar
#       Retorna 0 se parece conectável, senão 1
# ==============================================================
check_connectivity() {
    local url="$1"
    local code
    code=$(curl -I -s -L -A "$USER_AGENT" --max-time $PING_TIMEOUT \
                -o /dev/null -w "%{http_code}" "$url")

    if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    else
        return 1
    fi
}


# ==============================================================
#       FUNÇÃO: try_download_with_fallbacks
#       Tenta baixar o arquivo de várias formas:
#         1) curl normal
#         2) curl --insecure
#         3) curl -4 --insecure
#         4) curl HTTP (sem TLS)
#         5) wget --no-check-certificate
#       Retorna: total de bytes (>0) ou 0 se tudo falhar
# ==============================================================
try_download_with_fallbacks() {
    local url="$1"
    local max_time="$2"

    local tmp_bytes

    # 1) curl normal
    log_debug "Tentando curl normal: $url"
    tmp_bytes=$(timeout $max_time curl -s -L -A "$USER_AGENT" "$url" | wc -c)
    log_debug "Curl normal wc -c = $tmp_bytes"
    if [ "$tmp_bytes" -gt 0 ] 2>/dev/null; then
        echo "$tmp_bytes"
        return
    fi

    # 2) curl --insecure (ignorar SSL/TLS)
    log_debug "Tentando curl --insecure: $url"
    tmp_bytes=$(timeout $max_time curl -s -L -A "$USER_AGENT" --insecure "$url" | wc -c)
    log_debug "Curl --insecure wc -c = $tmp_bytes"
    if [ "$tmp_bytes" -gt 0 ] 2>/dev/null; then
        echo "$tmp_bytes"
        return
    fi

    # 3) curl -4 --insecure (forçar IPv4)
    log_debug "Tentando curl -4 --insecure: $url"
    tmp_bytes=$(timeout $max_time curl -4 -s -L -A "$USER_AGENT" --insecure "$url" | wc -c)
    log_debug "Curl -4 --insecure wc -c = $tmp_bytes"
    if [ "$tmp_bytes" -gt 0 ] 2>/dev/null; then
        echo "$tmp_bytes"
        return
    fi

    # 4) curl HTTP (substitui https por http, se possível)
    if [[ "$url" == https://* ]]; then
        local url_http="${url/https:\/\//http://}"
        log_debug "Tentando curl HTTP (sem TLS): $url_http"
        tmp_bytes=$(timeout $max_time curl -s -L -A "$USER_AGENT" "$url_http" | wc -c)
        log_debug "Curl HTTP wc -c = $tmp_bytes"
        if [ "$tmp_bytes" -gt 0 ] 2>/dev/null; then
            echo "$tmp_bytes"
            return
        fi
    fi

    # 5) wget --no-check-certificate (última opção)
    if command -v wget &> /dev/null; then
        log_debug "Tentando wget --no-check-certificate: $url"
        tmp_bytes=$(timeout $max_time wget -q --no-check-certificate -O - --user-agent="$USER_AGENT" "$url" | wc -c)
        log_debug "Wget wc -c = $tmp_bytes"
        if [ "$tmp_bytes" -gt 0 ] 2>/dev/null; then
            echo "$tmp_bytes"
            return
        fi
    else
        log_debug "wget não encontrado → pula opção wget"
    fi

    # Se tudo falhar, retorna zero
    echo 0
}


# ==============================================================
#       FUNÇÃO: measure_download_speed
#       Faz download usando try_download_with_fallbacks e calcula Mbps
# ==============================================================
measure_download_speed() {
    local url="$1"
    local idx="$2"
    local label="$3"

    echo -e "\n ${YELLOW}▶${NC} Testando: ${BLUE}${label}${NC}"

    # 1ª etapa: checa conectividade mínima (HEAD rápido)
    if ! check_connectivity "$url"; then
        echo -e " ${RED}× Host inacessível ou responde com erro. Pulando teste.${NC}"
        speed_results[$idx]=0
        test_ids[$idx]="$label"
        return
    fi

    # 2ª etapa: tenta baixar com vários fallbacks
    local bytes_downloaded
    bytes_downloaded=$(try_download_with_fallbacks "$url" "$MAX_TIME")

    if [ -z "$bytes_downloaded" ] || [ "$bytes_downloaded" -le 0 ] 2>/dev/null; then
        echo -e " ${RED}× Erro no download ou timeout em todos os métodos.${NC}"
        speed_results[$idx]=0
        test_ids[$idx]="$label"
        return
    fi

    # Se chegou aqui, conseguiu baixar algo
    local elapsed=$MAX_TIME

    # Converte bytes em KB
    local kb=$((bytes_downloaded / 1024))
    # Se kb < 1, força kb=1 pra não exibir 0 KB/s
    if [ "$kb" -lt 1 ] 2>/dev/null; then
        kb=1
    fi

    # Calcula velocidade: KB/s -> Mbps
    local speed_kbps=$((kb / elapsed))
    local speed_mbps
    speed_mbps=$(awk "BEGIN {printf \"%.2f\", $speed_kbps * 8 / 1024}")

    echo -e " ${GREEN}✓${NC} Velocidade aproximada: ${YELLOW}${speed_mbps} Mbps${NC} (${speed_kbps} KB/s)"
    log_debug "Bytes baixados: $bytes_downloaded B em ~${elapsed}s"

    speed_results[$idx]="$speed_mbps"
    test_ids[$idx]="$label"
}


# ==============================================================
#       FUNÇÃO PRINCIPAL: main
# ==============================================================
main() {
    draw_header

    # Gera labels com numeração sequencial (basename #1, basename #2, etc.)
    for i in "${!TEST_FILE_URLS[@]}"; do
        local url="${TEST_FILE_URLS[$i]}"
        local basename=$(basename "$url")
        # Usa índice +1 para numerar corretamente
        test_labels+=("${basename} #$((i + 1))")
    done

    echo -e " ${YELLOW}►${NC} Verificando recursos..."
    draw_separator

    # Checa disponibilidade e monta listas de URLs/labels válidas
    for i in "${!TEST_FILE_URLS[@]}"; do
        local url="${TEST_FILE_URLS[$i]}"
        if check_file_availability "$url"; then
            valid_urls+=("$url")
            valid_labels+=("${test_labels[$i]}")
        fi
    done

    draw_separator
    echo -e " ${YELLOW}►${NC} Iniciando ${#valid_urls[@]} testes..."
    draw_separator

    # Executa cada teste de velocidade
    for i in "${!valid_urls[@]}"; do
        measure_download_speed "${valid_urls[$i]}" "$i" "${valid_labels[$i]}"
    done

    draw_separator
    echo -e " ${YELLOW}►${NC} Resultados individuais:"
    local sum=0
    for i in "${!speed_results[@]}"; do
        printf " ${BLUE}➤${NC} %-45s: ${YELLOW}%8.2f Mbps${NC}\n" \
               "${test_ids[$i]}" "${speed_results[$i]}"
        sum=$(awk "BEGIN {print $sum + ${speed_results[$i]}}")
    done

    draw_separator
    # calcula e exibe média geral
    local avg
    if [ "${#speed_results[@]}" -gt 0 ]; then
        avg=$(awk "BEGIN {printf \"%.2f\", $sum / ${#speed_results[@]}}")
    else
        avg="0.00"
    fi
    echo -e " ${GREEN}▶${NC} Média geral: ${YELLOW}${avg} Mbps${NC}"
    draw_separator
}


# --------------------------------------------------------------
#       Verifica dependências: curl, timeout, wget
# --------------------------------------------------------------
if ! command -v curl &> /dev/null; then
    echo -e "${RED}Erro: curl não encontrado. Instale com: opkg update && opkg install curl${NC}"
    exit 1
fi

if ! command -v timeout &> /dev/null; then
    echo -e "${RED}Erro: timeout não encontrado. Instale com: opkg update && opkg install coreutils-timeout${NC}"
    exit 1
fi

# wget é opcional: se faltar, pulamos a tentativa final
if ! command -v wget &> /dev/null; then
    echo -e "${YELLOW}Aviso: wget não encontrado. Última fase de fallback (wget) será ignorada.${NC}"
fi

# Executa função principal
main
