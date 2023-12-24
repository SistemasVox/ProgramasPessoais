#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// Definindo a estrutura para os adubos
typedef struct {
    char tipo[10];
    float preco;
    int N, P, K; // Campos adicionados para armazenar os valores NPK
    float custo_unidade; // Campo para armazenar o custo por unidade de nutriente
    float custo_N, custo_P, custo_K; // Campos adicionados para armazenar o custo de cada nutriente
} Adubo;

// Função de comparação para qsort
int comparar_adubos(const void *a, const void *b) {
    Adubo *aduboA = (Adubo *)a;
    Adubo *aduboB = (Adubo *)b;
    if (aduboA->custo_unidade < aduboB->custo_unidade) return -1;
    if (aduboA->custo_unidade > aduboB->custo_unidade) return 1;
    return 0;
}

// Função para calcular o custo por unidade de nutriente e o custo de cada N, P e K
void calcular_custos(Adubo *adubo) {
    sscanf(adubo->tipo, "%d-%d-%d", &adubo->N, &adubo->P, &adubo->K); // Extrai os valores NPK da string
    int total_nutrientes = adubo->N + adubo->P + adubo->K;
    adubo->custo_unidade = adubo->preco / (total_nutrientes * 50); // 50Kg é o peso do saco
    adubo->custo_N = adubo->N > 0 ? adubo->custo_unidade * 50 / adubo->N : 0;
    adubo->custo_P = adubo->P > 0 ? adubo->custo_unidade * 50 / adubo->P : 0;
    adubo->custo_K = adubo->K > 0 ? adubo->custo_unidade * 50 / adubo->K : 0;
}

int main() {
    // Definindo os adubos com sua proporção NPK e preço
    Adubo adubos[] = {
        {"04-14-08", 142.00},
        {"08-28-16", 215.00},
        {"20-05-20", 185.00},
        {"10-10-10", 150.00},
        {"21-00-00", 130.00},
        {"46-00-00", 215.00},
        // Adicione os outros adubos da mesma forma
        {"", 0} // Marca o final da lista
    };

    int tamanho = sizeof(adubos) / sizeof(adubos[0]) - 1; // Excluindo o marcador de final da lista

    // Calcular o custo por unidade para cada adubo e determinar o melhor custo
    for (int i = 0; i < tamanho; i++) {
        calcular_custos(&adubos[i]);
    }

    // Ordenando os adubos pelo custo por unidade
    qsort(adubos, tamanho, sizeof(Adubo), comparar_adubos);

    // Imprimindo os adubos ordenados pelo custo por unidade
    printf("\nAdubos ordenados pelo custo por unidade de nutriente:\n");
    for (int i = 0; i < tamanho; i++) {
        printf("Adubo %s: R$ %.2f por unidade de nutriente, Custo N: R$ %.2f, Custo P: R$ %.2f, Custo K: R$ %.2f\n",
               adubos[i].tipo, adubos[i].custo_unidade, adubos[i].custo_N, adubos[i].custo_P, adubos[i].custo_K);
    }

    return 0;
}

