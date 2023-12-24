#include <stdio.h>
#include <locale.h>

int main() {
    setlocale(LC_ALL, "Portuguese");

    // Propriedades dos combust�veis
    float teorEtanolGasolina = 0.27; // Porcentagem de etanol na gasolina
    float purezaEtanol = 0.95; // Pureza do etanol puro
    float volumeTotalCombustivel = 35.92; // Volume total de combust�vel a ser abastecido

    // Pre�os dos combust�veis em reais por litro
    float precoLitroGasolina = 4.99;
    float precoLitroEtanol = 3.06;

    // Propor��o desejada de gasolina no total (50%)
    float proporcaoGasolinaDesejada = (50.0 / 100.0); // Propor��o de gasolina no total, em litros

    // C�lculo corrigido da quantidade de gasolina e etanol
    float volumeGasolinaPura = proporcaoGasolinaDesejada * volumeTotalCombustivel;
    float volumeEtanolEmGasolinaPura = volumeGasolinaPura * teorEtanolGasolina;
    float volumeEtanolPuroAdicional = (volumeTotalCombustivel - volumeGasolinaPura - volumeEtanolEmGasolinaPura) / purezaEtanol;

    // Ajustando o volume de gasolina e etanol puro para atingir a propor��o desejada
    float volumeGasolinaFinal = volumeGasolinaPura + volumeEtanolEmGasolinaPura;
    float volumeEtanolFinal = volumeEtanolPuroAdicional * purezaEtanol;

    // Calculando o custo em reais
    float custoGasolina = volumeGasolinaFinal * precoLitroGasolina;
    float custoEtanol = volumeEtanolFinal * precoLitroEtanol;
    float custoTotal = custoGasolina + custoEtanol;

    // Exibindo os resultados
    printf("Volume total de combust�vel: %.2f litros\n", volumeTotalCombustivel);
    printf("Propor��o de gasolina m�nima desejada: %.2f %%\n", (proporcaoGasolinaDesejada * 100.00));
    printf("Volume de gasolina: %.2f litros\n", volumeGasolinaFinal);
    printf("Volume de etanol: %.2f litros\n", volumeEtanolFinal);
    printf("Custo em reais:\n");
    printf("  Gasolina: R$ %.2f\n", custoGasolina);
    printf("  Etanol: R$ %.2f\n", custoEtanol);
    printf("Custo total: R$ %.2f\n", custoTotal);

    // Verificando se compensa adicionar etanol (se o pre�o do etanol for 70% ou mais caro que a gasolina)
    float porcentagemDiferenca = (precoLitroEtanol / precoLitroGasolina * 100.0) - 100.0;
    printf("Adicionar etanol %s compensa (diferen�a de %.2f%% em rela��o � gasolina).\n",
           (precoLitroEtanol >= 1.7 * precoLitroGasolina) ? "n�o" : "pode", porcentagemDiferenca);

    return 0;
}

