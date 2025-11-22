import tkinter as tk
from tkinter import font, ttk, messagebox
import threading, subprocess, re, ipaddress, math, time, platform, queue, random

try: import psutil; HAS_PSUTIL = True
except ImportError: HAS_PSUTIL = False

class PingGauge(tk.Canvas):
    LED_CONF = {'min_ms': 5, 'var_pct': 10.0, 'sample': 5}
    COLORS = {'st': "#00FF00", 'unst': "#FF9900", 'err': "#FF0000", 'off_g': "#003300", 'off_o': "#331a00"}

    def __init__(self, parent, title, max_scale=200, size=200, **kw):
        super().__init__(parent, width=size, height=size, bg="#000000", highlightthickness=0, **kw)
        self.size, self.center, self.radius, self.max_scale = size, size/2, size*0.38, max_scale
        self.current_ping, self.ping_history, self.recent = None, [], []
        self.min_ping, self.max_ping, self.cur_angle, self.anim_job, self.blink_job = 9999, 0, 225, None, None
        
        f_sz = lambda s, w="normal": font.Font(family="Arial", size=int(size*s), weight=w)
        self.fonts = {'val': f_sz(0.16,"bold"), 'unit': f_sz(0.06), 'sc': f_sz(0.045,"bold"), 'mm': f_sz(0.04), 'ti': f_sz(0.048,"bold"), 'ip': f_sz(0.038)}
        
        self.create_oval(self.center-(r:=self.radius+size*0.02), self.center-r, self.center+r, self.center+r, outline="#FFFFFF", width=int(size*0.008))
        self._draw_scale()
        self.create_oval(self.center-(cr:=size*0.015), self.center-cr, self.center+cr, self.center+cr, fill="#FFFFFF", outline="#CCCCCC", width=2)
        self.needle = self._draw_ptr(225, "#00FF00")
        
        self.txt_val = self.create_text(self.center, self.center*1.3, text="---", fill="#FFFFFF", font=self.fonts['val'])
        self.create_text(self.center, self.center*1.52, text="ms", fill="#AAAAAA", font=self.fonts['unit'])
        self.txt_min = self.create_text(self.center*0.3, size*1.03, text="Min\n---", fill="#AAAAAA", font=self.fonts['mm'], justify="center")
        self.txt_max = self.create_text(self.center*1.7, size*1.03, text="Max\n---", fill="#AAAAAA", font=self.fonts['mm'], justify="center")
        self.txt_ti = self.create_text(self.center, size*1.08, text=title, fill="#00BFFF", font=self.fonts['ti'], anchor="s")
        self.txt_ip = self.create_text(self.center, size*1.14, text="(...)", fill="#AAAAAA", font=self.fonts['ip'], anchor="s")
        
        self.led = self.create_oval(self.center-(lr:=size*0.012), (ly:=size*0.99)-lr, self.center+lr, ly+lr, fill=self.COLORS['off_g'], outline="")
        self.create_oval(self.center-lr*1.5, ly-lr*1.5, self.center+lr*1.5, ly+lr*1.5, outline="#555555", width=1)

    def set_title(self, title, ip): 
        self.itemconfigure(self.txt_ti, text=title)
        self.itemconfigure(self.txt_ip, text=ip)

    def _draw_scale(self):
        for i in range(11):
            ang, val = math.radians(225 - (i * 270 / 10)), int((i/10)*self.max_scale)
            col = "#00FF00" if val<=20 else "#FF3333" if val>=self.max_scale*0.75 else "#FF9933" if val>=self.max_scale*0.5 else "#FFFFFF"
            p = lambda r: (self.center + r * math.cos(ang), self.center - r * math.sin(ang))
            self.create_line(*p(self.radius*0.85), *p(self.radius), fill=col, width=int(self.size*0.012))
            self.create_text(*p(self.radius*0.7), text=str(val), fill=col, font=self.fonts['sc'])
            if i < 10:
                for j in range(1, 5):
                    a_m = math.radians(225 - ((i + j/5) * 270 / 10))
                    self.create_line(self.center+self.radius*0.92*math.cos(a_m), self.center-self.radius*0.92*math.sin(a_m),
                                     self.center+self.radius*math.cos(a_m), self.center-self.radius*math.sin(a_m), fill=col, width=int(self.size*0.004))

    def _draw_ptr(self, deg, color):
        rad = math.radians(deg)
        pts = [(self.center + self.radius*0.75 * math.cos(rad), self.center - self.radius*0.75 * math.sin(rad)),
               (self.center + self.size*0.02 * math.cos(rad+1.57), self.center - self.size*0.02 * math.sin(rad+1.57)),
               (self.center - self.radius*0.15 * math.cos(rad), self.center + self.radius*0.15 * math.sin(rad)),
               (self.center + self.size*0.02 * math.cos(rad-1.57), self.center - self.size*0.02 * math.sin(rad-1.57))]
        return self.create_polygon(*[c for p in pts for c in p], fill=color, outline="#FFFFFF", width=1)

    def update_ping(self, val):
        self.recent = (self.recent + [val])[-self.LED_CONF['sample']:]
        if val is not None:
            self.ping_history = (self.ping_history + [val])[-3600:]
            self.min_ping, self.max_ping = min(self.ping_history), max(self.ping_history)
            self.itemconfigure(self.txt_val, text=f"{val}")
            self.itemconfigure(self.txt_min, text=f"Min\n{self.min_ping}")
            self.itemconfigure(self.txt_max, text=f"Max\n{self.max_ping}")
            tgt, col = 225 - (min(val, self.max_scale)/self.max_scale * 270), "#00FF00" if val < self.max_scale*0.3 else "#FFFF00" if val < self.max_scale*0.6 else "#FF3333"
        else:
            self.itemconfigure(self.txt_val, text="Erro")
            tgt, col = 225, "#FF0000"
        self._anim(tgt, col)
        self._blink(val)

    def _anim(self, tgt, col):
        if self.anim_job: 
            self.after_cancel(self.anim_job)
        def step(cur):
            if abs(tgt - cur) < 0.5:
                self.delete(self.needle)
                self.needle = self._draw_ptr(tgt, col)
                self.cur_angle = tgt
            else:
                nxt = cur + (tgt - cur) * 0.1
                self.delete(self.needle)
                self.needle = self._draw_ptr(nxt, col)
                self.cur_angle = nxt
                self.anim_job = self.after(20, lambda: step(nxt))
        step(self.cur_angle)

    def _blink(self, val):
        if self.blink_job:
            self.after_cancel(self.blink_job)
        v_s = [x for x in self.recent if x is not None]
        conf = PingGauge.LED_CONF
        is_err = val is None
        is_unst = is_err or (len(v_s)>1 and (max(v_s)-min(v_s))>=conf['min_ms'] and ((max(v_s)-min(v_s))/min(v_s)*100)>conf['var_pct'])
        c_on, c_off = (self.COLORS['err'], self.COLORS['err']) if is_err else (self.COLORS['unst'], self.COLORS['off_o']) if is_unst else (self.COLORS['st'], self.COLORS['off_g'])
        if is_err:
            self.itemconfigure(self.led, fill=c_on)
            return
        def pulse(cnt, limit):
            if cnt >= limit*2:
                self.itemconfigure(self.led, fill=c_off)
                return
            self.itemconfigure(self.led, fill=c_on if cnt%2==0 else c_off)
            t = random.randint(60, 120) if is_unst else random.randint(80, 150)
            self.blink_job = self.after(t, lambda: pulse(cnt+1, limit))
        pulse(0, random.randint(2, 4) if is_unst else random.randint(1, 3))

    def reset(self):
        self.min_ping, self.max_ping, self.ping_history, self.recent = 9999, 0, [], []
        self.itemconfigure(self.txt_min, text="Min\n---")
        self.itemconfigure(self.txt_max, text="Max\n---")
        self._anim(225, "#00FF00")


