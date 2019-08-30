/* 
 * File:   MinutosSimples.cpp
 * Author: Marcelo
 *
 * Created on 24 de Janeiro de 2017, 00:37
 */

#include <stdio.h> // printf scanf

int main() {
    long int n = 0, h = 0, m = 0;
    scanf("%d", &n);
    h = n / 60;
    m = n % 60;
    printf("\n\n> %dh e %dmin", h, m);
    return 0;
}