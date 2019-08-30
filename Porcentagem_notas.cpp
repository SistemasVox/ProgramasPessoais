/* 
 * File:   Porcentagem_notas.cpp
 * Author: Marcelo
 *
 * Created on 04 de Abril de 2017, 01:05
 */

#include <stdio.h> // printf scanf

int main() {
    double v, t, r;
    printf("Valor obtido: ");
    scanf("%lf", & v);

    printf("Valor total: ");
    scanf("%lf", & t);

    r = (v * 100) / t;

    printf("\n\n>> %.1lf%%", r);
    return 0;
}