#include <stdio.h>
#include <stdlib.h>

void clear_buffer() {
    int c;
    while ((c = getchar()) != '\n' && c != EOF) { }
}

void calc(float vf, float *va, float *agua) {
    float cap = 92.5;
    float cad = 70;
    float vap = (vf * cad) / 100;
    float va92 = (vap * 100) / cap;
    *va = va92;
    *agua = vf - va92;
}

int main() {
    char op;
    float vf, va, agua, va92;

    do {
        system("clear||cls");
        printf("Digite 'v' para volume final ou 'a' para agua necessaria: ");
        scanf(" %c", &op);
        clear_buffer();

        switch(op) {
            case 'v':
            case 'V':
                printf("Volume final (litros): ");
                scanf("%f", &vf);
                clear_buffer();
                calc(vf, &va, &agua);
                printf("Para %.3fL a 70%%, precisa de:\n", vf);
                printf("- %.3fL de alcool 92,5%%\n", va);
                printf("- %.3fL de agua\n", agua);
                break;
            case 'a':
            case 'A':
                printf("Alcool 92,5%% disponivel (litros): ");
                scanf("%f", &va92);
                clear_buffer();
                agua = ((va92 * 92.5) / 70) - va92;
                vf = va92 + agua;
                printf("Para obter uma solucao a 70%% com %.3fL de alcool 92,5%%, precisa adicionar %.3fL de agua.\n", va92, agua);
                printf("O volume final sera de %.3fL.\n", vf);
                break;
            default:
                printf("Opcao invalida. Digite 'v' ou 'a'.\n");
        }

        printf("Outra operacao? (s/n): ");
        scanf(" %c", &op);
        clear_buffer();
    } while (op == 's' || op == 'S');

    return 0;
}

