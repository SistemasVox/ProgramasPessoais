def calcular_volume_alcool(c1, c2, v2, densidade_etanol, densidade_agua, fator_correcao=None):
    """
    Calcula o volume de álcool 92,7% e água necessários para preparar uma solução de álcool a 70%.

    Parâmetros:
    c1: Concentração do álcool de partida (%)
    c2: Concentração desejada da solução final (%)
    v2: Volume final desejado (litros)
    densidade_etanol: Densidade do etanol (g/cm³)
    densidade_agua: Densidade da água (g/cm³)
    fator_correcao: Fator de correção para contração volumétrica (opcional)

    Retorna:
    v1: Volume de álcool 92,7% necessário (litros)
    volume_agua: Volume de água necessário (litros)
    """

    # Se o fator de correção for fornecido, ajusta o volume final desejado
    if fator_correcao is not None:
        v2 *= fator_correcao

    # Calcula o volume de álcool 92,7% necessário
    v1 = (c2 * v2) / c1

    # Calcula o volume de água necessário
    volume_agua = v2 - v1

    return v1, volume_agua

# Dados do problema
c1 = 92.7  # Concentração do álcool de partida (%)
c2 = 70.0  # Concentração desejada (%)
v2 = float(input("Digite o volume final desejado em litros: "))  # Volume final desejado (litros)
densidade_etanol = 0.789  # g/cm³
densidade_agua = 0.998    # g/cm³

# Opcional: defina o fator de correção para a mistura desejada
fator_correcao = 0.95

# Calcula e exibe os resultados
v1, volume_agua = calcular_volume_alcool(c1, c2, v2, densidade_etanol, densidade_agua, fator_correcao)
volume_total_final = v1 + volume_agua
print(f"Volume de álcool {c1}% necessário: {v1:.3f} litros")
print(f"Volume de água necessário: {volume_agua:.3f} litros")
print(f"Volume total final da mistura: {volume_total_final:.3f} litros")
