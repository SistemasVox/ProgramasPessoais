#!/bin/sh

# Gerador de Jogos Aleatórios para Loterias da Caixa
# Versão 1.3 - OpenWrt/BusyBox compatível
#
# Uso: ./gerar_jogos_loteria.sh <nome_do_jogo>
# Exemplo: ./gerar_jogos_loteria.sh megasena

# Verifica se foi passado o nome do jogo
if [ -z "$1" ]; then
    echo "Uso: $0 <nome_do_jogo>"
    exit 1
fi

# Sanitiza o nome do jogo (compatível com BusyBox)
sanitizar_nome() {
    local nome="$1"
    # Remove espaços em branco
    nome=$(echo "$nome" | tr -d ' \t\n\r')
    # Converte para minúsculas
    nome=$(echo "$nome" | tr 'A-Z' 'a-z')
    echo "$nome"
}

JOGO=$(sanitizar_nome "$1")

# --- FUNÇÕES AUXILIARES ---

# Gera número aleatório usando /dev/urandom (sem od)
rand_number() {
    max=$1
    # Lê 4 bytes do urandom, converte para hex, depois para decimal
    hex=$(dd if=/dev/urandom bs=1 count=4 2>/dev/null | hexdump -e '1/4 "%u"')
    echo $((hex % (max + 1)))
}

# Gera números aleatórios únicos e ordenados
gerar_numeros() {
    qtd=$1
    max=$2
    min=${3:-1}
    
    numeros=""
    contador=0
    tentativas=0
    max_tentativas=$((qtd * 50))
    
    while [ $contador -lt $qtd ] && [ $tentativas -lt $max_tentativas ]; do
        num=$((min + $(rand_number $((max - min)))))
        tentativas=$((tentativas + 1))
        
        # Verifica se o número já foi sorteado
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
    
    # Ordena os números
    echo "$numeros" | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# Formata números com zero à esquerda (2 dígitos)
formatar_numero() {
    num=$1
    if [ $num -lt 10 ]; then
        echo "0$num"
    else
        echo "$num"
    fi
}

# Quebra linha a cada N números para melhor legibilidade
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
        
        if [ $((contador % por_linha)) -eq 0 ] && [ $contador -lt $total ]; then
            resultado="$resultado
   "
        fi
    done
    
    echo "$resultado"
}

# --- GERADORES POR TIPO DE JOGO ---

gerar_megasena() {
    echo "┌────────────────────────────┐"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "└────────────────────────────┘"
    echo ""
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 6 60)
        echo "Jogo $i: $(formatar_linha "$numeros" 6)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
}

gerar_maismilionaria() {
    echo "┌────────────────────────────┐"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "└────────────────────────────┘"
    echo ""
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 6 50)
        trevo1=$((1 + $(rand_number 5)))
        trevo2=$((1 + $(rand_number 5)))
        while [ $trevo2 -eq $trevo1 ]; do
            trevo2=$((1 + $(rand_number 5)))
        done
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
}

gerar_lotofacil() {
    echo "┌────────────────────────────┐"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "└────────────────────────────┘"
    echo ""
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 15 25)
        echo "Jogo $i:"
        echo "   $(formatar_linha "$numeros" 8)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
}

gerar_quina() {
    echo "┌────────────────────────────┐"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "└────────────────────────────┘"
    echo ""
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 5 80)
        echo "Jogo $i: $(formatar_linha "$numeros" 5)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
}

gerar_lotomania() {
    echo "┌────────────────────────────┐"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "└────────────────────────────┘"
    echo ""
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 50 100 0)
        echo "Jogo $i:"
        echo "   $(formatar_linha "$numeros" 10)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
}

gerar_duplasena() {
    echo "┌────────────────────────────┐"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "└────────────────────────────┘"
    echo ""
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 6 50)
        echo "Jogo $i: $(formatar_linha "$numeros" 6)"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
}

gerar_diadesorte() {
    echo "┌────────────────────────────┐"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "└────────────────────────────┘"
    echo ""
    
    i=1
    while [ $i -le 3 ]; do
        numeros=$(gerar_numeros 7 31)
        mes_numero=$((1 + $(rand_number 11)))
        
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
        esac
        
        echo "Jogo $i: $(formatar_linha "$numeros" 7)"
        echo "   📅 Mês da Sorte: $mes_nome"
        [ $i -lt 3 ] && echo ""
        i=$((i + 1))
    done
}

gerar_supersete() {
    echo "┌────────────────────────────┐"
    echo "🎲 SUGESTÕES DE JOGOS 🎲"
    echo "└────────────────────────────┘"
    echo ""
    
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
        echo "❌ Jogo '$1' não é suportado ou está corrompido." >&2
        echo "Nome recebido após sanitização: '$JOGO'" >&2
        echo "" >&2
        echo "Jogos disponíveis: megasena, maismilionaria, lotofacil, quina, lotomania, duplasena, diadesorte, supersete" >&2
        exit 1
        ;;
esac

echo ""
echo "┌────────────────────────────┐"
echo "💡 Boa sorte! 🍀"
echo "└────────────────────────────┘"
