// meu-app.js

// Importa o módulo de teste de velocidade.
const { runSpeedTest } = require('./speedtest-module.js');

// Função principal da aplicação.
async function iniciarMeuApp() {
    console.log('Bem-vindo ao meu Speedtest!');
    console.log('Vamos iniciar o teste de velocidade para verificar a sua conexão...');

    try {
        // Executa o teste de velocidade e aguarda o resultado.
        const velocidadeFinal = await runSpeedTest();

        console.log('\n----------------------------------------');
        console.log('Teste de velocidade concluído no Speedtest!');

        // Processa e exibe o resultado do teste.
        if (velocidadeFinal > 0) {
            console.log(`A velocidade de download obtida foi: ${velocidadeFinal.toFixed(2)} Mbps`);
        } else {
            console.log('Não foi possível determinar a velocidade da conexão.');
        }
        console.log('----------------------------------------');

    } catch (error) {
        // Captura e exibe erros do processo.
        console.error('Ocorreu um erro grave durante o teste de velocidade:', error);
    }

    console.log('\nSeu teste terminou a sua execução.');
}

// Inicia a aplicação.
iniciarMeuApp();