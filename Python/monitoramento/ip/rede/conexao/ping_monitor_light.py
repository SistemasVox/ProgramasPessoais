import tkinter as tk
from tkinter import font, ttk, messagebox
import threading
import subprocess
import re
import ipaddress
import math
import time
import platform
import queue
import random

# Tenta importar psutil, mas funciona sem ele
try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

# --- Configurações Globais e Estilos ---
COLORS = {
    'bg': "#000000",
    'fg': "#FFFFFF",
    'scale_low': "#00FF00",    # Verde (bom)
    'scale_med': "#FF9900",    # Laranja (atenção)
    'scale_high': "#FF0000",   # Vermelho (ruim)
    'led_st': "#00FF00",       # LED Estável
    'led_unst': "#FF9900",     # LED Instável
    'led_err': "#FF0000",      # LED Erro
    'led_off_g': "#003300",
    'led_off_o': "#331a00",
    'panel_bg': "#1a1a1a"
}

CONFIG = {
    'sample_size': 5,      # Tamanho da amostra para análise do LED
    'min_ms_trigger': 5,   # Variação mínima em ms para considerar instável
    'var_pct_trigger': 10.0, # Variação percentual para considerar instável
    'history_size': 3600   # Histórico para estatísticas (segundos)
}

class PingGauge(tk.Canvas):
    def __init__(self, parent, title, max_scale=200, size=200, **kw):
        super().__init__(parent, width=size, height=size, bg=COLORS['bg'], highlightthickness=0, **kw)
        self.size = size
        self.center = size / 2
        self.radius = size * 0.38
        self.max_scale = max_scale
        
        # Dados
        self.current_ping = None
        self.ping_history = [] # Guarda os últimos 3600 pontos
        self.recent = []       # Buffer recente para o LED
        
        # Estado interno
        self.min_ping = 9999
        self.max_ping = 0
        self.cur_angle = 225
        self.anim_job = None
        self.blink_job = None
        
        # Fontes
        self._init_fonts(size)
        
        # Desenho estático
        self._draw_static_elements()
        
        # Ponteiro
        self.needle = self._draw_ptr(225, COLORS['scale_low'])
        
        # Textos
        self.txt_val = self.create_text(self.center, self.center*1.3, text="---", fill=COLORS['fg'], font=self.fonts['val'])
        self.create_text(self.center, self.center*1.52, text="ms", fill="#AAAAAA", font=self.fonts['unit'])
        self.txt_min = self.create_text(self.center*0.3, size*1.03, text="Min\n---", fill="#AAAAAA", font=self.fonts['mm'], justify="center")
        self.txt_max = self.create_text(self.center*1.7, size*1.03, text="Max\n---", fill="#AAAAAA", font=self.fonts['mm'], justify="center")
        self.txt_ti = self.create_text(self.center, size*1.08, text=title, fill="#00BFFF", font=self.fonts['ti'], anchor="s")
        self.txt_ip = self.create_text(self.center, size*1.14, text="(...)", fill="#AAAAAA", font=self.fonts['ip'], anchor="s")
        
        # LED
        self.led = self._draw_led()

    def _init_fonts(self, size):
        def f(s, w="normal"): return font.Font(family="Arial", size=int(size*s), weight=w)
        self.fonts = {
            'val': f(0.16, "bold"),
            'unit': f(0.06),
            'sc': f(0.045, "bold"),
            'mm': f(0.04),
            'ti': f(0.048, "bold"),
            'ip': f(0.038)
        }

    def _draw_static_elements(self):
        # Aro externo
        r = self.radius + self.size * 0.02
        self.create_oval(self.center-r, self.center-r, self.center+r, self.center+r, outline=COLORS['fg'], width=int(self.size*0.008))
        
        # Escala
        self._draw_scale()
        
        # Pino central
        cr = self.size * 0.015
        self.create_oval(self.center-cr, self.center-cr, self.center+cr, self.center+cr, fill=COLORS['fg'], outline="#CCCCCC", width=2)

    def _draw_led(self):
        lr = self.size * 0.012
        ly = self.size * 0.99
        # Moldura do LED
        self.create_oval(self.center-lr*1.5, ly-lr*1.5, self.center+lr*1.5, ly+lr*1.5, outline="#555555", width=1)
        # Luz do LED
        return self.create_oval(self.center-lr, ly-lr, self.center+lr, ly+lr, fill=COLORS['led_off_g'], outline="")

    def set_title(self, title, ip): 
        self.itemconfigure(self.txt_ti, text=title)
        self.itemconfigure(self.txt_ip, text=ip)

    def _draw_scale(self):
        for i in range(11):
            # 225 graus é o início (esquerda embaixo), -270 é a varredura total
            ang = math.radians(225 - (i * 270 / 10))
            val = int((i/10) * self.max_scale)
            
            # Cor da escala
            if val <= 20: col = COLORS['scale_low']
            elif val >= self.max_scale * 0.75: col = COLORS['scale_high']
            elif val >= self.max_scale * 0.5: col = COLORS['scale_med']
            else: col = COLORS['fg']

            # Linha principal (Tick grande)
            p_out = (self.center + self.radius * math.cos(ang), self.center - self.radius * math.sin(ang))
            p_in = (self.center + self.radius * 0.85 * math.cos(ang), self.center - self.radius * 0.85 * math.sin(ang))
            self.create_line(*p_in, *p_out, fill=col, width=int(self.size*0.012))
            
            # Texto da escala
            p_txt = (self.center + self.radius * 0.7 * math.cos(ang), self.center - self.radius * 0.7 * math.sin(ang))
            self.create_text(*p_txt, text=str(val), fill=col, font=self.fonts['sc'])
            
            # Sub-divisões (Ticks pequenos)
            if i < 10:
                for j in range(1, 5):
                    a_m = math.radians(225 - ((i + j/5) * 270 / 10))
                    pm_out = (self.center + self.radius * math.cos(a_m), self.center - self.radius * math.sin(a_m))
                    pm_in = (self.center + self.radius * 0.92 * math.cos(a_m), self.center - self.radius * 0.92 * math.sin(a_m))
                    self.create_line(*pm_in, *pm_out, fill=col, width=int(self.size*0.004))

    def _draw_ptr(self, deg, color):
        rad = math.radians(deg)
        # Coordenadas do polígono da agulha
        pts = [
            (self.center + self.radius*0.75 * math.cos(rad), self.center - self.radius*0.75 * math.sin(rad)), # Ponta
            (self.center + self.size*0.02 * math.cos(rad+1.57), self.center - self.size*0.02 * math.sin(rad+1.57)), # Lado 1
            (self.center - self.radius*0.15 * math.cos(rad), self.center + self.radius*0.15 * math.sin(rad)), # Cauda
            (self.center + self.size*0.02 * math.cos(rad-1.57), self.center - self.size*0.02 * math.sin(rad-1.57)) # Lado 2
        ]
        return self.create_polygon(*[c for p in pts for c in p], fill=color, outline=COLORS['fg'], width=1)

    def update_ping(self, val):
        # Atualiza lista recente para o LED (Sample Size)
        self.recent.append(val)
        if len(self.recent) > CONFIG['sample_size']:
            self.recent.pop(0)
            
        target_angle = 225
        needle_color = COLORS['scale_high']

        if val is not None:
            # Atualiza histórico LONGO (para o botão Stats - 3600 segundos)
            self.ping_history.append(val)
            if len(self.ping_history) > CONFIG['history_size']: 
                self.ping_history.pop(0)
            
            self.min_ping = min(self.min_ping, val)
            self.max_ping = max(self.max_ping, val)
            
            self.itemconfigure(self.txt_val, text=f"{val}")
            self.itemconfigure(self.txt_min, text=f"Min\n{self.min_ping}")
            self.itemconfigure(self.txt_max, text=f"Max\n{self.max_ping}")
            
            # Calcula ângulo
            ratio = min(val, self.max_scale) / self.max_scale
            target_angle = 225 - (ratio * 270)
            
            # Define cor baseada no valor instantâneo
            if val < self.max_scale * 0.3: needle_color = COLORS['scale_low']
            elif val < self.max_scale * 0.6: needle_color = COLORS['scale_med']
            else: needle_color = COLORS['scale_high']
        else:
            self.itemconfigure(self.txt_val, text="Erro")
            
        self._anim_needle(target_angle, needle_color)
        self._update_led_logic(val)

    def _anim_needle(self, target, color):
        if self.anim_job: 
            self.after_cancel(self.anim_job)
            
        def step(current):
            # Movimento suave
            diff = target - current
            if abs(diff) < 0.5:
                self.delete(self.needle)
                self.needle = self._draw_ptr(target, color)
                self.cur_angle = target
            else:
                next_angle = current + (diff * 0.15) # Velocidade da agulha
                self.delete(self.needle)
                self.needle = self._draw_ptr(next_angle, color)
                self.cur_angle = next_angle
                self.anim_job = self.after(20, lambda: step(next_angle))
                
        step(self.cur_angle)

    def _update_led_logic(self, current_val):
        """
        Lógica Crítica do LED:
        1. Erro atual (None) -> Vermelho
        2. Histórico recente tem None -> Laranja (Instabilidade recente)
        3. Variação alta (Jitter) -> Laranja (Variação >= 5ms E 10%)
        4. Estável -> Verde
        """
        if self.blink_job:
            self.after_cancel(self.blink_job)

        valid_samples = [x for x in self.recent if x is not None]
        
        is_error_now = current_val is None
        has_recent_drop = None in self.recent 
        
        is_jittery = False
        if len(valid_samples) > 1:
            v_min = min(valid_samples)
            v_max = max(valid_samples)
            diff_abs = v_max - v_min
            diff_pct = (diff_abs / v_min * 100) if v_min > 0 else 0
            
            # Regra do usuário: >= 5ms E >= 10%
            if diff_abs >= CONFIG['min_ms_trigger'] and diff_pct > CONFIG['var_pct_trigger']:
                is_jittery = True

        # Determinação da cor
        if is_error_now:
            color_on, color_off = COLORS['led_err'], COLORS['led_err']
            mode = "error"
        elif has_recent_drop or is_jittery:
            color_on, color_off = COLORS['led_unst'], COLORS['led_off_o']
            mode = "unstable"
        else:
            color_on, color_off = COLORS['led_st'], COLORS['led_off_g']
            mode = "stable"

        if mode == "error":
            self.itemconfigure(self.led, fill=color_on)
        else:
            self._blink_led(0, mode, color_on, color_off)

    def _blink_led(self, count, mode, c_on, c_off):
        if mode == "stable":
            self.itemconfigure(self.led, fill=c_on)
            # Efeito heartbeat sutil
            if random.random() > 0.95:
                 self.itemconfigure(self.led, fill=c_off)
                 self.blink_job = self.after(100, lambda: self._blink_led(0, mode, c_on, c_off))
            else:
                 self.blink_job = self.after(200, lambda: self._blink_led(0, mode, c_on, c_off))
            return

        # Piscar instável
        limit = random.randint(2, 6)
        if count >= limit * 2:
            self.itemconfigure(self.led, fill=c_off)
            self.blink_job = self.after(random.randint(300, 800), lambda: self._blink_led(0, mode, c_on, c_off))
            return

        state = c_on if count % 2 == 0 else c_off
        self.itemconfigure(self.led, fill=state)
        delay = random.randint(50, 150)
        self.blink_job = self.after(delay, lambda: self._blink_led(count + 1, mode, c_on, c_off))

    def reset(self):
        self.min_ping, self.max_ping = 9999, 0
        self.ping_history, self.recent = [], []
        self.itemconfigure(self.txt_min, text="Min\n---")
        self.itemconfigure(self.txt_max, text="Max\n---")
        self._anim_needle(225, COLORS['scale_low'])


