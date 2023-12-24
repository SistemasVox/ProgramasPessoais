#include <stdio.h>
#include <locale.h>

int main() {
    setlocale(LC_ALL, "Portuguese");

    // Propriedades dos combustíveis
    float teorEtanolGasolina = 0.27; // Porcentagem de etanol na gasolina
    float precoLitroGasolina = 4.99; // Preço por litro de gasolina
    float precoLitroEtanol = 3.06; // Preço por litro de etanol
    float proporcaoGasolinaDesejada = 0.50; // Proporção desejada de gasolina pura no volume total
    float valorTotalGasto;

    printf("Insira o valor total que deseja gastar em combustível: R$ ");
    scanf("%f", &valorTotalGasto);

    // Calculando o volume de gasolina pura e o volume de gasolina (incluindo etanol)
    float valorParaGasolinaPura = valorTotalGasto / 2;
    float volumeGasolinaPura = valorParaGasolinaPura / precoLitroGasolina;
    float volumeGasolinaIncluindoEtanol = volumeGasolinaPura / (1 - teorEtanolGasolina);

    // Calculando o valor e volume para etanol
    float valorGastoGasolina = volumeGasolinaIncluindoEtanol * precoLitroGasolina;
    float valorParaEtanol = valorTotalGasto - valorGastoGasolina;
    float volumeEtanol = valorParaEtanol / precoLitroEtanol;

    // Calculando o volume total de combustível
    float volumeTotalCombustivel = volumeGasolinaIncluindoEtanol + volumeEtanol;

    // Exibindo os resultados
    printf("Valor total a ser gasto: R$ %.2f\n", valorTotalGasto);
    printf("Valor a ser gasto em gasolina: R$ %.2f\n", valorGastoGasolina);
    printf("Valor a ser gasto em etanol: R$ %.2f\n", valorParaEtanol);
    printf("Volume de gasolina a ser abastecido: %.2f litros\n", volumeGasolinaIncluindoEtanol);
    printf("Volume de etanol a ser abastecido: %.2f litros\n", volumeEtanol);
    printf("Volume total de combustível a ser abastecido: %.2f litros\n", volumeTotalCombustivel);

    return 0;
}

