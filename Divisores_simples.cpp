/* 
 * File:   Divisores_simples.cpp
 * Author: Marcelo
 *
 * Created on 04 de Abril de 2017, 01:05
 */

#include <stdio.h> // printf scanf

int main() {
    long int n = 0;
    int i;
    scanf("%d", &n);
    for (i = 1; i <= (n / 2); i++) {
        if (n % i == 0) {
            printf("\n %d", i);
        }
    }
    printf("\n\n> %d", n);
    return 0;
}
