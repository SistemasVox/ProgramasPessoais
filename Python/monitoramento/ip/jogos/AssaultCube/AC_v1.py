import socket
import threading
import time
from datetime import datetime
import re
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext

# Configurações
masterserver_host = "ms.cubers.net"
masterserver_port = 28760

# Configurações padrão
DEFAULT_MIN_PLAYERS = 5
DEFAULT_FAVORITE_MAPS = "village,casa,kasa,shine"
DEFAULT_CHECK_INTERVAL = 60

# Nomes dos modos de jogo
mode_names = [
    "DEMO", "TDM", "coop", "DM", "SURV", "TSURV", "CTF", "PF", "BTDM", "BDM", "LSS",
    "OSOK", "TOSOK", "BOSOK", "HTF", "TKTF", "KTF", "TPF", "TLSS", "BPF", "BLSS", "BTSURV", "BTOSOK"
]

class ReadBuffer:
    """Classe para ler dados do protocolo AssaultCube"""
    def __init__(self, data):
        self._data = data
        self._position = 0

    def has_more(self):
        return self._position < len(self._data)

    def get_uchar(self):
        if self.has_more():
            uchar = self._data[self._position]
            self._position += 1
            return uchar
        else:
            raise Exception("Mensagem muito curta")

    def get_int(self):
        uchar = self.get_uchar()
        if uchar == 0x80:
            ushort = self.get_uchar() | self.get_uchar() << 8
            return ushort if ushort < 0x8000 else ushort - 0x10000
        elif uchar == 0x81:
            uint = self.get_uchar() | self.get_uchar() << 8 | self.get_uchar() << 16 | self.get_uchar() << 24
            return uint if uint < 0x80000000 else uint - 0x100000000
        else:
            return uchar if uchar < 0x80 else uchar - 0x100

    def get_string(self):
        start = self._position
        while self.has_more():
            if self.get_uchar() == 0:
                break
        return self._data[start:self._position - 1].decode("ascii", "ignore")

def get_server_list(retries=3):
    """Obtém a lista de servidores do masterserver usando HTTP (método oficial)"""
    import urllib.request
    import urllib.error
    
    # Parâmetros do cliente oficial AssaultCube 1.3.0.2
    params = {
        'action': 'list',
        'name': 'AssaultCube',  # Nome do nosso cliente
        'version': '1302',      # Versão do protocolo (AC 1.3.0.2)
        'build': '0'            # Build
    }
    
    # Construir URL com parâmetros
    base_url = f"http://{masterserver_host}/retrieve.do"
    query_string = '&'.join([f"{k}={v}" for k, v in params.items()])
    url = f"{base_url}?{query_string}"
    
    last_error = None
    
    for attempt in range(retries):
        try:
            # Fazer requisição HTTP como o cliente oficial
            req = urllib.request.Request(url)
            req.add_header('User-Agent', 'AssaultCube/1.3.0.2')
            
            with urllib.request.urlopen(req, timeout=10) as response:
                data = response.read().decode('utf-8')
                return data
                
        except urllib.error.HTTPError as e:
            last_error = f"HTTP Error {e.code} na tentativa {attempt + 1}/{retries}: {e.reason}"
            if attempt < retries - 1:
                time.sleep(2)
                continue
        except urllib.error.URLError as e:
            last_error = f"URL Error na tentativa {attempt + 1}/{retries}: {e.reason}"
            if attempt < retries - 1:
                time.sleep(2)
                continue
        except Exception as e:
            last_error = f"Erro na tentativa {attempt + 1}/{retries}: {type(e).__name__}: {e}"
            if attempt < retries - 1:
                time.sleep(2)
                continue
    
    # Se chegou aqui, todas as tentativas falharam
    print(f"Falha após {retries} tentativas. Último erro: {last_error}")
    return None

def parse_response(response):
    """Extrai os servidores da resposta do masterserver"""
    lines = response.split('\n')
    servers = []

    for line in lines:
        if line.startswith('addserver'):
            parts = line.split()
            if len(parts) == 3:
                ip = parts[1]
                port = int(parts[2])
                servers.append((ip, port))

    return servers

