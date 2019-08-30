/* 
 * File:   DadosMB_S.cpp
 * Author: Marcelo
 *
 * Created on 22 de Outubro de 2016, 18:11
 */

#include <stdio.h> //printf scanf
#include <stdlib.h> //abs
#include <locale.h>// Por causa das acentuações.
int op, dd, mm = 0, hh = 0;
long int kbs = 0, ss = 0;
double kb = 0;
void MB();
void GB();
void Dados();
void Velocidade();
void mbits();
void kbps();
void mbps();
void TempoSegundos();
void Horas();
void SegundosemMin();
void Dias();
void Teto();

int main() {
    setlocale(LC_ALL, "Portuguese");
    Dados();
    Velocidade();
    TempoSegundos();
    printf("\n\n");
    return 0;
}

void Dados() {
    Teto();
    printf("> Escola dentre as opções a seguir:\n");
    printf("\n 1. Para quantidade em MB.");
    printf("\n 2. Para quantidade em GB.\n");
    printf("\n> Resposta: ");
    scanf("%i", &op);
    if (op == 1) {
        MB();
    } else if (op == 2) {
        GB();
    } else {
        main();
    }
}

void MB() {
    Teto();
    printf("| Opção Quantidade Em [Megabyte] Escolhida [-] [?] [×]\n");
    printf("-----------------------------------------------------------\n");
    printf("Insira Quantidade de MB: ");
    scanf("%lf", &kb);
    kb = kb * 1024;
}

void GB() {
    Teto();
    printf("| Opção Quantidade Em [Gigabyte] Escolhida [-] [?] [×]\n");
    printf("-----------------------------------------------------------\n");
    printf("Insira Quantidade de GB: ");
    scanf("%lf", &kb);
    kb = (kb * 1024)*1024;
}

void Velocidade() {
    Teto();
    printf("> Escola dentre as opções a seguir:\n");
    printf("\n 1. Para Velocidade em mbit/s.");
    printf("\n 2. Para Velocidade em kb/s.");
    printf("\n 3. Para Velocidade em mb/s.\n");
    printf("\n> Resposta: ");
    scanf("%i", &op);
    if (op == 1) {
        mbits();
    } else if (op == 2) {
        kbps();
    } else if (op == 3) {
        mbps();
    } else {
        Velocidade();
    }
}

void mbits() {
    Teto();
    printf("| Opção Quantidade Em [Mbit/s] Escolhida [-] [?] [×] |\n");
    printf("-----------------------------------------------------------\n");
    printf("Insira Velocidade em mbit/s: ");
    scanf("%d", &kbs);
    kbs = ((kbs * 1024) / 8);
}

void kbps() {
    Teto();
    printf("| Opção Quantidade Em [KB/s] Escolhida [-] [?] [×] |\n");
    printf("-----------------------------------------------------------\n");
    printf("Insira Velocidade em KB/s: ");
    scanf("%d", &kbs);
}

void mbps() {
    Teto();
    printf("| Opção Quantidade Em [MB/s] Escolhida [-] [?] [×] |\n");
    printf("-----------------------------------------------------------\n");
    printf("Insira Velocidade em MB/s: ");
    scanf("%d", &kbs);
    kbs = kbs * 1024;
}

void TempoSegundos() {
    ss = (kb / kbs)+(kb = abs(kb) % kbs);
    SegundosemMin();
}

void SegundosemMin() {
    if (ss >= 60) {
        ss = ss - 60;
        mm++;
        SegundosemMin();
    } else {
        Horas();
    }
}

void Horas() {
    if (mm >= 60) {
        hh++;
        mm = mm - 60;
        Horas();
    } else {
        if (mm <= 9) {
            printf("\n=====> %dh:0%dm:%is", hh, mm, ss);
            Dias();
        } else {
            printf("\n=====> %dh:%dm:%is", hh, mm, ss);
            Dias();
        }
    }
}

void Dias() {
    if (hh >= 24) {
        dd++;
        hh = hh - 24;
        Dias();
    } else {
        if (mm <= 9) {
            printf("\n=====> %ddia, %dh:0%dm", dd, hh, mm);
        } else {
            printf("\n=====> %ddia, %dh:%dm", dd, hh, mm);
        }
    }
}

void Teto() {
    system("cls");
    printf("-----------------------------------------------------------\n");
    printf("| BEM VINDO AO SISTEMA VOX |\n");
    printf("-----------------------------------------------------------\n");
}
