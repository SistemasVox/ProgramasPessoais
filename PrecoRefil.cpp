/* 
 * File:   PrecoRefil.cpp
 * Author: Marcelo
 *
 * Created on 21 de Outubro de 2017, 15:51
 */
 
#include<stdio.h>
#include<stdlib.h>
int main()
{
	double preco_refil, qtd_refil, preco_produto, qtd_produto;
	printf("Use ponto para decimais.\n");
	printf("Qual quantidade ml/kg do Normal? : ");
	scanf("%lf", &qtd_produto);
	printf("\nQual o preco do Normal? : ");
	scanf("%lf", &preco_produto);
	printf("\nQual quantidade ml/kg do refil? : ");
	scanf("%lf", &qtd_refil);
	printf("\nQual o preco do refil? : ");
	scanf("%lf", &preco_refil);

	printf("\n\n");

	double total_produto = 0, total_refil = 0;
	total_produto = preco_produto / qtd_produto;
	total_refil = preco_refil / qtd_refil;
	printf("Preco do produto, R$: %lf ml.kg/$$.", total_produto);
	printf("\nPreco do refil, R$: %lf ml.kg/$$.", total_refil);
	printf("\nO refil sai a %.1lf %% mais barato.",
		   (((total_produto - total_refil) * 100) / total_produto));
	return 0;
}
