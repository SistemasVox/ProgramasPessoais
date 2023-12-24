teor_etanol_gasolina = 0.27  # Porcentagem de etanol na gasolina
preco_litro_gasolina = 4.99  # Preço por litro de gasolina
preco_litro_etanol = 3.06    # Preço por litro de etanol
proporcao_gasolina_pura_desejada = 0.50  # Proporção desejada de gasolina pura

valor_total_gasto = float(input("Insira o valor total que deseja gastar em combustível: R$ "))

# Definindo os limites para busca binária
limite_inferior = 0
limite_superior = valor_total_gasto

tolerancia = 0.01  # Tolerância para a proporção desejada

while limite_superior - limite_inferior > tolerancia:
    valor_para_gasolina = (limite_inferior + limite_superior) / 2
    valor_para_etanol = valor_total_gasto - valor_para_gasolina

    volume_gasolina = valor_para_gasolina / preco_litro_gasolina
    volume_etanol = valor_para_etanol / preco_litro_etanol

    volume_total_tanque = volume_gasolina + volume_etanol
    proporcao_gasolina_pura = (volume_gasolina * (1 - teor_etanol_gasolina)) / volume_total_tanque

    if proporcao_gasolina_pura < proporcao_gasolina_pura_desejada:
        limite_inferior = valor_para_gasolina
    else:
        limite_superior = valor_para_gasolina

print(f"Valor a ser gasto em gasolina: R$ {valor_para_gasolina:.2f}")
print(f"Volume de gasolina a ser abastecido: {volume_gasolina:.2f} litros")
print(f"Valor a ser gasto em etanol: R$ {valor_para_etanol:.2f}")
print(f"Volume de etanol a ser abastecido: {volume_etanol:.2f} litros")
print(f"Volume total no tanque: {volume_total_tanque:.2f} litros")
print(f"Proporção de gasolina pura no tanque: {proporcao_gasolina_pura * 100:.2f}%")
