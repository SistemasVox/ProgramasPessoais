#include <stdio.h>
#include <locale.h>

int main() {
    // Define o locale para Português para exibir corretamente os caracteres acentuados
    setlocale(LC_ALL, "Portuguese");

    // Constantes
    const float teorEtanolGasolina = 0.27; // Define a porcentagem de etanol na gasolina
    const float precoLitroGasolina = 4.99; // Define o preço por litro de gasolina
    const float precoLitroEtanol = 3.06;   // Define o preço por litro de etanol
    const float proporcaoGasolinaPuraDesejada = 0.50; // Define a proporção desejada de gasolina pura no tanque
    const float tolerancia = 0.01; // Define a tolerância para a proporção desejada

    // Variável para armazenar o valor total que o usuário deseja gastar
    float valorTotalGasto;
    printf("Insira o valor total que deseja gastar em combustível: R$ ");
    scanf("%f", &valorTotalGasto);

    // Inicializa os limites para o cálculo da busca binária
    float limiteInferior = 0;
    float limiteSuperior = valorTotalGasto;

    // Variáveis para armazenar os valores calculados
    float valorParaGasolina, valorParaEtanol, volumeGasolina, volumeEtanol, volumeTotalTanque, proporcaoGasolinaPura;

    // Loop para calcular a proporção ideal de gasolina e etanol
    while (limiteSuperior - limiteInferior > tolerancia) {
        valorParaGasolina = (limiteInferior + limiteSuperior) / 2;
        valorParaEtanol = valorTotalGasto - valorParaGasolina;

        volumeGasolina = valorParaGasolina / precoLitroGasolina;
        volumeEtanol = valorParaEtanol / precoLitroEtanol;

        volumeTotalTanque = volumeGasolina + volumeEtanol;
        proporcaoGasolinaPura = (volumeGasolina * (1 - teorEtanolGasolina)) / volumeTotalTanque;

        // Ajusta os limites com base na proporção calculada
        if (proporcaoGasolinaPura < proporcaoGasolinaPuraDesejada) {
            limiteInferior = valorParaGasolina;
        } else {
            limiteSuperior = valorParaGasolina;
        }
    }

    // Exibe os resultados
    printf("Valor a ser gasto em gasolina: R$ %.2f\n", valorParaGasolina);
    printf("Volume de gasolina a ser abastecido: %.2f litros\n", volumeGasolina);
    printf("Valor a ser gasto em etanol: R$ %.2f\n", valorParaEtanol);
    printf("Volume de etanol a ser abastecido: %.2f litros\n", volumeEtanol);
    printf("Volume total no tanque: %.2f litros\n", volumeTotalTanque);
    printf("Proporção de gasolina pura no tanque: %.2f%%\n", proporcaoGasolinaPura * 100);

    return 0;
}
