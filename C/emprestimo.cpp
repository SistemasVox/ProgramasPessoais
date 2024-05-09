#include <stdio.h>

int main() {
    // Definir os valores do empréstimo
    float valor_emprestimo, valor_parcela;
    int parcelas;
    printf("Digite o valor do empréstimo: ");
    scanf("%f", &valor_emprestimo);
    printf("Digite o número de parcelas: ");
    scanf("%d", &parcelas);
    printf("Digite o valor da parcela: ");
    scanf("%f", &valor_parcela);

    // Calcular o valor total pago
    float valor_total_pago = parcelas * valor_parcela;

    // Calcular a taxa de juros total
    float juros_total = valor_total_pago - valor_emprestimo;

    // Calcular a taxa de juros mensal
    float juros_mensal = juros_total / parcelas;

    // Calcular a taxa de juros anual
    float juros_anual = juros_total / (parcelas / 12.0);

    // Calcular a porcentagem de juros total
    float porcentagem_juros_total = (juros_total / valor_emprestimo) * 100;

    // Calcular a porcentagem de juros mensal
    float porcentagem_juros_mensal = porcentagem_juros_total / parcelas;

    // Calcular a porcentagem de juros anual
    float porcentagem_juros_anual = porcentagem_juros_total / (parcelas / 12.0);

    // Exibir os resultados
    printf("Valor total pago: R$ %.2f\n", valor_total_pago);
    printf("Taxa de juros total: R$ %.2f\n", juros_total);
    printf("Taxa de juros mensal: R$ %.2f\n", juros_mensal);
    printf("Taxa de juros anual: R$ %.2f\n", juros_anual);
    printf("Porcentagem de juros total: %.2f%%\n", porcentagem_juros_total);
    printf("Porcentagem de juros mensal: %.2f%%\n", porcentagem_juros_mensal);
    printf("Porcentagem de juros anual: %.2f%%\n", porcentagem_juros_anual);

    return 0;
}

