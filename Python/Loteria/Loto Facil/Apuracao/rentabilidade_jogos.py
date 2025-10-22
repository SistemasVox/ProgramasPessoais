import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext
import csv
import threading
import re
import locale
import requests
import json
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

try:
    locale.setlocale(locale.LC_ALL, 'pt_BR.UTF-8')
except locale.Error:
    print("Locale 'pt_BR.UTF-8' não encontrado. Usando formatação manual.")

def formatar_brl(valor):
    try:
        return locale.currency(valor, grouping=True)
    except NameError:
        return f"R$ {valor:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")

PREMIOS = { 11: 7.00, 12: 14.00, 13: 35.00, 14: 1500.00, 15: 1800000.00 }
CUSTO_JOGO = 3.50

def ler_csv_para_analise(path):
    jogos = []
    with open(path, encoding='utf-8') as f:
        reader = csv.reader(f)
        for row in reader:
            dezenas = [int(x.strip()) for x in row if x.strip().isdigit()]
            if len(dezenas) == 15:
                jogos.append(dezenas)
    return jogos

def parse_dezenas_ganhadoras(texto_entrada):
    numeros_str = re.sub(r'\D', '', texto_entrada)
    if len(numeros_str) != 30:
        messagebox.showerror("Erro de Entrada", f"São necessários 30 dígitos para formar 15 dezenas (ex: 010203...). Você forneceu {len(numeros_str)}.")
        return None
    try:
        dezenas = {int(numeros_str[i:i+2]) for i in range(0, len(numeros_str), 2)}
        if len(dezenas) != 15:
            messagebox.showerror("Erro de Validação", "As dezenas contêm números repetidos. São necessárias 15 dezenas únicas.")
            return None
        if any(d < 1 or d > 25 for d in dezenas):
            messagebox.showerror("Erro de Validação", "Todas as dezenas devem estar entre 01 e 25.")
            return None
        return dezenas
    except ValueError:
        messagebox.showerror("Erro de Conversão", "Não foi possível converter as dezenas. Verifique o formato.")
        return None

def calcular_rentabilidade(jogos, dezenas_ganhadoras_set):
    custo_total = len(jogos) * CUSTO_JOGO
    ganho_total = 0.0
    contagem_premios = {11: 0, 12: 0, 13: 0, 14: 0, 15: 0}
    jogos_premiados = []

    for idx, jogo in enumerate(jogos):
        acertos = len(set(jogo) & dezenas_ganhadoras_set)
        if acertos in PREMIOS:
            premio_valor = PREMIOS[acertos]
            ganho_total += premio_valor
            contagem_premios[acertos] += 1
            jogos_premiados.append({'num_jogo': idx + 1, 'jogo': jogo, 'acertos': acertos, 'premio': premio_valor})
    
    balanco = ganho_total - custo_total
    percentual_retorno = (balanco / custo_total * 100) if custo_total > 0 else 0.0
    
    return {'custo_total': custo_total, 'ganho_total': ganho_total, 'balanco': balanco, 
            'percentual_retorno': percentual_retorno, 'contagem_premios': contagem_premios, 
            'jogos_premiados': sorted(jogos_premiados, key=lambda x: x['acertos'], reverse=True),
            'total_jogos': len(jogos)}

def obter_ultimo_sorteio():
    url = "https://servicebus2.caixa.gov.br/portaldeloterias/api/lotofacil/"
    try:
        response = requests.get(url, verify=False, timeout=10)
        response.raise_for_status()
        dados = response.json()
        
        dezenas_sorteadas = dados.get('listaDezenas') 
        num_concurso = dados.get('numero')
        
        if not dezenas_sorteadas or len(dezenas_sorteadas) != 15:
            return None, "API retornou dados inválidos."
        
        dezenas_str = " ".join([f"{int(d):02}" for d in dezenas_sorteadas])
        
        return dezenas_str, num_concurso
    except requests.exceptions.RequestException as e:
        return None, f"Erro de conexão: {e}"
    except json.JSONDecodeError:
        return None, "Erro ao processar a resposta da API."

