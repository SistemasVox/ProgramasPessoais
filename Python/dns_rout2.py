import subprocess
import platform
import ipaddress
import concurrent.futures

def is_private_ip(ip):
    try:
        return ipaddress.ip_address(ip).is_private
    except ValueError:
        return False

# Lista atualizada de servidores DNS...
dns_servers = [
    # Google Public DNS
    "8.8.8.8", "8.8.4.4",
    # OpenDNS
    "208.67.222.222", "208.67.220.220", "208.67.222.220", "208.67.220.222",
    # Yandex
    "77.88.8.1", "77.88.8.8",
    # Cloudflare
    "1.1.1.1", "1.0.0.1",
    # Norton ConnectSafe Basic
    "199.85.126.10", "199.85.127.10",
    # Level 3
    "209.244.0.3", "209.244.0.4",
    "4.2.2.1", "4.2.2.2", "4.2.2.3", "4.2.2.4", "4.2.2.5", "4.2.2.6",
    # Comodo
    "8.26.56.26", "8.20.247.20", "156.154.70.22", "156.154.71.22",
    # Dyn
    "216.146.35.35", "216.146.36.36",
    # Norton DNS
    "198.153.192.1", "198.153.194.1",
    # VeriSign
    "64.6.64.6", "64.6.65.6",
    # Qwest
    "205.171.3.65", "205.171.2.65",
    # Sprint
    "204.97.212.10", "204.117.214.10",
    # Censurfridns
    "89.233.43.71", "91.239.100.100",
    # Safe DNS
    "195.46.39.39", "195.46.39.40",
    # DNS WATCH
    "84.200.69.80", "84.200.70.40",
    # FreeDNS
    "37.235.1.174", "37.235.1.177",
    # Sprintlink
    "199.2.252.10", "204.97.212.10",
    # UltraDNS
    "204.69.234.1", "204.74.101.1",
    # Zen Internet
    "212.23.8.1", "212.23.3.1",
    # Orange DNS
    "195.92.195.94", "195.92.195.95",
    # Hurricane Electric
    "74.82.42.42",
    # puntCAT
    "109.69.8.51",
    # Freenom World
    "80.80.80.80", "80.80.81.81",
    # FDN
    "80.67.169.12", "80.67.169.40",
    # Neustar
    "156.154.70.1", "156.154.71.1", "156.154.70.5", "156.154.71.5",
    # AdGuard
    "94.140.14.14", "94.140.15.15",
    # Quad9
    "9.9.9.9", "149.112.112.112", "9.9.9.10", "149.112.112.10",
    # MegaLan
    "95.111.55.251", "95.111.55.250"
]

def extract_ip_from_line(line):
    """Extrai o IP de uma linha do traceroute/tracert."""
    parts = line.split()
    for part in parts:
        if part.count('.') == 3:  # Formato básico de IPv4
            try:
                ipaddress.ip_address(part)
                return part
            except ValueError:
                continue
    return None

def get_hop_count(dns_server, ignore_private_ips):
    MAX_HOPS = 20
    os_name = platform.system().lower()
    
    try:
        # Configuração do comando com -d para Windows e sem para Linux, mas específico
        if os_name == 'linux':
            cmd = ['traceroute', dns_server]
        elif os_name == 'windows':
            cmd = ['tracert', '-d', dns_server]  # Adicionando -d aqui
        else:
            print(f'Sistema operacional {os_name} não suportado.')
            return None

        try:
            result = subprocess.run(cmd, stdout=subprocess.PIPE, text=True, check=True)
            output_lines = result.stdout.strip().split('\n')
            
            valid_hops = 0
            for line in output_lines[1:]:  # Pula a linha de cabeçalho
                if valid_hops >= MAX_HOPS:  # Se ultrapassar 20 saltos, descarta o servidor
                    print(f'Servidor {dns_server} ultrapassou {MAX_HOPS} saltos.')
                    return None
                
                ip = extract_ip_from_line(line)
                # Sempre conta a linha como um salto
                if ip or '*' in line:  # Verifica se há IP ou um asterisco na linha
                    if ip and ignore_private_ips and is_private_ip(ip):
                        continue  # Ignora IPs privados
                    valid_hops += 1

            return valid_hops if valid_hops > 0 else None

        except subprocess.CalledProcessError as e:
            print(f'Erro ao executar {cmd[0]} para {dns_server}: {e}')
            return None

    except Exception as ex:
        print(f'Ocorreu um erro: {ex}')
        return None

