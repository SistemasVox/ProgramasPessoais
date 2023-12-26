import subprocess
import platform

# Lista de servidores DNS
dns_servers = [
    "1.0.0.1", "9.9.9.9", "9.9.9.10", "1.1.1.1",
    "156.154.71.22", "216.146.35.35", "216.146.36.36",
    "156.154.70.22", "208.67.222.222", "8.8.8.8",
    "8.8.4.4", "208.67.220.220", "8.26.56.26", "8.20.247.20"
]

def get_hop_count(dns_server):
    os_name = platform.system().lower()
    try:
        # Determinar o comando com base no sistema operacional
        if os_name == 'linux':
            cmd = ['traceroute', dns_server]
        elif os_name == 'windows':
            cmd = ['tracert', dns_server]
        else:
            print(f'Sistema operacional {os_name} não suportado.')
            return None

        # Executar o comando e capturar a saída
        result = subprocess.run(cmd, stdout=subprocess.PIPE, text=True, check=True)

        # Analisar a saída para encontrar a quantidade de saltos
        output_lines = result.stdout.strip().split('\n')
        hop_count = len(output_lines) - 1  # Subtrair 1 para excluir a linha de cabeçalho
        return hop_count
    except subprocess.CalledProcessError as e:
        print(f'Erro ao executar {cmd[0]} para {dns_server}: {e}')
        return None

# Inicializar variáveis para armazenar os resultados e o melhor servidor encontrado
dns_hop_counts = {}
min_hops = float('inf')
fastest_dns = None

# Testar todos os servidores DNS
total_dns = len(dns_servers)
for i, dns in enumerate(dns_servers, start=1):
    print(f'Testando {dns} ({i}/{total_dns})...')
    hop_count = get_hop_count(dns)
    if hop_count is not None:
        dns_hop_counts[dns] = hop_count
        # Atualizar o melhor servidor encontrado, se necessário
        if hop_count < min_hops:
            min_hops = hop_count
            fastest_dns = dns
            print(f'Novo melhor servidor encontrado: {fastest_dns} com {min_hops} saltos.')

# Ordenar os servidores DNS pelo número de saltos (ascendente)
sorted_dns = sorted(dns_hop_counts.items(), key=lambda x: x[1])

# Imprimir o ranking
print('Ranking de servidores DNS (menos saltos primeiro):')
for i, (dns, hops) in enumerate(sorted_dns, start=1):
    print(f'{i}. {dns} - {hops} saltos')
    
# Imprimir os servidores DNS ordenados, separados por vírgulas
sorted_dns_addresses = [item[0] for item in sorted_dns]
print(','.join(sorted_dns_addresses))
