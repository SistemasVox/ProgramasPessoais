#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import subprocess
import time
import platform
import os
import sys
import logging
import threading
from datetime import datetime, timedelta
from concurrent.futures import ThreadPoolExecutor
import signal
import sqlite3
import csv

# Configuração de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("monitoramento_ips.log", encoding='utf-8'),
        logging.StreamHandler()
    ]
)

# Lista de IPs para monitorar
IPS = [
    "186.232.8.22",
    "186.232.8.21", 
    "186.232.8.17",
    "186.232.10.81"
]

# Configurações
WHATSAPP_NUMBER = "553491509513"
SCRIPT_ENVIO_WHATSAPP = 'send_whatsapp.py'
PING_INTERVAL = 1.0
OFFLINE_THRESHOLD = 30
PING_TIMEOUT = 3
PING_PACKET_SIZE = 756

DB_PATH = "monitoramento_ips.db"
TABLE_NAME = "logs_status"
CSV_LOG_PATH = "monitoramento_ips.csv"

def inicializar_banco():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(f"""
        CREATE TABLE IF NOT EXISTS {TABLE_NAME} (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            servidor TEXT NOT NULL,
            horario DATETIME NOT NULL,
            status INTEGER NOT NULL
        )
    """)
    cursor.execute(f"CREATE INDEX IF NOT EXISTS idx_logs_horario ON {TABLE_NAME}(horario)")
    conn.commit()
    conn.close()

def salvar_log_status(ip, horario, status):
    status_int = 1 if status == 'Online' else 0
    try:
        # SQLite
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute(
            f"INSERT INTO {TABLE_NAME} (servidor, horario, status) VALUES (?, ?, ?)",
            (ip, horario.strftime('%Y-%m-%d %H:%M:%S'), status_int)
        )
        conn.commit()
        conn.close()
        # NÃO registra log humano aqui!

        # CSV Redundância
        try:
            arquivo_existe = os.path.isfile(CSV_LOG_PATH)
            with open(CSV_LOG_PATH, mode='a', newline='', encoding='utf-8') as csvfile:
                writer = csv.writer(csvfile)
                if not arquivo_existe:
                    writer.writerow(['servidor', 'horario', 'status'])
                writer.writerow([ip, horario.strftime('%Y-%m-%d %H:%M:%S'), status_int])
        except Exception as e_csv:
            logging.error(f"Erro ao salvar log no CSV: {e_csv}")

    except Exception as e:
        logging.error(f"Erro ao salvar log no banco: {e}")

def mostrar_evento_terminal(evento: str):
    print(f"\n{evento}")

