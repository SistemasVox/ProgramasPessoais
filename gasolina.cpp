#include <stdio.h>
#include <locale.h>
#include <math.h>

int main() {
    setlocale(LC_ALL, "Portuguese");
    // Propriedades dos combustíveis
    float teorEtanolGasolina = 0.27; // Porcentagem de etanol na gasolina
    float volumeTotalCombustivel = 48.0; // Volume total de combustível a ser abastecido

    // Preços dos combustíveis em reais por litro
    float precoLitroGasolina = 4.99;
    float precoLitroEtanol = 3.06;

    // Proporção desejada de gasolina no total (50%)
    float proporcaoGasolinaDesejada = 0.50; // Proporção de gasolina no total, em litros

    // Inicializando os limites para a busca binária
    float limiteInferior = 0;
    float limiteSuperior = volumeTotalCombustivel;
    float tolerancia = 0.01; // Tolerância para a proporção desejada

    float volumeGasolina, volumeEtanol, proporcaoGasolinaPura;

    // Realizando a busca binária
    while (limiteSuperior - limiteInferior > tolerancia) {
        volumeGasolina = (limiteInferior + limiteSuperior) / 2;
        volumeEtanol = volumeTotalCombustivel - volumeGasolina;

        proporcaoGasolinaPura = (volumeGasolina * (1 - teorEtanolGasolina)) / (volumeGasolina + volumeEtanol);

        if (proporcaoGasolinaPura < proporcaoGasolinaDesejada) {
            limiteInferior = volumeGasolina;
        } else {
            limiteSuperior = volumeGasolina;
        }
    }

    // Calculando o custo em reais
    float custoGasolina = volumeGasolina * precoLitroGasolina;
    float custoEtanol = volumeEtanol * precoLitroEtanol;
    float custoTotal = custoGasolina + custoEtanol;

    // Exibindo os resultados
    printf("Volume total de combustível: %.2f litros\n", volumeTotalCombustivel);
    printf("Volume de gasolina a ser abastecido: %.2f litros\n", volumeGasolina);
    printf("Volume de etanol a ser abastecido: %.2f litros\n", volumeEtanol);
    printf("Custo em reais:\n");
    printf("  Gasolina: R$ %.2f\n", custoGasolina);
    printf("  Etanol: R$ %.2f\n", custoEtanol);
    printf("Custo total: R$ %.2f\n", custoTotal);

    return 0;
}
