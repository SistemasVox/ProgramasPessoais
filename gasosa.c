#include <stdio.h>
#include <locale.h>

int main() {
    setlocale(LC_ALL, "Portuguese");

    const float teorEtanolGasolina = 0.27; // Porcentagem de etanol na gasolina
    const float precoLitroGasolina = 4.99; // Preço por litro de gasolina
    const float precoLitroEtanol = 3.06;   // Preço por litro de etanol
    const float proporcaoGasolinaPuraDesejada = 0.50; // Proporção desejada de gasolina pura
    const float tolerancia = 0.01; // Tolerância para a proporção desejada

    float valorTotalGasto;
    printf("Insira o valor total que deseja gastar em combustível: R$ ");
    scanf("%f", &valorTotalGasto);

    float limiteInferior = 0;
    float limiteSuperior = valorTotalGasto;
    float valorParaGasolina, valorParaEtanol, volumeGasolina, volumeEtanol, volumeTotalTanque, proporcaoGasolinaPura;

    while (limiteSuperior - limiteInferior > tolerancia) {
        valorParaGasolina = (limiteInferior + limiteSuperior) / 2;
        valorParaEtanol = valorTotalGasto - valorParaGasolina;

        volumeGasolina = valorParaGasolina / precoLitroGasolina;
        volumeEtanol = valorParaEtanol / precoLitroEtanol;

        volumeTotalTanque = volumeGasolina + volumeEtanol;
        proporcaoGasolinaPura = (volumeGasolina * (1 - teorEtanolGasolina)) / volumeTotalTanque;

        if (proporcaoGasolinaPura < proporcaoGasolinaPuraDesejada) {
            limiteInferior = valorParaGasolina;
        } else {
            limiteSuperior = valorParaGasolina;
        }
    }

    printf("Valor a ser gasto em gasolina: R$ %.2f\n", valorParaGasolina);
    printf("Volume de gasolina a ser abastecido: %.2f litros\n", volumeGasolina);
    printf("Valor a ser gasto em etanol: R$ %.2f\n", valorParaEtanol);
    printf("Volume de etanol a ser abastecido: %.2f litros\n", volumeEtanol);
    printf("Volume total no tanque: %.2f litros\n", volumeTotalTanque);
    printf("Proporção de gasolina pura no tanque: %.2f%%\n", proporcaoGasolinaPura * 100);

    return 0;
}