def mostrar_resultados(resultados):
    resultado_texto.delete(1.0, tk.END)
    balanco_str = "Lucro" if resultados['balanco'] >= 0 else "Prejuízo"
    percentual_str = f"({resultados['percentual_retorno']:+.2f}%)".replace('.', ',')
    
    total_jogos_str = f"({resultados['total_jogos']:,} jogos)".replace(',', '.')

    resultado_texto.insert(tk.END, "--- Resumo Financeiro ---\n")
    resultado_texto.insert(tk.END, f"Custo Total das Apostas: {formatar_brl(resultados['custo_total'])} {total_jogos_str}\n")
    resultado_texto.insert(tk.END, f"Ganho Total com Prêmios: {formatar_brl(resultados['ganho_total'])}\n")
    resultado_texto.insert(tk.END, f"Balanço Final ({balanco_str}): {formatar_brl(resultados['balanco'])} {percentual_str}\n\n")

    resultado_texto.insert(tk.END, "--- Resumo de Prêmios ---\n")
    if any(resultados['contagem_premios'].values()):
        for acertos, quantidade in resultados['contagem_premios'].items():
            if quantidade > 0:
                premio_unitario = PREMIOS.get(acertos, 0)
                total_faixa = quantidade * premio_unitario
                resultado_texto.insert(tk.END, f"Jogos com {acertos} acertos: {quantidade} (Prêmio: {formatar_brl(premio_unitario)}) | Total Faixa: {formatar_brl(total_faixa)}\n")
    else:
        resultado_texto.insert(tk.END, "Nenhum jogo foi premiado.\n")
    
    if resultados['jogos_premiados']:
        resultado_texto.insert(tk.END, "\n--- Detalhes dos Jogos Premiados ---\n")
        for jogo_info in resultados['jogos_premiados']:
            jogo_str = ', '.join(f"{d:02}" for d in sorted(jogo_info['jogo']))
            resultado_texto.insert(tk.END, f"Jogo Nº {jogo_info['num_jogo']} | {jogo_info['acertos']} acertos | Prêmio: {formatar_brl(jogo_info['premio'])}\n")
            resultado_texto.insert(tk.END, f"  Dezenas: {jogo_str}\n")
    status_label['text'] = "Cálculo concluído."

def iniciar_calculo_thread():
    if not jogos_globais:
        messagebox.showinfo("Aviso", "Por favor, abra um arquivo CSV com os jogos primeiro.")
        return
    dezenas_ganhadoras = parse_dezenas_ganhadoras(dezenas_entry.get())
    if dezenas_ganhadoras is None: return
    status_label['text'] = "Calculando..."
    resultado_texto.delete(1.0, tk.END)
    def tarefa():
        resultados = calcular_rentabilidade(jogos_globais, dezenas_ganhadoras)
        root.after(0, mostrar_resultados, resultados)
    threading.Thread(target=tarefa, daemon=True).start()

def abrir_csv():
    global jogos_globais
    path = filedialog.askopenfilename(filetypes=[("CSV files", "*.csv")])
    if not path: return
    try:
        jogos_globais = ler_csv_para_analise(path)
        if not jogos_globais:
            messagebox.showerror("Erro", "Nenhum jogo válido (com 15 dezenas) encontrado.")
            status_label['text'] = "Falha ao carregar arquivo."
            return
        status_label['text'] = f"{len(jogos_globais)} jogos carregados. Insira as dezenas sorteadas."
    except Exception as e:
        messagebox.showerror("Erro de Leitura", f"Ocorreu um erro ao ler o arquivo:\n{e}")
        status_label['text'] = "Aguardando ação."

