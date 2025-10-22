# Nome do arquivo: banco_de_dados.py

import requests
from concurrent.futures import ThreadPoolExecutor
from tqdm import tqdm
from threading import Lock, Semaphore
import random
import argparse
import sys
import time

class BancoDeDadosLotofacil:
    def __init__(self, filename='banco_de_dados.txt'):
        self.filename = filename
        self.lock = Lock()
        self.rate_limit_semaphore = Semaphore(4)  # Limitar a 4 requisições paralelas
        self.headers = {
            "user-agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
                " AppleWebKit/537.36 (KHTML, like Gecko)"
                " Chrome/138.0.0.0 Safari/537.36"
            )
        }
        # Configurações específicas da Lotofácil
        self.modalidade = "lotofacil"
        self.num_dezenas = 15
        self.delay_requisicao = 1  # segundos entre requisições
        self.max_workers = 4
        self.timeout_requisicao = 10

    def buscar_concurso(self, numero):
        """
        Faz a requisição à API da Caixa para obter informações
        de um determinado concurso da Lotofácil.
        Caso 'numero' seja string vazia (""), tenta buscar o concurso mais recente.
        """
        # Usar semáforo para limitar requisições paralelas
        with self.rate_limit_semaphore:
            # Adicionar delay entre requisições
            time.sleep(self.delay_requisicao)
            
            url = f"https://servicebus2.caixa.gov.br/portaldeloterias/api/{self.modalidade}/{numero}"
            try:
                response = requests.get(url, timeout=self.timeout_requisicao, headers=self.headers)
                response.raise_for_status()
                data = response.json()
                if not data:
                    raise ValueError(f"Resposta vazia para o concurso {numero}")
                return data
            except requests.exceptions.RequestException as e:
                print(f"Erro na requisição para o concurso {numero}: {e}")
                return None
            except ValueError as e:
                print(f"Erro no processamento do concurso {numero}: {e}")
                return None

    def criar_atualizar_banco_de_dados(self, status_callback=None, progresso_callback=None):
        """
        Cria ou atualiza o banco de dados local (arquivo texto) com todos
        os concursos da Lotofácil, do 1 até o mais recente disponível na API.
        
        - status_callback: função para receber mensagens de status
        - progresso_callback: função para receber percentual de progresso e número do concurso
        """
        try:
            # Carregar concursos existentes do arquivo
            try:
                with open(self.filename, 'r') as file:
                    dados_existentes = {}
                    for line in file.readlines():
                        parts = line.strip().split(',')
                        if len(parts) >= (self.num_dezenas + 1):  # Garantir que tem número do concurso + dezenas
                            num_concurso = int(parts[0])
                            # Converter para inteiro, ordenar e formatar com dois dígitos
                            dezenas = sorted([int(d) for d in parts[1:(self.num_dezenas + 1)]])
                            dezenas_formatadas = [f"{d:02d}" for d in dezenas]
                            linha_ordenada = f"{num_concurso},{','.join(dezenas_formatadas)}"
                            dados_existentes[num_concurso] = linha_ordenada
                    ultimo_concurso_local = max(dados_existentes.keys()) if dados_existentes else 0
            except FileNotFoundError:
                dados_existentes = {}
                ultimo_concurso_local = 0

            # Buscar o último concurso disponível na API (string vazia -> concurso mais recente)
            if status_callback:
                status_callback("Buscando informações do último concurso...")
            
            ultimo_dado = self.buscar_concurso("")
            if not ultimo_dado:
                if status_callback:
                    status_callback(
                        "Erro ao buscar o último concurso. "
                        "Verifique sua conexão ou a API."
                    )
                return

            ultimo_numero = int(ultimo_dado["numero"])

            if status_callback:
                status_callback(f"Último concurso disponível: {ultimo_numero}")

            # Identificar quais concursos estão ausentes
            sequencia_completa = set(range(1, ultimo_numero + 1))
            concursos_existentes = set(dados_existentes.keys())
            concursos_ausentes = list(sequencia_completa - concursos_existentes)
            
            if not concursos_ausentes:
                if status_callback:
                    status_callback("Banco de dados completo. Nenhum concurso ausente.")
                return

            if status_callback:
                status_callback(
                    f"Concursos ausentes identificados: {len(concursos_ausentes)}"
                )

            # Embaralhar a lista de concursos ausentes para evitar sobrecarga na API
            random.shuffle(concursos_ausentes)

            # Baixar concursos ausentes
            novos_dados = []
            with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
                futuros = {
                    executor.submit(self.buscar_concurso, numero): numero
                    for numero in concursos_ausentes
                }

                for i, futuro in enumerate(tqdm(futuros, desc="Baixando concursos", unit="concurso")):
                    numero = futuros[futuro]
                    try:
                        concurso = futuro.result()
                        if concurso is None:
                            if status_callback:
                                status_callback(
                                    f"Concurso {numero} não pôde ser baixado. Pulando."
                                )
                            continue

                        dezenas = concurso.get("dezenasSorteadasOrdemSorteio")
                        if dezenas and len(dezenas) == self.num_dezenas:
                            # Ordenar as dezenas e formatar com dois dígitos
                            dezenas_ordenadas = sorted([int(d) for d in dezenas])
                            dezenas_formatadas = [f"{d:02d}" for d in dezenas_ordenadas]
                            novos_dados.append((numero, dezenas_formatadas))
                            if progresso_callback:
                                progresso_callback(
                                    (i + 1) / len(concursos_ausentes) * 100,
                                    numero
                                )
                        else:
                            if status_callback:
                                status_callback(
                                    f"Concurso {numero} com dados inválidos. "
                                    f"Esperado {self.num_dezenas} dezenas, "
                                    f"encontrado {len(dezenas) if dezenas else 0}. Pulando."
                                )
                    except Exception as e:
                        if status_callback:
                            status_callback(
                                f"Erro ao processar concurso {numero}: {str(e)}"
                            )

            # Atualizar dados existentes
            for numero, dezenas in novos_dados:
                dados_existentes[numero] = f"{numero},{','.join(dezenas)}"

            # Salvar concursos ordenados por número
            dados_ordenados = sorted(
                dados_existentes.values(),
                key=lambda x: int(x.split(",")[0])
            )
            
            with self.lock, open(self.filename, 'w') as file:
                file.write("\n".join(dados_ordenados) + "\n")

            if status_callback:
                status_callback(f"Banco de dados atualizado com sucesso. {len(novos_dados)} novos concursos adicionados.")

            # Verificar se todos os concursos estão presentes
            concursos_faltando = sequencia_completa - set(dados_existentes.keys())
            if concursos_faltando:
                if status_callback:
                    status_callback(
                        f"Ainda faltam {len(concursos_faltando)} concursos: {sorted(concursos_faltando)}"
                    )
            else:
                if status_callback:
                    status_callback("Banco de dados completo e consistente.")

        except Exception as e:
            if status_callback:
                status_callback(f"Erro na atualização do banco de dados: {str(e)}")

    def obter_total_concursos(self):
        """
        Retorna quantas linhas (concursos) há no arquivo (banco_de_dados_lotofacil.txt).
        """
        try:
            with open(self.filename, "r") as file:
                return len(file.readlines())
        except FileNotFoundError:
            return 0

    def obter_ultimo_concurso(self):
        """
        Retorna o número do último concurso armazenado no arquivo local,
        ou None se o arquivo estiver vazio ou não existir.
        """
        try:
            with open(self.filename, 'r') as file:
                dados_existentes = file.readlines()
                if dados_existentes:
                    return int(dados_existentes[-1].split(",")[0])
                else:
                    return None
        except FileNotFoundError:
            return None

    def recuperar_todos_jogos(self):
        """
        Lê o arquivo e retorna uma lista de tuplas:
          [(num_concurso, [d1, d2, ..., d15]), ...]
        """
        jogos = []
        try:
            with open(self.filename, 'r') as file:
                lines = file.readlines()

            for line in lines:
                parts = line.strip().split(',')
                # parts[0] = número do concurso
                # parts[1..15] = as dezenas
                if len(parts) == (self.num_dezenas + 1):
                    num_concurso = int(parts[0])
                    dezenas = [int(x) for x in parts[1:(self.num_dezenas + 1)]]
                    jogos.append((num_concurso, dezenas))
        except FileNotFoundError:
            pass

        return jogos

    def obter_info_banco(self):
        """
        Retorna (total_concursos, ultimo_concurso).
        """
        total = self.obter_total_concursos()
        ultimo = self.obter_ultimo_concurso()
        return (total, ultimo)

