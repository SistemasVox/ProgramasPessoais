#include <stdio.h>

void calcular_volume_alcool(float c1, float c2, float v2, float *v1, float *volume_agua) {
    // Calcular a quantidade de álcool puro necessária para a solução final
    float quantidade_alcool_puro = (c2 / 100) * v2;

    // Calcular a quantidade de álcool 92,7% necessário para fornecer essa quantidade de álcool puro
    *v1 = quantidade_alcool_puro / (c1 / 100);

    // Calcular a quantidade de água necessária para completar o volume final
    *volume_agua = v2 - *v1;
}

int main() {
    // Dados do problema
    float c1 = 92.7;  // Concentração do álcool de partida (%)
    float c2 = 70.0;  // Concentração desejada (%)
    float v2;         // Volume final desejado (litros)

    // Solicita ao usuário o volume final desejado
    printf("Digite o volume final desejado em litros: ");
    scanf("%f", &v2);

    // Calcula os volumes de álcool e água necessários
    float v1, volume_agua;
    calcular_volume_alcool(c1, c2, v2, &v1, &volume_agua);

    // Exibe os resultados
    printf("Volume de álcool %.1f%% necessário: %.3f litros\n", c1, v1);
    printf("Volume de água necessário: %.3f litros\n", volume_agua);
    printf("Volume total final da mistura: %.3f litros\n", v1 + volume_agua);

    return 0;
}