class MonitorIP:
    def __init__(self):
        self.estatisticas = {}
        self.running = True
        self.lock = threading.Lock()
        inicializar_banco()
        for ip in IPS:
            self.estatisticas[ip] = {
                'min': float('inf'),
                'max': 0,
                'atual': 0,
                'status': 'Desconhecido',
                'offline_since': None,
                'online_since': None,
                'notificado_offline': False,
                'notificado_online': False,
                'downtime_total': timedelta(0),
                'tentativas_consecutivas': 0,
                'ultimo_ping_sucesso': None
            }

    def enviar_notificacao_whatsapp(self, message, number):
        try:
            python_executable = sys.executable
            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), SCRIPT_ENVIO_WHATSAPP)
            if not os.path.exists(script_path):
                logging.error(f"CRÍTICO: O script de envio '{script_path}' não foi encontrado.")
                return False
            command = [python_executable, script_path, number, message]
            logging.info(f"Enviando notificação WhatsApp para {number}...")
            def executar_envio():
                try:
                    result = subprocess.run(
                        command, 
                        capture_output=True, 
                        text=True,
                        timeout=30,
                        encoding='utf-8',
                        errors='replace'
                    )
                    if result.returncode == 0:
                        logging.info(f"Notificação enviada com sucesso para {number}")
                    else:
                        logging.error(f"Erro no envio para {number}. Código: {result.returncode}")
                        logging.error(f"Stdout: {result.stdout}")
                        logging.error(f"Stderr: {result.stderr}")
                except subprocess.TimeoutExpired:
                    logging.error(f"Timeout ao enviar notificação para {number}")
                except Exception as e:
                    logging.error(f"Erro ao executar script de envio: {e}")
            thread_envio = threading.Thread(target=executar_envio)
            thread_envio.daemon = True
            thread_envio.start()
            return True
        except Exception as e:
            logging.error(f"Falha ao preparar envio do WhatsApp: {e}")
            return False

    def fazer_ping(self, ip):
        try:
            sistema = platform.system().lower()
            if sistema == "windows":
                comando = ["ping", "-n", "1", "-l", str(PING_PACKET_SIZE), ip]
            else:
                comando = ["ping", "-c", "1", "-s", str(PING_PACKET_SIZE), ip]
            result = subprocess.run(
                comando,
                capture_output=True,
                text=True,
                timeout=PING_TIMEOUT,
                encoding='utf-8' if sistema != "windows" else 'cp1252',
                errors='replace'
            )
            if result.returncode == 0:
                output = result.stdout.lower()
                if sistema == "windows":
                    if 'tempo=' in output:
                        for linha in output.split('\n'):
                            if 'tempo=' in linha and 'ms' in linha:
                                try:
                                    tempo_str = linha.split('tempo=')[1].split('ms')[0].strip()
                                    return int(tempo_str)
                                except (IndexError, ValueError):
                                    continue
                else:
                    if 'time=' in output:
                        for linha in output.split('\n'):
                            if 'time=' in linha and 'ms' in linha:
                                try:
                                    tempo_str = linha.split('time=')[1].split('ms')[0].strip()
                                    return float(tempo_str)
                                except (IndexError, ValueError):
                                    continue
            return None
        except subprocess.TimeoutExpired:
            logging.debug(f"Timeout no ping para {ip}")
            return None
        except Exception as e:
            logging.error(f"Erro no ping para {ip}: {e}")
            return None

    def formatar_duracao(self, duracao):
        if isinstance(duracao, (int, float)):
            duracao = timedelta(seconds=duracao)
        dias = duracao.days
        horas, resto = divmod(duracao.seconds, 3600)
        minutos, segundos = divmod(resto, 60)
        return f"{dias:02d} {horas:02d}:{minutos:02d}:{segundos:02d}"

    def processar_resultado_ping(self, ip, tempo_ping):
        agora = datetime.now()
        with self.lock:
            stats = self.estatisticas[ip]
            status_atual = stats['status']
            if tempo_ping is None:
                stats['tentativas_consecutivas'] += 1
                if status_atual in ['Desconhecido', 'Online']:
                    if stats['tentativas_consecutivas'] >= 2:
                        stats['status'] = 'Offline'
                        stats['offline_since'] = agora
                        stats['notificado_offline'] = False
                        stats['notificado_online'] = False
                        salvar_log_status(ip, agora, 'Offline')
                        mostrar_evento_terminal(f"🔴 {ip} ficou OFFLINE em {agora.strftime('%Y-%m-%d %H:%M:%S')}")
                        logging.warning(f"🔴 IP {ip} ficou OFFLINE em {agora.strftime('%Y-%m-%d %H:%M:%S')}")
                if (stats['status'] == 'Offline' and 
                    stats['offline_since'] and 
                    not stats['notificado_offline']):
                    tempo_offline = agora - stats['offline_since']
                    if tempo_offline.total_seconds() >= OFFLINE_THRESHOLD:
                        mensagem = (f"🚨 ALERTA: Servidor {ip} está OFFLINE!\n"
                                   f"⏰ Desde: {stats['offline_since'].strftime('%d/%m/%Y %H:%M:%S')}\n"
                                   f"⏱️ Há: {self.formatar_duracao(tempo_offline)} (dd hh:mm:ss)")
                        self.enviar_notificacao_whatsapp(mensagem, WHATSAPP_NUMBER)
                        stats['notificado_offline'] = True
                        logging.critical(f"📱 NOTIFICAÇÃO OFFLINE ENVIADA para {ip}")

            else:
                stats['tentativas_consecutivas'] = 0
                stats['ultimo_ping_sucesso'] = agora
                if status_atual == 'Offline':
                    tempo_offline = agora - stats['offline_since'] if stats['offline_since'] else timedelta(0)
                    stats['downtime_total'] += tempo_offline
                    if tempo_offline.total_seconds() >= OFFLINE_THRESHOLD and not stats['notificado_online']:
                        duracao_formatada = self.formatar_duracao(tempo_offline)
                        mensagem = (f"✅ SERVIDOR RECUPERADO: {ip}\n"
                                   f"⏰ Caiu em: {stats['offline_since'].strftime('%d/%m/%Y %H:%M:%S')}\n"
                                   f"⏰ Voltou em: {agora.strftime('%d/%m/%Y %H:%M:%S')}\n"
                                   f"⏱️ Tempo offline: {duracao_formatada} (dd hh:mm:ss)")
                        self.enviar_notificacao_whatsapp(mensagem, WHATSAPP_NUMBER)
                        stats['notificado_online'] = True
                        logging.info(f"📱 NOTIFICAÇÃO RECUPERAÇÃO ENVIADA para {ip}")
                    stats['status'] = 'Online'
                    stats['online_since'] = agora
                    salvar_log_status(ip, agora, 'Online')
                    mostrar_evento_terminal(f"🟢 {ip} voltou ONLINE em {agora.strftime('%d/%m/%Y %H:%M:%S')}")
                    logging.info(f"🟢 IP {ip} voltou ONLINE após {self.formatar_duracao(tempo_offline)}")
                elif status_atual == 'Desconhecido':
                    stats['status'] = 'Online'
                    stats['online_since'] = agora
                    salvar_log_status(ip, agora, 'Online')
                    mostrar_evento_terminal(f"🟢 {ip} está ONLINE em {agora.strftime('%d/%m/%Y %H:%M:%S')}")
                    logging.info(f"🟢 IP {ip} está ONLINE")
                stats['atual'] = tempo_ping
                if stats['min'] == float('inf'):
                    stats['min'] = tempo_ping
                else:
                    stats['min'] = min(stats['min'], tempo_ping)
                stats['max'] = max(stats['max'], tempo_ping)

    def monitorar_ip_individual(self, ip):
        while self.running:
            try:
                tempo_ping = self.fazer_ping(ip)
                self.processar_resultado_ping(ip, tempo_ping)
            except Exception as e:
                logging.error(f"Erro no monitoramento de {ip}: {e}")
            time.sleep(PING_INTERVAL)

    def signal_handler(self, signum, frame):
        logging.info("🛑 Recebido sinal de interrupção. Encerrando...")
        self.running = False

    def executar(self):
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        logging.info("🚀 Iniciando monitoramento de IPs...")
        print("🖥️  Monitor de Servidores Iniciado")
        print("Somente eventos críticos serão exibidos no terminal.")
        threads = []
        with ThreadPoolExecutor(max_workers=len(IPS)) as executor:
            futures = [executor.submit(self.monitorar_ip_individual, ip) for ip in IPS]
            try:
                while self.running:
                    time.sleep(1)
            except KeyboardInterrupt:
                pass
            finally:
                self.running = False
                for future in futures:
                    future.cancel()
        print("\n🛑 Monitoramento encerrado.")
        logging.info("🛑 Monitoramento encerrado pelo usuário.")

if __name__ == "__main__":
    monitor = MonitorIP()
    try:
        monitor.executar()
    except Exception as e:
        logging.error(f"❌ Erro fatal no monitoramento: {e}")
        sys.exit(1)