class SystemMonitorCanvas(tk.Canvas):
    def __init__(self, parent, **kw):
        super().__init__(parent, bg=COLORS['panel_bg'], highlightthickness=0, height=30, **kw)
        self.segment_width = 3
        self.segment_spacing = 2
        self.cpu_segments = []
        self.ram_segments = []
        self.bind("<Configure>", self._on_resize)
        self.current_cpu = 0
        self.current_ram = 0
    
    def _on_resize(self, event=None):
        w, h = self.winfo_width(), self.winfo_height()
        if w <= 1: return
        self.delete("all")
        
        bar_h = 20
        margin_y = (h - bar_h) // 2
        bar_w = min(int(w * 0.35), max(80, int((w - 220) / 2)))
        
        # Backgrounds
        self.create_rectangle(5, margin_y, 5 + bar_w, margin_y + bar_h, fill="#0a0a0a", outline="#333")
        self.create_rectangle(w - 5 - bar_w, margin_y, w - 5, margin_y + bar_h, fill="#0a0a0a", outline="#333")
        
        # Texto
        self.txt_cpu = self.create_text(5 + bar_w + 10, h//2, text="CPU: --%", fill="#AAA", font=("Arial", 9), anchor="w")
        self.txt_ram = self.create_text(w - 5 - bar_w - 10, h//2, text="RAM: --%", fill="#AAA", font=("Arial", 9), anchor="e")
        self.create_text(w//2, h//2, text="|", fill="#555", font=("Arial", 9))
        
        # Recalcula segmentos
        self.cpu_segments = self._create_segments(5 + 2, margin_y + 2, bar_w - 4, bar_h - 4, 1)
        self.ram_segments = self._create_segments(w - 5 - 2, margin_y + 2, bar_w - 4, bar_h - 4, -1)
        
        self._update_visuals()

    def _create_segments(self, start_x, start_y, width, height, direction):
        segs = []
        num = width // (self.segment_width + self.segment_spacing)
        for i in range(int(num)):
            x = start_x + (i * (self.segment_width + self.segment_spacing) * direction)
            if direction == -1: x -= self.segment_width 
            segs.append(self.create_rectangle(x, start_y, x + self.segment_width, start_y + height, fill="#0a0a0a", outline=""))
        return segs

    def update_values(self, cpu, ram):
        self.current_cpu, self.current_ram = cpu, ram
        if hasattr(self, 'txt_cpu'):
            self.itemconfigure(self.txt_cpu, text=f"CPU: {cpu:.1f}%")
            self.itemconfigure(self.txt_ram, text=f"RAM: {ram:.1f}%")
            self._update_visuals()

    def _update_visuals(self):
        def fill_segs(segs, pct):
            count = len(segs)
            fill_idx = int((pct / 100) * count)
            for i, s in enumerate(segs):
                if i < fill_idx:
                    ratio = (i / count)
                    r = int(255 * (ratio * 2)) if ratio < 0.5 else 255
                    g = 255 if ratio < 0.5 else int(255 * (2 - ratio * 2))
                    col = f"#{min(255,max(0,r)):02x}{min(255,max(0,g)):02x}00"
                    self.itemconfigure(s, fill=col)
                else:
                    self.itemconfigure(s, fill="#0a0a0a")
        
        fill_segs(self.cpu_segments, self.current_cpu)
        fill_segs(self.ram_segments, self.current_ram)


class PingApp:
    def __init__(self, root):
        self.root = root
        root.title("Monitor de Ping Pro")
        root.geometry("720x360")
        root.configure(bg=COLORS['bg'])
        
        self.running = True
        self.ips = ["...", "...", "9.9.9.9"]
        self.titles = ["Gateway", "Provedor", "Internet"]
        self.queue = queue.Queue()
        
        self._setup_menu()
        self._setup_ui()
        
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        threading.Thread(target=self._discovery_thread, daemon=True).start()
        threading.Thread(target=self._ping_loop_thread, daemon=True).start()
        
        self._process_queue()
        self._update_sys_stats()

    def _setup_menu(self):
        mb = tk.Menu(self.root)
        m_file = tk.Menu(mb, tearoff=0)
        m_file.add_command(label="Sair", command=self.close)
        mb.add_cascade(label="Arquivo", menu=m_file)
        
        m_tools = tk.Menu(mb, tearoff=0)
        m_tools.add_command(label="Estatísticas Detalhadas", command=self.stats)
        m_tools.add_command(label="Configurar Sensibilidade", command=self._open_config)
        m_tools.add_command(label="Zerar Dados", command=self._reset_data)
        mb.add_cascade(label="Ferramentas", menu=m_tools)
        
        self.root.config(menu=mb)

    def _setup_ui(self):
        mf = tk.Frame(self.root, bg=COLORS['bg'])
        mf.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
        
        self.gauges = []
        for t in self.titles:
            g = PingGauge(mf, title=t, size=220)
            g.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
            self.gauges.append(g)
            
        bf = tk.Frame(self.root, bg=COLORS['bg'])
        bf.pack(fill='x', padx=10, pady=(0, 10))
        
        style = ttk.Style()
        style.theme_use('clam')
        style.configure('D.TButton', background='#333', foreground='white', borderwidth=1)
        style.map('D.TButton', background=[('active', '#555')])
        
        ttk.Button(bf, text="Stats", command=self.stats, style='D.TButton', width=6).pack(side=tk.LEFT, padx=2)
        ttk.Button(bf, text="Reset", command=self._reset_data, style='D.TButton', width=6).pack(side=tk.LEFT, padx=2)
        
        self.sys_mon = SystemMonitorCanvas(bf)
        self.sys_mon.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=10)
        
        ttk.Button(bf, text="Sair", command=self.close, style='D.TButton', width=6).pack(side=tk.RIGHT, padx=2)

    def stats(self):
        """Mostra estatísticas baseadas nos últimos 3600 segundos de histórico"""
        w = tk.Toplevel(self.root)
        w.title("Estatísticas (1h)")
        w.configure(bg="black")
        w.geometry("400x200")
        
        lbl_header = tk.Label(w, text="Resumo dos últimos 3600 pacotes", bg="black", fg="#00BFFF", font=("Arial", 10, "bold"))
        lbl_header.pack(pady=10)

        for g, t in zip(self.gauges, self.titles):
            h = g.ping_history
            if h:
                avg = sum(h) / len(h)
                txt = f"{t}: Min={min(h)}ms | Méd={avg:.1f}ms | Max={max(h)}ms"
            else:
                txt = f"{t}: Sem dados suficientes"
            
            tk.Label(w, text=txt, bg="black", fg="white", font=("Arial", 9)).pack(pady=5, padx=10, anchor="w")

    def _ping_host(self, ip):
        if ip in [None, "...", "Erro", "?"]:
            return None
            
        param = '-n' if platform.system().lower() == 'windows' else '-c'
        timeout = '1000'
        
        creationflags = 0
        if platform.system().lower() == 'windows':
            creationflags = 0x08000000 # CREATE_NO_WINDOW
        
        cmd = ['ping', param, '1', '-w' if platform.system().lower()=='windows' else '-W', timeout if platform.system().lower()=='windows' else '1', ip]
        
        try:
            proc = subprocess.Popen(
                cmd, 
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE, 
                creationflags=creationflags,
                encoding='cp850' if platform.system()=='Windows' else 'utf-8'
            )
            out, _ = proc.communicate()
            
            if match := re.search(r'(?:tempo|time)[=<]([0-9]+)(?:ms)?', out, re.IGNORECASE):
                return int(match.group(1))
            return None
        except Exception:
            return None

    def _ping_loop_thread(self):
        while self.running:
            results = []
            for ip in self.ips:
                results.append(self._ping_host(ip))
            self.queue.put(results)
            time.sleep(1)

    def _process_queue(self):
        try:
            while True:
                data = self.queue.get_nowait()
                for g, val in zip(self.gauges, data):
                    g.update_ping(val)
        except queue.Empty:
            pass
        if self.running:
            self.root.after(100, self._process_queue)

    def _update_sys_stats(self):
        if HAS_PSUTIL:
            try:
                cpu = psutil.cpu_percent(interval=None)
                ram = psutil.virtual_memory().percent
                self.sys_mon.update_values(cpu, ram)
            except: pass
        if self.running:
            self.root.after(1000, self._update_sys_stats)

    def _discovery_thread(self):
        if platform.system() != "Windows":
            self.ips = ["1.1.1.1", "9.9.9.9", "9.9.9.9"]
            self._update_titles_safe()
            return

        try:
            target_ip = "9.9.9.9"
            cmd = ["tracert", "-w", "100", "-h", "10", target_ip]
            out = subprocess.check_output(cmd, encoding='cp850', creationflags=0x08000000)
            
            hops = []
            for line in out.splitlines():
                if m := re.search(r'(\d+\.\d+\.\d+\.\d+)', line):
                    ip = m.group(1)
                    if ip != target_ip and ip not in [x[0] for x in hops]:
                        name = line.split()[1] if '[' in line else ""
                        hops.append((ip, name))
            
            if not hops: return

            gw = hops[0][0]
            prov = "?"
            
            # Identificar IPs Públicos para selecionar o provedor correto
            public_hops = []
            for ip, _ in hops:
                obj = ipaddress.ip_address(ip)
                # Ignora privados, CGNAT (100.64) e o destino
                if not obj.is_private and not str(ip).startswith("100.64") and ip != target_ip:
                    public_hops.append(ip)
            
            if public_hops:
                # Se houver mais de 1 IP público, o primeiro geralmente é o WAN do cliente (ex: .82)
                # e o segundo é o gateway da operadora (ex: .81). Damos preferência ao segundo.
                if len(public_hops) >= 2:
                    prov = public_hops[1]
                else:
                    prov = public_hops[0]
            
            self.ips = [gw, prov, target_ip]
            self._update_titles_safe()
            
        except Exception as e:
            print(f"Erro discovery: {e}")

    def _update_titles_safe(self):
        self.root.after(0, lambda: [g.set_title(t, f"({ip})") for g, t, ip in zip(self.gauges, self.titles, self.ips)])

    def _open_config(self):
        w = tk.Toplevel(self.root)
        w.title("Config")
        w.configure(bg="black")
        
        def add_field(lbl, key):
            f = tk.Frame(w, bg="black"); f.pack(pady=5)
            tk.Label(f, text=lbl, bg="black", fg="white").pack(side=tk.LEFT)
            e = ttk.Entry(f, width=5); e.pack(side=tk.LEFT)
            e.insert(0, str(CONFIG[key]))
            return e, key

        fields = [
            add_field("Min Var (ms):", 'min_ms_trigger'),
            add_field("Min Var (%):", 'var_pct_trigger')
        ]

        def save():
            try:
                CONFIG['min_ms_trigger'] = int(fields[0][0].get())
                CONFIG['var_pct_trigger'] = float(fields[1][0].get())
                w.destroy()
            except ValueError:
                messagebox.showerror("Erro", "Use apenas números.")
        
        ttk.Button(w, text="Salvar", command=save).pack(pady=10)

    def _reset_data(self):
        if messagebox.askyesno("Confirmar", "Zerar gráficos e histórico?"):
            for g in self.gauges: g.reset()

    def close(self):
        self.running = False
        self.root.destroy()

if __name__ == "__main__":
    root = tk.Tk()
    app = PingApp(root)
    root.mainloop()
