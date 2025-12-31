import socket
import threading
import time
from datetime import datetime
import re
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
import winsound  # Para tocar sons no Windows

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
        'name': 'AssaultCube',
        'version': '1302',
        'build': '0'
    }
    
    base_url = f"http://{masterserver_host}/retrieve.do"
    query_string = '&'.join([f"{k}={v}" for k, v in params.items()])
    url = f"{base_url}?{query_string}"
    
    last_error = None
    
    for attempt in range(retries):
        try:
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
        self.root.geometry("960x720")
        self.root.resizable(True, True)
        
        # Tema Cyberpunk
        self.setup_cyberpunk_theme()
        
        self.monitoring = False
        self.monitor_thread = None
        
        # Histórico rastreia tempo para detectar reinício
        self.notification_history = {}  # {server_key: last_time}
        
        # Modo de notificação: False = Normal (padrão), True = Prioridade Máxima
        self.priority_notification_mode = tk.BooleanVar(value=False)
        
        self.setup_ui()
        # Centralizar janela principal ao iniciar
        self.center_main_window()
    
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
        
        self.text_color = "#e0e0e0"
        self.highlight_bg = "#2a2f4a"
        
        # Configurar estilo
        style = ttk.Style()
        style.theme_use('clam')
        
        # Treeview
        style.configure("Cyber.Treeview",
                       background=self.bg_medium,
                       foreground=self.text_color,
                       fieldbackground=self.bg_medium,
                       borderwidth=0)
        style.map('Cyber.Treeview', background=[('selected', self.accent_purple)])
        
        # Treeview heading
        style.configure("Cyber.Treeview.Heading",
                       background=self.bg_dark,
                       foreground=self.accent_cyan,
                       borderwidth=1,
                       relief='flat')
        style.map("Cyber.Treeview.Heading",
                 background=[('active', self.accent_purple)])
        
        self.root.configure(bg=self.bg_dark)
    
    def setup_ui(self):
        """Configura a interface"""
        # Frame superior - Configurações
        config_frame = tk.Frame(self.root, bg=self.bg_dark, pady=10)
        config_frame.pack(fill=tk.X, padx=10)
        
        # Título
        title = tk.Label(config_frame, text="⚡ ASSAULTCUBE SERVER MONITOR ⚡",
                        font=('Consolas', 16, 'bold'),
                        bg=self.bg_dark, fg=self.accent_cyan)
        title.pack(pady=5)
        
        # Configurações em grid
        settings_frame = tk.Frame(config_frame, bg=self.bg_dark)
        settings_frame.pack(pady=10)
        
        # Mapas favoritos
        tk.Label(settings_frame, text="Mapas Favoritos:",
                font=('Consolas', 10), bg=self.bg_dark, fg=self.accent_magenta).grid(row=0, column=0, sticky='w', padx=5)
        self.fav_maps_entry = tk.Entry(settings_frame, width=40, font=('Consolas', 10),
                                       bg=self.bg_medium, fg=self.text_color,
                                       insertbackground=self.accent_cyan)
        self.fav_maps_entry.insert(0, DEFAULT_FAVORITE_MAPS)
        self.fav_maps_entry.grid(row=0, column=1, padx=5)
        
        # Jogadores mínimos
        tk.Label(settings_frame, text="Jogadores Mínimos:",
                font=('Consolas', 10), bg=self.bg_dark, fg=self.accent_magenta).grid(row=1, column=0, sticky='w', padx=5, pady=5)
        self.min_players_entry = tk.Entry(settings_frame, width=10, font=('Consolas', 10),
                                         bg=self.bg_medium, fg=self.text_color,
                                         insertbackground=self.accent_cyan)
        self.min_players_entry.insert(0, str(DEFAULT_MIN_PLAYERS))
        self.min_players_entry.grid(row=1, column=1, sticky='w', padx=5, pady=5)
        
        # Intervalo de verificação
        tk.Label(settings_frame, text="Intervalo (segundos):",
                font=('Consolas', 10), bg=self.bg_dark, fg=self.accent_magenta).grid(row=2, column=0, sticky='w', padx=5)
        self.interval_entry = tk.Entry(settings_frame, width=10, font=('Consolas', 10),
                                      bg=self.bg_medium, fg=self.text_color,
                                      insertbackground=self.accent_cyan)
        self.interval_entry.insert(0, str(DEFAULT_CHECK_INTERVAL))
        self.interval_entry.grid(row=2, column=1, sticky='w', padx=5)
        
        # Checkbox para modo de notificação
        priority_frame = tk.Frame(settings_frame, bg=self.bg_dark)
        priority_frame.grid(row=3, column=0, columnspan=2, pady=10, sticky='w', padx=5)
        
        self.priority_check = tk.Checkbutton(
            priority_frame,
            text="🔔 Notificações com PRIORIDADE MÁXIMA",
            variable=self.priority_notification_mode,
            font=('Consolas', 10, 'bold'),
            bg=self.bg_dark,
            fg=self.accent_yellow,
            selectcolor=self.bg_medium,
            activebackground=self.bg_dark,
            activeforeground=self.accent_green,
            cursor='hand2'
        )
        self.priority_check.pack(anchor='w')
        
        # Descrição dos modos
        desc_frame = tk.Frame(priority_frame, bg=self.bg_dark)
        desc_frame.pack(anchor='w', padx=20, pady=5)
        
        tk.Label(desc_frame, 
                text="✓ LIGADO: Pop-up aparece SEMPRE, mesmo em tela cheia",
                font=('Consolas', 8),
                bg=self.bg_dark,
                fg=self.accent_green).pack(anchor='w')
        
        tk.Label(desc_frame, 
                text="✗ DESLIGADO: Pop-up normal + janela pisca + som característico",
                font=('Consolas', 8),
                bg=self.bg_dark,
                fg=self.accent_cyan).pack(anchor='w')
        
        # Botões de controle
        button_frame = tk.Frame(config_frame, bg=self.bg_dark, pady=10)
        button_frame.pack()
        
        self.start_btn = tk.Button(button_frame, text="▶ INICIAR MONITORAMENTO",
                                   command=self.toggle_monitoring,
                                   font=('Consolas', 11, 'bold'),
                                   bg=self.accent_green, fg=self.bg_dark,
                                   activebackground=self.accent_cyan,
                                   borderwidth=0, padx=20, pady=10,
                                   cursor='hand2')
        self.start_btn.pack(side=tk.LEFT, padx=5)
        
        self.search_btn = tk.Button(button_frame, text="🔍 BUSCAR AGORA",
                                    command=self.single_search,
                                    font=('Consolas', 11, 'bold'),
                                    bg=self.accent_purple, fg='#ffffff',
                                    activebackground=self.accent_magenta,
                                    borderwidth=0, padx=20, pady=10,
                                    cursor='hand2')
        self.search_btn.pack(side=tk.LEFT, padx=5)
        
        self.exit_btn = tk.Button(button_frame, text="❌ SAIR",
                                  command=self.exit_application,
                                  font=('Consolas', 11, 'bold'),
                                  bg='#ff3333', fg='#ffffff',
                                  activebackground='#cc0000',
                                  activeforeground='#ffffff',
                                  borderwidth=0, padx=30, pady=10,
                                  cursor='hand2')
        self.exit_btn.pack(side=tk.LEFT, padx=5)
        
        # Frame para a tabela de servidores
        table_frame = tk.Frame(self.root, bg=self.bg_dark)
        table_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)
        
        # Label de servidores
        tk.Label(table_frame, text="SERVIDORES ATIVOS:",
                font=('Consolas', 12, 'bold'),
                bg=self.bg_dark, fg=self.accent_magenta).pack(anchor='w', pady=5)
        
        # Treeview com scrollbar
        tree_scroll = ttk.Scrollbar(table_frame)
        tree_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        
        self.tree = ttk.Treeview(table_frame, style="Cyber.Treeview",
                                yscrollcommand=tree_scroll.set,
                                selectmode='browse')
        
        tree_scroll.config(command=self.tree.yview)
        
        # Definir colunas
        self.tree['columns'] = ('Players', 'Map', 'Mode', 'Time', 'Description', 'Address')
        
        self.tree.column("#0", width=30, minwidth=30, stretch=False)
        self.tree.column("Players", width=80, minwidth=80)
        self.tree.column("Map", width=120, minwidth=100)
        self.tree.column("Mode", width=80, minwidth=80)
        self.tree.column("Time", width=80, minwidth=80)
        self.tree.column("Description", width=250, minwidth=200)
        self.tree.column("Address", width=150, minwidth=150)
        
        self.tree.heading("#0", text="⭐")
        self.tree.heading("Players", text="JOGADORES")
        self.tree.heading("Map", text="MAPA")
        self.tree.heading("Mode", text="MODO")
        self.tree.heading("Time", text="TEMPO")
        self.tree.heading("Description", text="DESCRIÇÃO")
        self.tree.heading("Address", text="IP:PORTA")
        
        self.tree.pack(fill=tk.BOTH, expand=True)
        
        # Bind duplo clique
        self.tree.bind('<Double-1>', self.on_server_double_click)
        
        # Frame de log
        log_frame = tk.Frame(self.root, bg=self.bg_dark)
        log_frame.pack(fill=tk.BOTH, padx=10, pady=5)
        
        tk.Label(log_frame, text="LOG DE ATIVIDADES:",
                font=('Consolas', 10, 'bold'),
                bg=self.bg_dark, fg=self.accent_cyan).pack(anchor='w')
        
        self.log_text = scrolledtext.ScrolledText(log_frame, height=6,
                                                  font=('Consolas', 9),
                                                  bg=self.bg_medium, fg=self.text_color,
                                                  insertbackground=self.accent_cyan,
                                                  wrap=tk.WORD)
        self.log_text.pack(fill=tk.BOTH, expand=True)
        
        # Tags para cores no log
        self.log_text.tag_config('success', foreground=self.accent_green)
        self.log_text.tag_config('error', foreground=self.accent_magenta)
        self.log_text.tag_config('highlight', foreground=self.accent_yellow)
        
        self.log("Sistema iniciado. Configure e clique em INICIAR MONITORAMENTO.", "success")
    
    def center_main_window(self):
        """Centraliza a janela principal na tela"""
        self.root.update_idletasks()
        width = self.root.winfo_width()
        height = self.root.winfo_height()
        x = (self.root.winfo_screenwidth() // 2) - (width // 2)
        y = (self.root.winfo_screenheight() // 2) - (height // 2)
        self.root.geometry(f'{width}x{height}+{x}+{y}')
    
    def center_child(self, child_window, width=None, height=None):
        """Centraliza uma janela filha em relação ao root (ou à tela)"""
        child_window.update_idletasks()
        
        if width is None:
            width = child_window.winfo_width()
        if height is None:
            height = child_window.winfo_height()
        
        # Tenta centralizar em relação ao root se ele estiver visível
        try:
            parent_state = self.root.state()
            parent_visible = parent_state in ('normal', 'zoomed') and self.root.winfo_viewable()
            
            if parent_visible:
                parent_x = self.root.winfo_x()
                parent_y = self.root.winfo_y()
                parent_width = self.root.winfo_width()
                parent_height = self.root.winfo_height()
                
                x = parent_x + (parent_width // 2) - (width // 2)
                y = parent_y + (parent_height // 2) - (height // 2)
            else:
                # Centraliza na tela
                x = (child_window.winfo_screenwidth() // 2) - (width // 2)
                y = (child_window.winfo_screenheight() // 2) - (height // 2)
        except:
            # Fallback: centralizar na tela
            x = (child_window.winfo_screenwidth() // 2) - (width // 2)
            y = (child_window.winfo_screenheight() // 2) - (height // 2)
        
        child_window.geometry(f'{width}x{height}+{x}+{y}')
    
    def log(self, message, tag=None):
        """Adiciona mensagem ao log"""
        timestamp = datetime.now().strftime("%H:%M:%S")
        log_message = f"[{timestamp}] {message}\n"
        
        self.log_text.insert(tk.END, log_message, tag)
        self.log_text.see(tk.END)
    
    def is_map_favorite(self, map_name):
        """Verifica se o mapa está na lista de favoritos (busca parcial)"""
        favorites = [m.strip().lower() for m in self.fav_maps_entry.get().split(',')]
        map_lower = map_name.lower()
        
        # Verifica se algum favorito está contido no nome do mapa
        # Ex: "casa" encontra "ac_casa", "ac_casa_2", etc.
        for fav in favorites:
            if fav in map_lower:
                return True
        return False
    
    def toggle_monitoring(self):
        """Inicia ou para o monitoramento"""
        if not self.monitoring:
            self.start_monitoring()
        else:
            self.stop_monitoring()
    
    def start_monitoring(self):
        """Inicia o monitoramento contínuo"""
        try:
            interval = int(self.interval_entry.get())
            if interval < 10:
                messagebox.showwarning("Aviso", "Intervalo mínimo é 10 segundos")
                return
        except ValueError:
            messagebox.showerror("Erro", "Intervalo inválido")
            return
        
        self.monitoring = True
        self.start_btn.config(text="⏸ PARAR MONITORAMENTO", bg=self.accent_magenta)
        self.log("Monitoramento iniciado!", "success")
        
        self.monitor_thread = threading.Thread(target=self.monitor_loop, daemon=True)
        self.monitor_thread.start()
    
    def stop_monitoring(self):
        """Para o monitoramento"""
        self.monitoring = False
        self.start_btn.config(text="▶ INICIAR MONITORAMENTO", bg=self.accent_green)
        self.log("Monitoramento parado.", "error")
    
    def monitor_loop(self):
        """Loop principal de monitoramento"""
        while self.monitoring:
            self.search_servers()
            
            interval = int(self.interval_entry.get())
            for _ in range(interval):
                if not self.monitoring:
                    break
                time.sleep(1)
    
    def search_servers(self):
        """Busca servidores ativos"""
        self.log("Buscando servidores...")
        
        response = get_server_list()
        if not response:
            self.log("Erro ao obter lista de servidores", "error")
            return
        
        servers = parse_response(response)
        self.log(f"Consultando {len(servers)} servidores...")
        
        # Obter jogadores mínimos
        try:
            min_players = int(self.min_players_entry.get())
        except ValueError:
            min_players = DEFAULT_MIN_PLAYERS
        
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
            
            # Verificar se deve notificar (com detecção de reinício)
            if is_fav and info['players'] >= min_players:
                server_key = f"{info['ip']}:{info['port']}:{info['map']}"
                current_time = info['minutes_remaining']
                
                # Verificar se é um novo jogo ou se a partida reiniciou
                should_notify = False
                
                if server_key not in self.notification_history:
                    # Primeira vez que vemos este servidor com este mapa
                    should_notify = True
                    self.log(f"🆕 Novo mapa favorito detectado: {info['map']}", "highlight")
                else:
                    # Verificar se o tempo aumentou (partida reiniciou)
                    last_time = self.notification_history[server_key]
                    if current_time > last_time:
                        should_notify = True
                        self.log(f"🔄 Partida reiniciou em {info['map']} (tempo: {last_time}→{current_time}min)", "highlight")
                
                if should_notify:
                    self.show_notification(info)
                
                # Atualizar o tempo no histórico
                self.notification_history[server_key] = current_time
            
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
            # Manter apenas os 50 mais recentes
            items = list(self.notification_history.items())
            self.notification_history = dict(items[-50:])
            self.log("Histórico de notificações reduzido", "highlight")
    
    def single_search(self):
        """Faz uma busca única"""
        thread = threading.Thread(target=self.search_servers, daemon=True)
        thread.start()
    
    def exit_application(self):
        """Fecha a aplicação com confirmação"""
        if self.monitoring:
            # Se está monitorando, confirmar antes de sair
            response = messagebox.askyesno(
                "Confirmar Saída",
                "O monitoramento está ativo.\n\nDeseja realmente sair?",
                icon='warning'
            )
            if not response:
                return
        
        self.log("Encerrando aplicação...", "error")
        self.monitoring = False
        self.root.quit()
        self.root.destroy()
    
    def play_notification_sound(self):
        """Toca um som característico de notificação (3 beeps em sequência)"""
        def play_sound():
            try:
                # Som característico: 3 beeps curtos em frequências diferentes
                # Representa: "AC Monitor Alert!"
                frequencies = [800, 1000, 1200]  # Hz
                for freq in frequencies:
                    winsound.Beep(freq, 150)  # 150ms cada beep
                    time.sleep(0.05)  # Pequena pausa entre beeps
            except Exception as e:
                # Fallback: usar bell do sistema se Beep falhar
                self.root.bell()
                time.sleep(0.2)
                self.root.bell()
                time.sleep(0.2)
                self.root.bell()
        
        # Tocar som em thread separada para não bloquear
        sound_thread = threading.Thread(target=play_sound, daemon=True)
        sound_thread.start()
    
    def flash_main_window(self, duration=5):
        """Faz a janela principal piscar por alguns segundos"""
        def flash():
            end_time = time.time() + duration
            while time.time() < end_time:
                try:
                    # Alterna entre normal e destacado
                    self.root.attributes('-topmost', True)
                    time.sleep(0.3)
                    self.root.attributes('-topmost', False)
                    time.sleep(0.3)
                except:
                    break
        
        # Executar flash em thread separada
        flash_thread = threading.Thread(target=flash, daemon=True)
        flash_thread.start()
        
    def show_notification(self, info):
        """Exibe notificação de mapa favorito"""
        msg = f"🎮 MAPA FAVORITO ENCONTRADO!\n\n"
        msg += f"Servidor: {info['description']}\n"
        msg += f"Mapa: {info['map']}\n"
        msg += f"Modo: {info['mode']}\n"
        msg += f"Jogadores: {info['players']}/{info['max_players']}\n"
        msg += f"Tempo: {info['minutes_remaining']} minutos\n"
        msg += f"IP:Porta: {info['ip']}:{info['port']}\n\n"
        msg += f"Copie o IP:Porta acima para conectar!"
        
        self.log(f"⭐ NOTIFICAÇÃO: Mapa favorito '{info['map']}' com {info['players']} jogadores!", "highlight")
        
        # Criar janela de notificação
        self.root.after(0, lambda: self.create_notification_window(msg, info))
    
    def create_notification_window(self, message, info):
        """Cria janela de notificação com comportamento baseado no modo selecionado"""
        notif = tk.Toplevel(self.root)
        notif.title("⭐ MAPA FAVORITO DETECTADO!")
        notif.geometry("450x300")
        notif.resizable(False, False)
        notif.configure(bg=self.bg_dark)
        
        # Verificar modo de notificação
        use_priority = self.priority_notification_mode.get()
        
        if use_priority:
            # PRIORIDADE MÁXIMA: Pop-up sempre visível, mesmo em tela cheia
            notif.attributes('-topmost', True)
            notif.lift()
            try:
                notif.focus_force()
            except:
                pass
            # Manter topmost permanente no modo prioritário
            # (não remover depois de um tempo)
        else:
            # PRIORIDADE NORMAL: Pop-up normal + janela pisca + som característico
            notif.lift()
            
            # Fazer a janela principal piscar
            self.flash_main_window(duration=5)
            
            # Tocar som característico
            self.play_notification_sound()
        
        # Header com efeito neon
        header_text = "⚡ SERVIDOR FAVORITO ENCONTRADO ⚡"
        if use_priority:
            header_text += " [🔴 PRIORIDADE MÁXIMA]"
        else:
            header_text += " [🔵 PRIORIDADE NORMAL]"
        
        header = tk.Label(notif, text=header_text,
                         font=('Consolas', 11, 'bold'),
                         bg=self.bg_dark, 
                         fg=self.accent_magenta if use_priority else self.accent_cyan,
                         pady=10)
        header.pack(fill=tk.X)
        
        # Texto da notificação
        text_frame = tk.Frame(notif, bg=self.bg_medium, padx=20, pady=20)
        text_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
        
        text_widget = tk.Text(text_frame, wrap=tk.WORD, height=9, font=('Consolas', 10),
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
            confirm.attributes('-topmost', True)
            
            tk.Label(confirm, text="✅ IP:PORTA COPIADO!",
                    font=('Consolas', 11, 'bold'),
                    bg=self.bg_dark, fg=self.accent_green,
                    pady=20).pack()
            tk.Label(confirm, text=address,
                    font=('Consolas', 10),
                    bg=self.bg_dark, fg=self.accent_cyan).pack()
            
            self.center_child(confirm, width=300, height=100)
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
        
        # Centraliza a notificação
        self.center_child(notif, width=450, height=300)
    
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
