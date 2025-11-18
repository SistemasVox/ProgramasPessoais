#!/bin/sh

################################################################################
# Gerador de Jogos Aleatórios para Loterias da Caixa
################################################################################
#
# Descrição: Gera 3 sugestões de jogos aleatórios para loterias brasileiras
# Autor: SistemasVox
# Versão: 1.2.0
# Licença: MIT
#
# Compatibilidade:
#   - OpenWrt/BusyBox
#   - POSIX shell (/bin/sh, ash, dash)
#   - Linux embedded systems
#
# Dependências:
#   - dd (coreutils ou busybox)
#   - hexdump (bsdmainutils ou busybox)
#   - sort, tr, sed (busybox)
#
# Uso:
#   ./gerar_jogos_loteria.sh <nome_do_jogo>
#
# Exemplos:
#   ./gerar_jogos_loteria.sh megasena
#   ./gerar_jogos_loteria.sh lotofacil
#
# Jogos suportados:
#   - megasena (6 números de 1-60)
#   - maismilionaria (6 números de 1-50 + 2 trevos de 1-6)
#   - lotofacil (15 números de 1-25)
#   - quina (5 números de 1-80)
#   - lotomania (50 números de 0-100)
#   - duplasena (6 números de 1-50)
#   - diadesorte (7 números de 1-31 + mês da sorte)
#   - supersete (7 colunas com números de 0-9)
#
################################################################################

set -e  # Sai se houver erro

# Constantes
VERSION="1.2.0"
SCRIPT_NAME=$(basename "$0")

# --- VALIDAÇÃO DE ENTRADA ---

if [ -z "$1" ]; then
    cat << EOF
Uso: $SCRIPT_NAME <nome_do_jogo>

Jogos disponíveis:
  megasena        Mega-Sena (6 números de 1-60)
  maismilionaria  +Milionária (6 números + 2 trevos)
  lotofacil       Lotofácil (15 números de 1-25)
  quina           Quina (5 números de 1-80)
  lotomania       Lotomania (50 números de 0-100)
  duplasena       Dupla Sena (6 números de 1-50)
  diadesorte      Dia de Sorte (7 números + mês)
  supersete       Super Sete (7 colunas de 0-9)

Exemplos:
  $SCRIPT_NAME megasena
  $SCRIPT_NAME lotofacil

Versão: $VERSION
EOF
    exit 1
fi

JOGO=$(echo "$1" | tr '[:upper:]' '[:lower:]')

# --- FUNÇÕES DE GERAÇÃO ALEATÓRIA ---

# Gera número aleatório usando /dev/urandom
# Compatível com OpenWrt/BusyBox (não usa 'od')
# Argumentos: $1 = valor máximo (inclusive)
# Retorno: número aleatório entre 0 e max
rand_number() {
    max=$1
    
    # Validação de entrada
    if [ -z "$max" ] || [ "$max" -lt 0 ]; then
        echo "0"
        return 1
    fi
    
    # Lê 4 bytes do urandom, converte para hex, depois para decimal
    hex=$(dd if=/dev/urandom bs=1 count=4 2>/dev/null | hexdump -e '1/4 "%u"' 2>/dev/null)
    
    # Fallback se hexdump falhar
    if [ -z "$hex" ]; then
        echo "0"
        return 1
    fi
    
    echo $((hex % (max + 1)))
}

# Gera lista de números aleatórios únicos e ordenados
# Argumentos: $1 = quantidade, $2 = valor máximo, $3 = valor mínimo (opcional, padrão=1)
# Retorno: lista de números separados por espaço
gerar_numeros() {
    qtd=$1
    max=$2
    min=${3:-1}
    
    numeros=""
    contador=0
    tentativas=0
    max_tentativas=$((qtd * 100))  # Limite de segurança
    
    while [ $contador -lt $qtd ] && [ $tentativas -lt $max_tentativas ]; do
        num=$((min + $(rand_number $((max - min)))))
        tentativas=$((tentativas + 1))
        
        # Verifica duplicação (sem usar grep para performance)
        caso_encontrado=0
        for n in $numeros; do
            if [ "$n" = "$num" ]; then
                caso_encontrado=1
                break
            fi
        done
        
        if [ $caso_encontrado -eq 0 ]; then
            numeros="$numeros $num"
            contador=$((contador + 1))
        fi
    done
    
    # Ordena numericamente e remove espaço final
    echo "$numeros" | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# --- FUNÇÕES DE FORMATAÇÃO ---

# Formata número com zero à esquerda (2 dígitos)
# Argumentos: $1 = número
# Retorno: número formatado (ex: 01, 15)
formatar_numero() {
    num=$1
    if [ "$num" -lt 10 ]; then
        echo "0$num"
    else
        echo "$num"
    fi
}

# Quebra linha a cada N números para melhor legibilidade
# Argumentos: $1 = lista de números, $2 = números por linha
# Retorno: números formatados com quebras de linha
formatar_linha() {
    numeros="$1"
    por_linha=$2
    contador=0
    resultado=""
    total=$(echo "$numeros" | wc -w | tr -d ' ')
    
    for num in $numeros; do
        num_formatado=$(formatar_numero "$num")
        resultado="$resultado $num_formatado"
        contador=$((contador + 1))
        
        # Adiciona quebra de linha
        if [ $((contador % por_linha)) -eq 0 ] && [ $contador -lt $total ]; then
            resultado="$resultado
   "
        fi
    done
    
    echo "$resultado"
}

# Imprime cabeçalho padronizado
imprimir_cabecalho() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Imprime rodapé padronizado
imprimir_rodape() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "💡 Boa sorte! 🍀"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# --- GERADORES POR TIPO DE JOGO ---

gerar_megasena() {
    imprimir_cabecalho
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 6 60)
        echo "Jogo $i: $(formatar_linha "$numeros" 6)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
    
    imprimir_rodape
}

