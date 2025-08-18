// speedtest-module.js
const http = require('http');
const https = require('https');
const { URL } = require('url');

// Configurações
const CHUNK_SIZE = 10 * 1024 * 1024; // 10 MB
const TIMEOUT = 15000; // 15 segundos
const MAX_REDIRECTS = 3;
const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36';

// URLs para teste
const TEST_FILE_URLS = [
    "https://debian.c3sl.ufpr.br/debian-cd/12.11.0-live/amd64/iso-hybrid/debian-live-12.11.0-amd64-mate.iso",
    "https://mirrors.ic.unicamp.br/archlinux/iso/2025.06.01/archlinux-x86_64.iso",
    "http://ubuntu.linux.n0c.ca/ubuntu-cdimage/20.04/ubuntu-20.04.6-desktop-amd64.iso",
    "https://mint.c3sl.ufpr.br/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso"
];

/**
 * Extrai o nome do ficheiro a partir de uma URL.
 * @param {string} url A URL do ficheiro.
 * @returns {string} O nome do ficheiro.
 */
function extractFileName(url) {
    const parsed = new URL(url);
    const path = parsed.pathname;
    const segments = path.split('/');
    const fullName = segments.pop() || ''; 
    return fullName;
}

/**
 * Verifica a disponibilidade de uma URL e se ela suporta 'Range requests'.
 * @param {string} fileUrl A URL a ser verificada.
 * @returns {Promise<object>} Um objeto com o status da URL.
 */
async function checkUrlAvailability(fileUrl) {
    let currentUrl = fileUrl;
    let redirectCount = 0;
    
    while (redirectCount <= MAX_REDIRECTS) {
        const parsedUrl = new URL(currentUrl);
        const protocol = parsedUrl.protocol === 'https:' ? https : http;

        const options = {
            hostname: parsedUrl.hostname,
            path: parsedUrl.pathname + parsedUrl.search,
            method: 'HEAD',
            timeout: TIMEOUT,
            headers: { 'User-Agent': USER_AGENT }
        };

        try {
            const response = await new Promise((resolve, reject) => {
                const req = protocol.request(options, resolve);
                req.on('error', reject);
                req.on('timeout', () => {
                    req.destroy();
                    reject(new Error('Timeout'));
                });
                req.end();
            });

            if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
                redirectCount++;
                const location = response.headers.location;
                if (location) {
                    currentUrl = new URL(location, currentUrl).href;
                    continue;
                }
            }

            const available = response.statusCode >= 200 && response.statusCode < 400;
            let supportsRange = false;

            if (available) {
                if (response.headers['accept-ranges'] === 'bytes' || response.headers['content-length']) {
                    supportsRange = true;
                }
            }

            return {
                available,
                supportsRange,
                protocol,
                finalUrl: currentUrl
            };
            
        } catch (error) {
            return { 
                available: false, 
                supportsRange: false,
                error: error.message
            };
        }
    }
    
    return { 
        available: false, 
        supportsRange: false,
        error: 'Too many redirects'
    };
}

/**
 * Realiza o download de um pedaço do ficheiro para medir a velocidade.
 * @param {object} fileInfo Objeto com informações do ficheiro (url, protocol).
 * @returns {Promise<number>} A velocidade de download em Mbps.
 */
async function downloadSpeedTest(fileInfo) {
    return new Promise((resolve, reject) => {
        const { url, protocol } = fileInfo;
        const parsedUrl = new URL(url);
        let bytesDownloaded = 0;
        
        const options = {
            hostname: parsedUrl.hostname,
            path: parsedUrl.pathname + parsedUrl.search,
            headers: { 
                'User-Agent': USER_AGENT,
                'Range': `bytes=0-${CHUNK_SIZE - 1}`
            },
            timeout: TIMEOUT
        };

        const startTime = Date.now();
        const req = protocol.request(options, (res) => {
            if (res.statusCode !== 206 && res.statusCode !== 200) {
                return reject(new Error(`Código inválido: ${res.statusCode}`));
            }

            res.on('data', (chunk) => {
                bytesDownloaded += chunk.length;
                if (bytesDownloaded >= CHUNK_SIZE) {
                    req.destroy();
                }
            });

            res.on('end', () => {
                const duration = (Date.now() - startTime) / 1000;
                if (duration === 0) {
                    resolve(0); // Evita divisão por zero
                    return;
                }
                const speed = (bytesDownloaded * 8) / (duration * 1000000);
                resolve(speed);
            });
        });

        req.on('error', reject);
        req.on('timeout', () => {
            req.destroy();
            reject(new Error('Timeout de download'));
        });
        
        req.end();
    });
}

/**
 * Orquestra o processo de teste de velocidade.
 * @returns {Promise<number>} A velocidade média de download em Mbps.
 */
async function runSpeedTest() {
    console.log('Módulo de Speedtest: Validando URLs...');
    const validUrls = [];
    
    for (const fileUrl of TEST_FILE_URLS) {
        try {
            const result = await checkUrlAvailability(fileUrl);
            if (result.available && result.supportsRange) {
                validUrls.push({
                    url: result.finalUrl,
                    protocol: result.protocol,
                    fileName: extractFileName(result.finalUrl)
                });
            }
        } catch (error) {
            // Ignora falhas na verificação de uma URL individual
        }
    }
    
    if (validUrls.length === 0) {
        console.log('\n❌ Módulo de Speedtest: Nenhum servidor válido encontrado.');
        return 0;
    }
    
    console.log('\nTestando velocidades...');
    const speeds = [];
    
    for (const fileInfo of validUrls) {
        try {
            const speed = await downloadSpeedTest(fileInfo);
            speeds.push(speed);
            console.log(`- ${fileInfo.fileName}: ${speed.toFixed(2)} Mbps`);
        } catch (error) {
            // Ignora falhas em um teste de download individual
        }
    }
    
    if (speeds.length > 0) {
        const averageSpeed = speeds.reduce((sum, speed) => sum + speed, 0) / speeds.length;
        console.log(`\nVelocidade média calculada: ${averageSpeed.toFixed(2)} Mbps`);
        console.log(`Baseada em ${speeds.length} servidor(es)`);
        
        return averageSpeed; 
    } else {
        console.log('\n❌ Módulo de Speedtest: Todos os testes falharam.');
        return 0;
    }
}

module.exports = {
    runSpeedTest
};