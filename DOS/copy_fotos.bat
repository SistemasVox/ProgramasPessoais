:: -------------------------------------------------------------------
:: copy_fotos.bat - Copia aleatoriamente N fotos entre diretórios
:: 
:: Funcionalidade:
::   Seleciona %NUM_PHOTOS% arquivos aleatórios de %SOURCE_DIR%
::   e copia para %DEST_DIR%, mantendo a estrutura original.
::
:: Configurável:
::   - Diretório de origem e destino
::   - Número de arquivos a serem copiados
::
:: Uso: Executar como administrador se necessário
:: -------------------------------------------------------------------

@echo off
setlocal enabledelayedexpansion

:: Mudar para o diretório onde suas fotos estão armazenadas
cd /d "C:\Users\Marcelo\Pictures"

:: Configurações
set SOURCE_DIR=background
set DEST_DIR=background_temp
set NUM_PHOTOS=100

:: Limpar tela
cls

:: Verificar se a pasta origem existe
if not exist "%SOURCE_DIR%" (
    echo Pasta origem %SOURCE_DIR% nao existe!
    echo Diretorio atual: %CD%
    pause
    exit /b
)

:: Remover e recriar diretório destino
if exist "%DEST_DIR%" rmdir /s /q "%DEST_DIR%"
mkdir "%DEST_DIR%"

:: Contar arquivos na origem e criar lista
set count=0
for %%f in ("%SOURCE_DIR%\*.*") do (
    set /a count+=1
    set "file[!count!]=%%~nxf"
)

echo Total de arquivos encontrados: !count!

:: Verificar se há arquivos suficientes
if !count! lss %NUM_PHOTOS% (
    echo Nao ha arquivos suficientes na pasta origem
    pause
    exit /b
)

:: Copiar arquivos aleatoriamente
set copied=0
:copyloop
set /a random_index=!random! %% !count! + 1
set "file=!file[%random_index%]!"

if not exist "%DEST_DIR%\!file!" (
    copy "%SOURCE_DIR%\!file!" "%DEST_DIR%\" >nul
    set /a copied+=1
    echo Copiado !copied!/%NUM_PHOTOS%: !file!
)

if !copied! lss %NUM_PHOTOS% goto copyloop

echo.
echo !copied! fotos copiadas para %DEST_DIR%
pause