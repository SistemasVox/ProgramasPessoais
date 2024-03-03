# Definir constantes
$c1 = 92.7
$c2 = 70.0

# Solicitar ao usuário o volume final desejado
$v2 = [double](Read-Host "Digite o volume final desejado em litros")

# Calcular a quantidade de álcool puro necessária
$quantidade_alcool_puro = $c2 * $v2 / 100

# Calcular a quantidade de álcool 92,7% necessária
$v1 = $quantidade_alcool_puro * 100 / $c1

# Calcular a quantidade de água necessária
$volume_agua = $v2 - $v1

# Exibir os resultados com três casas decimais
Write-Host "Volume de álcool $c1% necessário: $($v1.ToString('0.000')) litros"
Write-Host "Volume de água necessário: $($volume_agua.ToString('0.000')) litros"
Write-Host "Volume total final da mistura: $($v2.ToString('0.000')) litros"

# Pausar a execução
Read-Host "Pressione Enter para continuar..."