def main():
    """
    Função principal para executar o script de forma autônoma.
    """
    parser = argparse.ArgumentParser(description='Atualizar banco de dados da Lotofácil')
    parser.add_argument('--arquivo', '-a', default='banco_de_dados.txt', 
                       help='Nome do arquivo para salvar os dados')
    parser.add_argument('--verbose', '-v', action='store_true', 
                       help='Modo verboso para mostrar mais informações')
    
    args = parser.parse_args()
    
    # Criar instância do banco de dados
    banco = BancoDeDadosLotofacil(filename=args.arquivo)
    
    # Função de callback para status
    def status_callback(mensagem):
        if args.verbose:
            print(mensagem)
    
    # Função de callback para progresso (apenas modo verboso)
    def progresso_callback(percentual, numero):
        if args.verbose:
            print(f"Progresso: {percentual:.1f}% - Concurso {numero}")
    
    print("Iniciando atualização do banco de dados da Lotofácil...")
    
    # Obter informações atuais
    total_atual, ultimo_atual = banco.obter_info_banco()
    if total_atual > 0:
        print(f"Banco atual: {total_atual} concursos, último: {ultimo_atual}")
    else:
        print("Nenhum concurso encontrado no banco atual. Criando novo banco.")
    
    # Atualizar o banco de dados
    banco.criar_atualizar_banco_de_dados(
        status_callback=status_callback if args.verbose else None,
        progresso_callback=progresso_callback if args.verbose else None
    )
    
    # Mostrar informações finais
    total_final, ultimo_final = banco.obter_info_banco()
    print(f"Atualização concluída. Total de concursos: {total_final}, Último concurso: {ultimo_final}")

if __name__ == "__main__":
    main()