def carregar_ultimo_sorteio_thread():
    status_label['text'] = "Buscando último sorteio online..."
    def tarefa():
        dezenas_str, num_concurso = obter_ultimo_sorteio()
        def atualizar_gui():
            if dezenas_str:
                dezenas_entry.delete(0, tk.END)
                dezenas_entry.insert(0, dezenas_str)
                status_label['text'] = f"Resultado do concurso {num_concurso} carregado. Clique em 'Calcular'."
            else:
                messagebox.showerror("Falha na Busca", f"Não foi possível obter o último resultado.\nMotivo: {num_concurso}")
                status_label['text'] = "Falha ao buscar sorteio."
        root.after(0, atualizar_gui)
    threading.Thread(target=tarefa, daemon=True).start()

def limpar_tela():
    dezenas_entry.delete(0, tk.END)
    resultado_texto.delete(1.0, tk.END)
    status_label['text'] = "Aguardando ação."

def salvar_relatorio():
    texto = resultado_texto.get("1.0", tk.END)
    if not texto.strip():
        messagebox.showinfo("Info", "Nada para salvar.")
        return
    path = filedialog.asksaveasfilename(defaultextension=".txt", filetypes=[("Text files", "*.txt"), ("All files", "*.*")])
    if path:
        try:
            with open(path, 'w', encoding='utf-8') as f: f.write(texto)
            messagebox.showinfo("Sucesso", "Relatório salvo com sucesso!")
        except Exception as e:
            messagebox.showerror("Erro ao Salvar", f"Não foi possível salvar o arquivo:\n{e}")

def mostrar_sobre():
    messagebox.showinfo("Sobre", "Analisador de Rentabilidade de Jogos v2.3\n\nDesenvolvido com o auxílio de IA (Gemini).")

root = tk.Tk()
root.title("Analisador de Rentabilidade de Jogos")
root.geometry("800x650")

entrada_frame = tk.LabelFrame(root, text="Dados de Análise", padx=5, pady=5)
entrada_frame.pack(padx=10, pady=10, fill='x')
btn_abrir = tk.Button(entrada_frame, text="1. Abrir Arquivo CSV", command=abrir_csv)
btn_abrir.pack(side=tk.LEFT, padx=(5, 10))
dezenas_label = tk.Label(entrada_frame, text="2. Dezenas Ganhadoras:")
dezenas_label.pack(side=tk.LEFT, padx=5)
dezenas_entry = tk.Entry(entrada_frame, width=40)
dezenas_entry.pack(side=tk.LEFT, expand=True, fill='x', padx=5)
btn_calcular = tk.Button(entrada_frame, text="3. Calcular Rentabilidade", command=iniciar_calculo_thread, font=('helvetica', 10, 'bold'))
btn_calcular.pack(side=tk.LEFT, padx=(10, 5))

botoes_frame = tk.Frame(root)
botoes_frame.pack(padx=10, pady=5, fill='x')
btn_carregar_sorteio = tk.Button(botoes_frame, text="Carregar Último Sorteio (Online)", command=carregar_ultimo_sorteio_thread)
btn_carregar_sorteio.pack(side=tk.LEFT, padx=5)
btn_limpar = tk.Button(botoes_frame, text="Limpar", command=limpar_tela)
btn_limpar.pack(side=tk.LEFT, padx=5)
btn_salvar = tk.Button(botoes_frame, text="Salvar Relatório", command=salvar_relatorio)
btn_salvar.pack(side=tk.LEFT, padx=5)
btn_sobre = tk.Button(botoes_frame, text="Sobre", command=mostrar_sobre)
btn_sobre.pack(side=tk.RIGHT, padx=5)
btn_sair = tk.Button(botoes_frame, text="Sair", command=root.quit)
btn_sair.pack(side=tk.RIGHT, padx=5)

resultado_frame = tk.LabelFrame(root, text="Relatório de Análise", padx=5, pady=5)
resultado_frame.pack(padx=10, pady=10, expand=True, fill='both')
resultado_texto = scrolledtext.ScrolledText(resultado_frame, width=90, height=30, font=("Courier New", 9))
resultado_texto.pack(expand=True, fill='both')

status_label = tk.Label(root, text="Aguardando ação...", bd=1, relief=tk.SUNKEN, anchor=tk.W)
status_label.pack(side=tk.BOTTOM, fill='x')

jogos_globais = []
root.mainloop()