def ping_dns(dns_server, count=10, timeout=1):
    """Executa múltiplos pings no servidor DNS e retorna a latência média em milissegundos."""
    os_name = platform.system().lower()
    cmd = (
        ['ping', '-n', str(count), '-w', str(timeout), dns_server] if os_name == 'windows' 
        else ['ping', '-c', str(count), '-W', str(timeout), dns_server]
    )
    
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, text=True, check=True, timeout=timeout + count)  # tempo total limite
        total_time = 0
        successful_pings = 0

        if os_name == 'windows':
            for line in result.stdout.splitlines():
                if 'tempo=' in line:
                    time_part = float(line.split('tempo=')[1].split('ms')[0])
                    total_time += time_part
                    successful_pings += 1
        else:
            for line in result.stdout.splitlines():
                if 'time=' in line:
                    time_part = float(line.split('time=')[1].split(' ')[0])
                    total_time += time_part
                    successful_pings += 1
        
        if successful_pings == 0:
            return float('inf')  # Penaliza se nenhum ping foi bem sucedido
        
        return total_time / successful_pings  # Retorna a média dos tempos

    except Exception as e:
        print(f'Falha ao pingar {dns_server}: {e}')
        return float('inf')  # Penaliza se o ping falhar

def main():
    # Perguntar se deseja ignorar IPs privados
    ignore_private_ips = input("Deseja ignorar IPs privados? (s/n): ").lower() == 's'
    print(f"Ignorar IPs privados: {'Sim' if ignore_private_ips else 'Não'}")
    
    dns_hop_counts = {}
    speeds = {}
    min_hops = float('inf')
    fastest_dns = None

    # Testar todos os servidores DNS usando threading
    total_dns = len(dns_servers)
    with concurrent.futures.ThreadPoolExecutor() as executor:
        future_to_dns = {executor.submit(get_hop_count, dns, ignore_private_ips): dns for dns in dns_servers}
        
        for future in concurrent.futures.as_completed(future_to_dns):
            dns = future_to_dns[future]
            hop_count = future.result()
            if hop_count is not None:
                dns_hop_counts[dns] = hop_count
                avg_ping = ping_dns(dns)
                speeds[dns] = avg_ping

                print(f'{dns} - {hop_count} saltos, tempo médio de ping: {avg_ping:.2f} ms')

                # Lógica para determinar o melhor servidor
                if hop_count < min_hops or (hop_count == min_hops and (fastest_dns is None or avg_ping < speeds[fastest_dns])):
                    min_hops = hop_count
                    fastest_dns = dns
                    print(f'Novo melhor servidor encontrado: {fastest_dns} com {min_hops} saltos e ping médio de {avg_ping:.2f} ms.')

    # Ranking dos menores saltos
    if dns_hop_counts:
        sorted_hops = sorted(dns_hop_counts.items(), key=lambda x: x[1])  # Ordena apenas por saltos
        
        print('\nRanking de servidores DNS (menos saltos primeiro):')
        for i, (dns, hops) in enumerate(sorted_hops, start=1):
            avg_ping = speeds[dns]
            print(f'{i}. {dns} - {hops} saltos, tempo de ping médio: {avg_ping:.2f} ms')

    # Ranking dos menores pings
    if speeds:
        sorted_ping = sorted(speeds.items(), key=lambda x: x[1])  # Ordena apenas por ping
        
        print('\nRanking de servidores DNS (menor ping primeiro):')
        for i, (dns, ping) in enumerate(sorted_ping, start=1):
            hops = dns_hop_counts[dns]
            print(f'{i}. {dns} - {hops} saltos, tempo de ping: {ping:.2f} ms')

    # Ranking combinado
    if dns_hop_counts and speeds:
        sorted_combined = sorted(dns_hop_counts.items(), key=lambda x: (x[1], speeds[x[0]]))  # Ordena por saltos e ping médio

        print('\nRanking de servidores DNS (menor saltos e menor ping primeiro):')
        for i, (dns, hops) in enumerate(sorted_combined, start=1):
            avg_ping = speeds[dns]
            print(f'{i}. {dns} - {hops} saltos, tempo de ping médio: {avg_ping:.2f} ms')
            
        print('\nServidores DNS ordenados (separados por vírgulas):\n')
        # Cria uma lista de strings com os endereços DNS
        dns_list = [dns for dns, _ in sorted_combined]
        print(','.join(dns_list))
        
if __name__ == "__main__":
    main()