gerar_maismilionaria() {
    imprimir_cabecalho
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 6 50)
        trevo1=$((1 + $(rand_number 5)))
        trevo2=$((1 + $(rand_number 5)))
        
        # Garante trevos diferentes
        tentativas=0
        while [ $trevo2 -eq $trevo1 ] && [ $tentativas -lt 10 ]; do
            trevo2=$((1 + $(rand_number 5)))
            tentativas=$((tentativas + 1))
        done
        
        # Ordena trevos
        if [ $trevo2 -lt $trevo1 ]; then
            temp=$trevo1
            trevo1=$trevo2
            trevo2=$temp
        fi
        
        echo "Jogo $i: $(formatar_linha "$numeros" 6)"
        echo "   🍀 Trevos: $(formatar_numero $trevo1) $(formatar_numero $trevo2)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
    
    imprimir_rodape
}

gerar_lotofacil() {
    imprimir_cabecalho
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 15 25)
        echo "Jogo $i:"
        echo "   $(formatar_linha "$numeros" 8)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
    
    imprimir_rodape
}

gerar_quina() {
    imprimir_cabecalho
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 5 80)
        echo "Jogo $i: $(formatar_linha "$numeros" 5)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
    
    imprimir_rodape
}

gerar_lotomania() {
    imprimir_cabecalho
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 50 100 0)
        echo "Jogo $i:"
        echo "   $(formatar_linha "$numeros" 10)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
    
    imprimir_rodape
}

gerar_duplasena() {
    imprimir_cabecalho
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 6 50)
        echo "Jogo $i: $(formatar_linha "$numeros" 6)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
    
    imprimir_rodape
}

gerar_diadesorte() {
    imprimir_cabecalho
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 7 31)
        mes_numero=$((1 + $(rand_number 11)))
        
        # Mapeia número do mês para nome
        case $mes_numero in
            1) mes_nome="Janeiro" ;;
            2) mes_nome="Fevereiro" ;;
            3) mes_nome="Março" ;;
            4) mes_nome="Abril" ;;
            5) mes_nome="Maio" ;;
            6) mes_nome="Junho" ;;
            7) mes_nome="Julho" ;;
            8) mes_nome="Agosto" ;;
            9) mes_nome="Setembro" ;;
            10) mes_nome="Outubro" ;;
            11) mes_nome="Novembro" ;;
            12) mes_nome="Dezembro" ;;
            *) mes_nome="Janeiro" ;;  # Fallback
        esac
        
        echo "Jogo $i: $(formatar_linha "$numeros" 7)"
        echo "   📅 Mês da Sorte: $mes_nome"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
    
    imprimir_rodape
}

gerar_supersete() {
    imprimir_cabecalho
    
    i=1
    while [ $i -le 3 ]; do
        col1=$(rand_number 9)
        col2=$(rand_number 9)
        col3=$(rand_number 9)
        col4=$(rand_number 9)
        col5=$(rand_number 9)
        col6=$(rand_number 9)
        col7=$(rand_number 9)
        
        echo "Jogo $i: $col1 $col2 $col3 $col4 $col5 $col6 $col7"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
    
    imprimir_rodape
}

# --- EXECUÇÃO PRINCIPAL ---

case "$JOGO" in
    megasena)
        gerar_megasena
        ;;
    maismilionaria)
        gerar_maismilionaria
        ;;
    lotofacil)
        gerar_lotofacil
        ;;
    quina)
        gerar_quina
        ;;
    lotomania)
        gerar_lotomania
        ;;
    duplasena)
        gerar_duplasena
        ;;
    diadesorte)
        gerar_diadesorte
        ;;
    supersete)
        gerar_supersete
        ;;
    *)
        echo "Erro: Jogo '$JOGO' não é suportado."
        echo ""
        echo "Execute '$SCRIPT_NAME' sem argumentos para ver a lista de jogos disponíveis."
        exit 1
        ;;
esac

exit 0