def query_server(ip, port, timeout=0.8):
    """Consulta informações de um servidor específico"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    
    info_port = port + 1
    address = (ip, info_port)
    
    try:
        sock.sendto(b"\x01\x02\x65\x6E", address)
        data, _ = sock.recvfrom(4096)
        
        buf = ReadBuffer(data[4:])
        
        protocol = buf.get_int()
        mode = buf.get_int()
        current_players = buf.get_int()
        minutes_remaining = buf.get_int()
        map_name = buf.get_string()
        server_description = buf.get_string()
        max_players = buf.get_int()
        
        server_description = re.sub(r'\f.', '', server_description)
        map_name = re.sub(r'\f.', '', map_name)
        
        mode_name = mode_names[mode + 1] if -1 <= mode < len(mode_names) - 1 else "Desconhecido"
        
        return {
            'ip': ip,
            'port': port,
            'map': map_name,
            'mode': mode_name,
            'players': current_players,
            'max_players': max_players,
            'description': server_description,
            'minutes_remaining': minutes_remaining
        }
        
    except:
        return None
    finally:
        sock.close()

def query_servers_parallel(servers, max_workers=20):
    """Consulta múltiplos servidores em paralelo"""
    from concurrent.futures import ThreadPoolExecutor, as_completed
    
    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_server = {executor.submit(query_server, ip, port): (ip, port) 
                           for ip, port in servers}
        
        for future in as_completed(future_to_server):
            try:
                result = future.result()
                if result:
                    results.append(result)
            except:
                pass
    
    return results

class AssaultCubeMonitor:
    def __init__(self, root):
        self.root = root
        self.root.title("AssaultCube - Monitor de Servidores")
        self.root.geometry("1000x700")
        self.root.resizable(True, True)
        
        # Tema Cyberpunk
        self.setup_cyberpunk_theme()
        
        self.monitoring = False
        self.monitor_thread = None
        self.notification_history = set()
        
        self.setup_ui()
    
    def setup_cyberpunk_theme(self):
        """Configura o tema cyberpunk"""
        # Cores Cyberpunk
        self.bg_dark = "#0a0e27"  # Azul escuro profundo
        self.bg_medium = "#1a1f3a"  # Azul médio
        self.accent_cyan = "#00f0ff"  # Ciano neon
        self.accent_magenta = "#ff00ff"  # Magenta neon
        self.accent_purple = "#bd00ff"  # Roxo neon
        self.accent_yellow = "#ffff00"  # Amarelo neon
        self.accent_green = "#00ff41"  # Verde neon
        self.text_color = "#e0e0e0"  # Texto claro
        self.highlight_bg = "#2d1b69"  # Roxo escuro para destaque
        
        # Configurar estilo
        style = ttk.Style()
        style.theme_use('clam')
        
        # Configurar cores do tema
        self.root.configure(bg=self.bg_dark)
        
        # LabelFrame
        style.configure('TLabelframe', 
                       background=self.bg_dark,
                       bordercolor=self.accent_cyan,
                       borderwidth=2)
        style.configure('TLabelframe.Label',
                       background=self.bg_dark,
                       foreground=self.accent_cyan,
                       font=('Consolas', 10, 'bold'))
        
        # Labels
        style.configure('TLabel',
                       background=self.bg_dark,
                       foreground=self.text_color,
                       font=('Consolas', 9))
        
        # Entry
        style.configure('TEntry',
                       fieldbackground=self.bg_medium,
                       foreground=self.accent_cyan,
                       bordercolor=self.accent_purple,
                       borderwidth=2)
        
        # Buttons
        style.configure('TButton',
                       background=self.bg_medium,
                       foreground=self.accent_cyan,
                       bordercolor=self.accent_magenta,
                       borderwidth=2,
                       font=('Consolas', 9, 'bold'))
        style.map('TButton',
                 background=[('active', self.accent_purple)],
                 foreground=[('active', '#ffffff')])
        
        # Frame
        style.configure('TFrame',
                       background=self.bg_dark)
        
    def setup_ui(self):
        """Configura a interface"""
        
        # Frame de configurações
        config_frame = ttk.LabelFrame(self.root, text="⚙️ CONFIGURAÇÕES DO SISTEMA", padding=10)
        config_frame.pack(fill=tk.X, padx=10, pady=5)
        
        # Linha 1: Mínimo de jogadores
        ttk.Label(config_frame, text="Mínimo de jogadores:").grid(row=0, column=0, sticky=tk.W, padx=5)
        self.min_players_var = tk.StringVar(value=str(DEFAULT_MIN_PLAYERS))
        entry1 = ttk.Entry(config_frame, textvariable=self.min_players_var, width=10,
                          font=('Consolas', 10, 'bold'))
        entry1.grid(row=0, column=1, padx=5)
        
        # Linha 1: Mapas favoritos
        ttk.Label(config_frame, text="Mapas favoritos (separados por vírgula):").grid(row=0, column=2, sticky=tk.W, padx=20)
        self.favorite_maps_var = tk.StringVar(value=DEFAULT_FAVORITE_MAPS)
        entry2 = ttk.Entry(config_frame, textvariable=self.favorite_maps_var, width=30,
                          font=('Consolas', 10, 'bold'))
        entry2.grid(row=0, column=3, padx=5)
        
        # Linha 2: Intervalo
        ttk.Label(config_frame, text="Intervalo (segundos):").grid(row=1, column=0, sticky=tk.W, padx=5, pady=5)
        self.interval_var = tk.StringVar(value=str(DEFAULT_CHECK_INTERVAL))
        entry3 = ttk.Entry(config_frame, textvariable=self.interval_var, width=10,
                          font=('Consolas', 10, 'bold'))
        entry3.grid(row=1, column=1, padx=5, pady=5)
        
        # Botões de controle
        button_frame = ttk.Frame(self.root)
        button_frame.pack(fill=tk.X, padx=10, pady=5)
        
        self.start_button = ttk.Button(button_frame, text="▶️ INICIAR MONITOR", command=self.start_monitoring)
        self.start_button.pack(side=tk.LEFT, padx=5)
        
        self.stop_button = ttk.Button(button_frame, text="⏹️ PARAR MONITOR", command=self.stop_monitoring, state=tk.DISABLED)
        self.stop_button.pack(side=tk.LEFT, padx=5)
        
        ttk.Button(button_frame, text="🔍 BUSCAR AGORA", command=self.single_search).pack(side=tk.LEFT, padx=5)
        ttk.Button(button_frame, text="🗑️ LIMPAR LOG", command=self.clear_log).pack(side=tk.LEFT, padx=5)
        
        # Status com estilo cyberpunk
        self.status_var = tk.StringVar(value="⏸️ AGUARDANDO...")
        status_label = tk.Label(button_frame, textvariable=self.status_var, 
                               font=('Consolas', 10, 'bold'),
                               bg=self.bg_dark, fg=self.accent_yellow,
                               padx=10, pady=5)
        status_label.pack(side=tk.RIGHT, padx=10)
        
        # Frame da tabela de servidores
        table_frame = ttk.LabelFrame(self.root, text="🎮 SERVIDORES ATIVOS", padding=5)
        table_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)
        
        # Scrollbar para a tabela
        tree_scroll = ttk.Scrollbar(table_frame)
        tree_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        
        # Treeview para exibir servidores
        columns = ("Jogadores", "Mapa", "Modo", "Tempo", "Descrição", "IP:Porta")
        self.tree = ttk.Treeview(table_frame, columns=columns, show='tree headings', 
                                 yscrollcommand=tree_scroll.set, height=15)
        tree_scroll.config(command=self.tree.yview)
        
        # Configurar colunas (proporções para responsividade)
        self.tree.column("#0", width=30, minwidth=30, stretch=False)
        self.tree.column("Jogadores", width=90, minwidth=70, anchor=tk.CENTER)
        self.tree.column("Mapa", width=150, minwidth=100)
        self.tree.column("Modo", width=80, minwidth=60, anchor=tk.CENTER)
        self.tree.column("Tempo", width=70, minwidth=60, anchor=tk.CENTER)
        self.tree.column("Descrição", width=300, minwidth=150)
        self.tree.column("IP:Porta", width=150, minwidth=120)
        
        # Cabeçalhos
        self.tree.heading("#0", text="⭐")
        self.tree.heading("Jogadores", text="JOGADORES")
        self.tree.heading("Mapa", text="MAPA")
        self.tree.heading("Modo", text="MODO")
        self.tree.heading("Tempo", text="TEMPO")
        self.tree.heading("Descrição", text="DESCRIÇÃO")
        self.tree.heading("IP:Porta", text="IP:PORTA")
        
        # Estilo Cyberpunk para Treeview
        style = ttk.Style()
        style.configure("Treeview",
                       background=self.bg_medium,
                       foreground=self.text_color,
                       fieldbackground=self.bg_medium,
                       borderwidth=0,
                       font=('Consolas', 9))
        style.configure("Treeview.Heading",
                       background=self.bg_dark,
                       foreground=self.accent_cyan,
                       borderwidth=2,
                       relief="flat",
                       font=('Consolas', 9, 'bold'))
        style.map('Treeview.Heading',
                 background=[('active', self.accent_purple)])
        style.map('Treeview',
                 background=[('selected', self.accent_purple)],
                 foreground=[('selected', '#ffffff')])
        
        self.tree.pack(fill=tk.BOTH, expand=True)
        
        # Bind para copiar IP ao clicar duas vezes
        self.tree.bind("<Double-1>", self.on_server_double_click)
        
        # Frame de log
        log_frame = ttk.LabelFrame(self.root, text="📋 LOG DO SISTEMA", padding=5)
        log_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)
        
        self.log_text = scrolledtext.ScrolledText(log_frame, height=8, wrap=tk.WORD, 
                                                   font=('Consolas', 9),
                                                   bg=self.bg_medium,
                                                   fg=self.text_color,
                                                   insertbackground=self.accent_cyan,
                                                   selectbackground=self.accent_purple,
                                                   selectforeground='#ffffff',
                                                   borderwidth=0,
                                                   highlightthickness=2,
                                                   highlightbackground=self.accent_cyan,
                                                   highlightcolor=self.accent_magenta)
        self.log_text.pack(fill=tk.BOTH, expand=True)
        
        # Configurar tags de cores para o log (cores cyberpunk)
        self.log_text.tag_config("info", foreground=self.accent_cyan)
        self.log_text.tag_config("success", foreground=self.accent_green)
        self.log_text.tag_config("warning", foreground=self.accent_yellow)
        self.log_text.tag_config("error", foreground="#ff0055")
        self.log_text.tag_config("highlight", foreground=self.accent_magenta, font=('Consolas', 9, 'bold'))
        
        self.log("╔══════════════════════════════════════════════════════════════════╗", "info")
        self.log("║  BEM-VINDO AO MONITOR DE SERVIDORES ASSAULTCUBE [CYBERPUNK]     ║", "highlight")
        self.log("╚══════════════════════════════════════════════════════════════════╝", "info")
        self.log(">>> Configure os parâmetros e clique em 'INICIAR MONITOR'", "success")
        
    def log(self, message, tag="info"):
        """Adiciona mensagem ao log"""
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.log_text.insert(tk.END, f"[{timestamp}] {message}\n", tag)
        self.log_text.see(tk.END)
        
    def clear_log(self):
        """Limpa o log"""
        self.log_text.delete(1.0, tk.END)
        self.log("Log limpo.", "info")
        
    def get_favorite_maps(self):
        """Retorna lista de mapas favoritos"""
        maps = self.favorite_maps_var.get().strip()
        return [m.strip().lower() for m in maps.split(',') if m.strip()]
    
    def is_map_favorite(self, map_name):
        """Verifica se o mapa é favorito"""
        map_lower = map_name.lower()
        return any(fav in map_lower for fav in self.get_favorite_maps())
    
    def start_monitoring(self):
        """Inicia o monitoramento"""
        if not self.monitoring:
            self.monitoring = True
            self.start_button.config(state=tk.DISABLED)
            self.stop_button.config(state=tk.NORMAL)
            self.status_var.set("▶️ MONITORANDO...")
            
            self.monitor_thread = threading.Thread(target=self.monitor_loop, daemon=True)
            self.monitor_thread.start()
            
            self.log(">>> MONITOR INICIADO! <<<", "success")
    
    def stop_monitoring(self):
        """Para o monitoramento"""
        if self.monitoring:
            self.monitoring = False
            self.start_button.config(state=tk.NORMAL)
            self.stop_button.config(state=tk.DISABLED)
            self.status_var.set("⏹️ PARADO")
            
            self.log(">>> Monitor parado <<<", "warning")
    
    def monitor_loop(self):
        """Loop principal de monitoramento"""
        while self.monitoring:
            self.search_servers()
            
            if self.monitoring:
                try:
                    interval = int(self.interval_var.get())
                except:
                    interval = DEFAULT_CHECK_INTERVAL
                
                for i in range(interval):
                    if not self.monitoring:
                        break
                    time.sleep(1)
    
    def search_servers(self):
        """Busca e atualiza lista de servidores"""
        self.log(">>> Buscando servidores...", "info")
        
        response = get_server_list()
        if not response:
            self.log("❌ Erro ao conectar ao masterserver após múltiplas tentativas!", "error")
            self.log("💡 Dica: Verifique sua conexão de internet", "warning")
            return
        
        servers = parse_response(response)
        self.log(f"Encontrados {len(servers)} servidores no masterserver", "info")
        
        try:
            min_players = int(self.min_players_var.get())
        except:
            min_players = DEFAULT_MIN_PLAYERS
        
        # Consultar servidores em paralelo (MUITO MAIS RÁPIDO!)
        active_servers = query_servers_parallel(servers)
        
        # Filtrar apenas servidores com jogadores
        active_servers = [s for s in active_servers if s['players'] > 0]
        
        # Ordenar por quantidade de jogadores
        active_servers.sort(key=lambda x: x['players'], reverse=True)
        
        # Criar dicionário de servidores atuais para atualização eficiente
        current_servers = {}
        for item in self.tree.get_children():
            values = self.tree.item(item)['values']
            if values:
                ip_port = values[5]  # IP:Porta
                current_servers[ip_port] = item
        
        # Atualizar ou adicionar servidores
        updated_items = set()
        
        for info in active_servers:
            is_fav = self.is_map_favorite(info['map'])
            ip_port = f"{info['ip']}:{info['port']}"
            
            # Verificar se deve notificar
            if is_fav and info['players'] >= min_players:
                server_key = f"{info['ip']}:{info['port']}:{info['map']}"
                if server_key not in self.notification_history:
                    self.show_notification(info)
                    self.notification_history.add(server_key)
            
            star = "⭐" if is_fav else ""
            
            values = (
                f"{info['players']}/{info['max_players']}",
                info['map'],
                info['mode'],
                f"{info['minutes_remaining']}min",
                info['description'][:40],
                ip_port
            )
            
            tag = 'favorite' if is_fav else ''
            
            # Se o servidor já existe, atualizar
            if ip_port in current_servers:
                item_id = current_servers[ip_port]
                self.tree.item(item_id, text=star, values=values, tags=(tag,))
                updated_items.add(item_id)
            else:
                # Adicionar novo servidor
                new_item = self.tree.insert("", tk.END, text=star, values=values, tags=(tag,))
                updated_items.add(new_item)
        
        # Remover servidores que não estão mais ativos
        for ip_port, item_id in current_servers.items():
            if item_id not in updated_items:
                self.tree.delete(item_id)
        
        # Configurar cores
        self.tree.tag_configure('favorite', background=self.highlight_bg, foreground=self.accent_yellow)
        
        self.log(f"Encontrados {len(active_servers)} servidores ativos com jogadores", "success")
        
        # Limpar histórico se muito grande
        if len(self.notification_history) > 100:
            self.notification_history.clear()
    
    def single_search(self):
        """Faz uma busca única"""
        self.searching_once = True
        thread = threading.Thread(target=self.search_servers, daemon=True)
        thread.start()
        
    def show_notification(self, info):
        """Exibe notificação de mapa favorito"""
        msg = f"🎮 MAPA FAVORITO ENCONTRADO!\n\n"
        msg += f"Servidor: {info['description']}\n"
        msg += f"Mapa: {info['map']}\n"
        msg += f"Modo: {info['mode']}\n"
        msg += f"Jogadores: {info['players']}/{info['max_players']}\n"
        msg += f"IP:Porta: {info['ip']}:{info['port']}\n\n"
        msg += f"Copie o IP:Porta acima para conectar!"
        
        self.log(f"⭐ NOTIFICAÇÃO: Mapa favorito '{info['map']}' com {info['players']} jogadores!", "highlight")
        
        # Criar janela de notificação
        self.root.after(0, lambda: self.create_notification_window(msg, info))
    
    def create_notification_window(self, message, info):
        """Cria janela de notificação"""
        notif = tk.Toplevel(self.root)
        notif.title("⭐ MAPA FAVORITO DETECTADO!")
        notif.geometry("450x280")
        notif.resizable(False, False)
        notif.configure(bg=self.bg_dark)
        
        # Centralizar janela
        notif.transient(self.root)
        notif.grab_set()
        
        # Header com efeito neon
        header = tk.Label(notif, text="⚡ SERVIDOR FAVORITO ENCONTRADO ⚡",
                         font=('Consolas', 12, 'bold'),
                         bg=self.bg_dark, fg=self.accent_magenta,
                         pady=10)
        header.pack(fill=tk.X)
        
        # Texto da notificação
        text_frame = tk.Frame(notif, bg=self.bg_medium, padx=20, pady=20)
        text_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
        
        text_widget = tk.Text(text_frame, wrap=tk.WORD, height=8, font=('Consolas', 10),
                             bg=self.bg_medium, fg=self.text_color,
                             borderwidth=0, highlightthickness=0)
        text_widget.pack(fill=tk.BOTH, expand=True)
        text_widget.insert(1.0, message)
        text_widget.config(state=tk.DISABLED)
        
        # Botões com estilo cyberpunk
        button_frame = tk.Frame(notif, bg=self.bg_dark, pady=10)
        button_frame.pack(fill=tk.X)
        
        def copy_address():
            address = f"{info['ip']} {info['port']}"
            self.root.clipboard_clear()
            self.root.clipboard_append(address)
            self.log(f">>> IP copiado: {address}", "success")
            
            # Mini popup de confirmação
            confirm = tk.Toplevel(notif)
            confirm.title("✅ Copiado!")
            confirm.geometry("300x100")
            confirm.configure(bg=self.bg_dark)
            confirm.transient(notif)
            
            tk.Label(confirm, text="✅ IP:PORTA COPIADO!",
                    font=('Consolas', 11, 'bold'),
                    bg=self.bg_dark, fg=self.accent_green,
                    pady=20).pack()
            tk.Label(confirm, text=address,
                    font=('Consolas', 10),
                    bg=self.bg_dark, fg=self.accent_cyan).pack()
            
            confirm.after(2000, confirm.destroy)
        
        copy_btn = tk.Button(button_frame, text="📋 COPIAR IP:PORTA", command=copy_address,
                            font=('Consolas', 10, 'bold'),
                            bg=self.accent_purple, fg='#ffffff',
                            activebackground=self.accent_magenta,
                            activeforeground='#ffffff',
                            borderwidth=0, padx=20, pady=10,
                            cursor='hand2')
        copy_btn.pack(side=tk.LEFT, padx=10)
        
        ok_btn = tk.Button(button_frame, text="✅ OK", command=notif.destroy,
                          font=('Consolas', 10, 'bold'),
                          bg=self.bg_medium, fg=self.accent_cyan,
                          activebackground=self.accent_cyan,
                          activeforeground=self.bg_dark,
                          borderwidth=0, padx=30, pady=10,
                          cursor='hand2')
        ok_btn.pack(side=tk.RIGHT, padx=10)
        
        # Som de alerta (beep do sistema)
        notif.bell()
    
    def on_server_double_click(self, event):
        """Copia IP:Porta ao clicar duas vezes"""
        item = self.tree.selection()
        if item:
            values = self.tree.item(item[0])['values']
            if values:
                ip_port = values[5]  # Coluna IP:Porta
                self.root.clipboard_clear()
                self.root.clipboard_append(ip_port.replace(':', ' '))
                self.log(f"IP copiado: {ip_port}", "success")
                messagebox.showinfo("Copiado!", f"IP:Porta copiado:\n{ip_port}")

def main():
    root = tk.Tk()
    app = AssaultCubeMonitor(root)
    root.mainloop()

if __name__ == "__main__":
    main()
