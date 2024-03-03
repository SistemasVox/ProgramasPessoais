#!/bin/bash
# dos2unix ./CalculadorAlcool70.bash ou sed -i 's/\r$//' ./CalculadorAlcool70.bash
# Definir constantes
c1=92.7
c2=70.0
densidade_etanol=0.789
densidade_agua=1.0

# Solicitar ao usuário o volume final desejado
read -p "Digite o volume final desejado em litros: " v2

# Calcular a quantidade de álcool puro necessária para a solução final
quantidade_alcool_puro=$(echo "scale=3; $c2 * $v2 / 100" | bc)

# Calcular a quantidade de álcool 92,7% necessária para fornecer essa quantidade de álcool puro
v1=$(echo "scale=3; $quantidade_alcool_puro / ($c1 / 100)" | bc)

# Calcular a quantidade de água necessária para completar o volume final
volume_agua=$(echo "scale=3; $v2 - $v1" | bc)

# Exibir os resultados
echo "Volume de álcool $c1% necessário: $v1 litros"
echo "Volume de água necessário: $volume_agua litros"
echo "Volume total final da mistura: $(echo "scale=3; $v1 + $volume_agua" | bc) litros"