class SystemMonitorCanvas(tk.Canvas):
    def __init__(self, parent, **kw):
        super().__init__(parent, bg="#1a1a1a", highlightthickness=0, height=30, **kw)
        self.segment_width = 3
        self.segment_spacing = 2
        self.cpu_bg = None
        self.ram_bg = None
        self.cpu_segments = []
        self.ram_segments = []
        self.cpu_text = None
        self.ram_text = None
        self.separator = None
        self.bind("<Configure>", self._on_resize)
        self.current_cpu = 0
        self.current_ram = 0
    
    def _on_resize(self, event=None):
        width = self.winfo_width()
        height = self.winfo_height()
        
        if width <= 1 or height <= 1:
            return
        
        self.delete("all")
        
        bar_height = 20
        margin_y = (height - bar_height) // 2
        text_space = 200
        available_for_bars = width - text_space - 20
        bar_width = max(80, int(available_for_bars / 2))
        bar_width = min(bar_width, int(width * 0.35))
        num_segments = max(10, (bar_width - 4) // (self.segment_width + self.segment_spacing))
        margin_x = 5
        
        self.cpu_bg = self.create_rectangle(margin_x, margin_y, margin_x + bar_width, margin_y + bar_height, 
                                           fill="#0a0a0a", outline="#333333", width=1)
        self.ram_bg = self.create_rectangle(width - margin_x - bar_width, margin_y, 
                                           width - margin_x, margin_y + bar_height, 
                                           fill="#0a0a0a", outline="#333333", width=1)
        
        self.cpu_segments = []
        start_x = margin_x + 2
        seg_margin_y = margin_y + 2
        seg_height = bar_height - 4
        
        for i in range(num_segments):
            x = start_x + i * (self.segment_width + self.segment_spacing)
            if x + self.segment_width > margin_x + bar_width - 2:
                break
            seg = self.create_rectangle(x, seg_margin_y, x + self.segment_width, 
                                       seg_margin_y + seg_height, 
                                       fill="#0a0a0a", outline="")
            self.cpu_segments.append(seg)
        
        self.ram_segments = []
        start_x_ram = width - margin_x - 2 - self.segment_width
        
        for i in range(num_segments):
            x = start_x_ram - i * (self.segment_width + self.segment_spacing)
            if x < width - margin_x - bar_width + 2:
                break
            seg = self.create_rectangle(x, seg_margin_y, x + self.segment_width, 
                                       seg_margin_y + seg_height, 
                                       fill="#0a0a0a", outline="")
            self.ram_segments.append(seg)
        
        text_x_cpu = margin_x + bar_width + 10
        text_x_ram = width - margin_x - bar_width - 10
        
        self.cpu_text = self.create_text(text_x_cpu, height//2, text="CPU: --%", fill="#AAAAAA", 
                                         font=("Arial", 9), anchor="w")
        self.ram_text = self.create_text(text_x_ram, height//2, text="RAM: --%", fill="#AAAAAA", 
                                         font=("Arial", 9), anchor="e")
        self.separator = self.create_text(width//2, height//2, text="|", fill="#555555", font=("Arial", 9))
        
        self._update_segments(self.current_cpu, self.current_ram)
    
    def update_values(self, cpu_percent, ram_percent):
        self.current_cpu = cpu_percent
        self.current_ram = ram_percent
        
        if self.cpu_text and self.ram_text:
            self.itemconfig(self.cpu_text, text=f"CPU: {cpu_percent:.1f}%")
            self.itemconfig(self.ram_text, text=f"RAM: {ram_percent:.1f}%")
        
        self._update_segments(cpu_percent, ram_percent)
    
    def _update_segments(self, cpu_percent, ram_percent):
        num_cpu_segments = len(self.cpu_segments)
        if num_cpu_segments > 0:
            segments_to_fill_cpu = int((cpu_percent / 100) * num_cpu_segments)
            for i, seg in enumerate(self.cpu_segments):
                if i < segments_to_fill_cpu:
                    seg_percent = ((i + 1) / num_cpu_segments) * 100
                    color = self._get_color_for_percent(seg_percent)
                    self.itemconfig(seg, fill=color)
                else:
                    self.itemconfig(seg, fill="#0a0a0a")
        
        num_ram_segments = len(self.ram_segments)
        if num_ram_segments > 0:
            segments_to_fill_ram = int((ram_percent / 100) * num_ram_segments)
            for i, seg in enumerate(self.ram_segments):
                if i < segments_to_fill_ram:
                    seg_percent = ((i + 1) / num_ram_segments) * 100
                    color = self._get_color_for_percent(seg_percent)
                    self.itemconfig(seg, fill=color)
                else:
                    self.itemconfig(seg, fill="#0a0a0a")
    
    def _get_color_for_percent(self, percent):
        if percent <= 50:
            ratio = percent / 50
            r = int(255 * ratio)
            g = 255
            b = 0
        else:
            ratio = (percent - 50) / 50
            r = 255
            g = int(255 * (1 - ratio))
            b = 0
        return f"#{r:02x}{g:02x}{b:02x}"


class PingApp:
    def __init__(self, root):
        self.root = root
        root.title("Monitor de Ping")
        root.geometry("700x340")
        root.configure(bg="#000000")
        self.ips = ["...", "...", "9.9.9.9"]
        self.titles = ["Gateway Local", "Provedor", "Internet"]
        self.gauges = []
        self.q = queue.Queue()
        self.mon = True
        
        mb = tk.Menu(root)
        m_arq = tk.Menu(mb, tearoff=0)
        m_arq.add_command(label="Sair", command=self.close, accelerator="Ctrl+Q")
        mb.add_cascade(label="Arquivo", menu=m_arq)
        
        m_fer = tk.Menu(mb, tearoff=0)
        m_fer.add_command(label="Estatísticas Detalhadas", command=self.stats, accelerator="Ctrl+S")
        m_fer.add_command(label="Zerar Dados", command=self.confirm_reset, accelerator="Ctrl+R")
        m_fer.add_separator()
        m_fer.add_command(label="Configurar Sensibilidade...", command=self.open_config)
        mb.add_cascade(label="Ferramentas", menu=m_fer)
        
        m_aju = tk.Menu(mb, tearoff=0)
        m_aju.add_command(label="Sobre", command=self.about)
        mb.add_cascade(label="Ajuda", menu=m_aju)
        root.config(menu=mb)
        
        root.bind("<Control-q>", lambda e: self.close())
        root.bind("<Control-r>", lambda e: self.confirm_reset())
        root.bind("<Control-s>", lambda e: self.stats())

        mf = tk.Frame(root, bg="#000000")
        mf.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
        for t in self.titles:
            g = PingGauge(mf, title=t, size=220)
            g.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
            self.gauges.append(g)

        style = ttk.Style()
        style.theme_use('clam')
        style.configure('D.TButton', background='#1a1a1a', foreground='#FFF', borderwidth=1)
        style.map('D.TButton', background=[('active', '#333')], foreground=[('active', '#FFF')])

        bf = tk.Frame(root, bg="#000000")
        bf.pack(fill='x', padx=10, pady=(0,10))
        ttk.Button(bf, text="Stats", command=self.stats, style='D.TButton').pack(side=tk.LEFT, padx=5)
        ttk.Button(bf, text="Zerar", command=self.confirm_reset, style='D.TButton').pack(side=tk.LEFT, padx=5)
        
        self.sys_monitor = SystemMonitorCanvas(bf)
        self.sys_monitor.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=5)
        
        ttk.Button(bf, text="Sair", command=self.close, style='D.TButton').pack(side=tk.RIGHT, padx=5)

        root.protocol("WM_DELETE_WINDOW", self.close)
        threading.Thread(target=self.disc_gw, daemon=True).start()
        threading.Thread(target=self.loop, daemon=True).start()
        self.update_ui()
        self.update_sys()

    def confirm_reset(self):
        if messagebox.askyesno("Confirmar", "Deseja realmente zerar todo o histórico?"):
            [g.reset() for g in self.gauges]

    def open_config(self):
        w = tk.Toplevel(self.root)
        w.title("Configurações")
        w.configure(bg="#000000")
        w.geometry("300x180")
        ttk.Label(w, text="Variação Mínima (ms):", background="#000", foreground="#FFF").pack(pady=(15,5))
        e_ms = ttk.Entry(w)
        e_ms.pack()
        e_ms.insert(0, str(PingGauge.LED_CONF['min_ms']))
        ttk.Label(w, text="Variação Percentual (%):", background="#000", foreground="#FFF").pack(pady=(10,5))
        e_pct = ttk.Entry(w)
        e_pct.pack()
        e_pct.insert(0, str(PingGauge.LED_CONF['var_pct']))
        def save():
            try:
                ms, pct = int(e_ms.get()), float(e_pct.get())
                PingGauge.LED_CONF.update({'min_ms': ms, 'var_pct': pct})
                w.destroy()
            except ValueError:
                messagebox.showerror("Erro", "Use apenas números.", parent=w)
        ttk.Button(w, text="Salvar", command=save, style='D.TButton').pack(pady=20)

    def about(self):
        messagebox.showinfo("Sobre", "Monitor de Ping v1.0\n\nFerramenta de diagnóstico de rede com estilo automotivo.\nOtimizado para detecção de jitter e latência.")

    def update_sys(self):
        if not self.mon:
            return
        if HAS_PSUTIL:
            try: 
                cpu = psutil.cpu_percent(interval=None)
                ram = psutil.virtual_memory().percent
                self.sys_monitor.update_values(cpu, ram)
            except:
                pass
        self.root.after(1000, self.update_sys)

    def disc_gw(self):
        if platform.system() != "Windows":
            self.ips = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
            self.upd_titles()
            return
        try:
            out = subprocess.check_output(["tracert", "-w", "100", "-h", "15", "9.9.9.9"], encoding='latin-1', creationflags=0x08000000)
            hops = []
            for line in out.splitlines():
                if m := re.search(r'(\d+\.\d+\.\d+\.\d+)', line):
                    if m.group(1) != "9.9.9.9" and m.group(1) not in [h[0] for h in hops]:
                        hops.append((m.group(1), line.split()[1] if '[' in line else ""))
            types = [('L' if ipaddress.ip_address(ip).is_private and not str(ip).startswith("100.64") else 'C' if str(ip).startswith("100.64") else 'P') for ip, _ in hops]
            gw = next((hops[i][0] for i in range(len(types)-1) if types[i]=='L' and types[i+1]!='L'), hops[0][0] if hops else "?")
            prov = None
            pubs = [(ip, nm) for (ip, nm), t in zip(hops, types) if t == 'P']
            if pubs:
                doms = [n.split('.')[-2:] for _, n in pubs if n]
                if doms:
                    prov = next((ip for ip, nm in pubs if '.'.join(doms[0]) in nm), None)
                if not prov:
                    prov = pubs[0][0]
            self.ips = [gw, prov or (hops[-1][0] if hops else "?"), "9.9.9.9"]
        except:
            self.ips = ["Erro", "Erro", "9.9.9.9"]
        self.root.after(0, self.upd_titles)

    def upd_titles(self):
        [g.set_title(t.split()[0], f"({ip})") for g, t, ip in zip(self.gauges, self.titles, self.ips)]
    
    def loop(self):
        while self.mon:
            res = []
            for ip in self.ips:
                if ip in ["...", "Erro", "?"]:
                    res.append(None)
                    continue
                try:
                    o = subprocess.check_output(['ping', '-n', '1', '-w', '1000', ip], creationflags=0x08000000, encoding='cp850')
                    res.append(int(float(re.search(r'[=<]([0-9]+)ms', o).group(1))))
                except:
                    res.append(None)
            self.q.put(res)
            time.sleep(1)

    def update_ui(self):
        try:
            while True:
                [g.update_ping(r) for g, r in zip(self.gauges, self.q.get_nowait())]
        except queue.Empty:
            pass
        if self.mon:
            self.root.after(100, self.update_ui)

    def stats(self):
        w = tk.Toplevel(self.root)
        w.title("Stats")
        w.configure(bg="#000")
        for g, t in zip(self.gauges, self.titles):
            h = g.ping_history
            txt = f"{t}: Min={g.min_ping} Méd={sum(h)/len(h):.1f} Max={g.max_ping}" if h else f"{t}: ---"
            ttk.Label(w, text=txt, background="#000", foreground="#FFF").pack(pady=5, padx=10)

    def close(self):
        self.mon = False
        self.root.destroy()

if __name__ == "__main__":
    r = tk.Tk()
    PingApp(r)
    r.mainloop()
