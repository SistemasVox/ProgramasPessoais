@echo off
setlocal enabledelayedexpansion

:: =============================================================================
:: Script para copiar fotos aleatoriamente - Versão Otimizada para Grandes Volumes
:: Versao: 2.2 - Aleatoriedade eficiente, sem backup de destino
:: =============================================================================

:: ===== CONFIGURAÇÕES =====
set "BASE_DIR=C:\Users\%USERNAME%\Pictures"
set "SOURCE_DIR=Wallpapers"
set "DEST_DIR=Wallpapers_temp"
set "NUM_PHOTOS=240"

:: Extensoes de imagem suportadas
set "IMG_EXTENSIONS=jpg jpeg"

:: ===== INÍCIO DO PROGRAMA =====
cls
echo.
echo ===============================================================================
echo          SCRIPT PARA COPIA ALEATORIA DE FOTOS - v2.2 ALEATORIEDADE EFICIENTE
echo ===============================================================================
echo.

:: Verificar privilegios
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [INFO] Executando com privilegios administrativos
) else (
    echo [AVISO] Executando sem privilegios administrativos
)

:: Exibir configuracoes
echo.
echo Configuracoes:
echo   Base: %BASE_DIR%
echo   Origem: %SOURCE_DIR%
echo   Destino: %DEST_DIR%
echo   Quantidade: %NUM_PHOTOS%
echo.

:: Mudar para o diretorio base
echo [INFO] Mudando para diretorio base...
cd /d "%BASE_DIR%" 2>nul
if errorlevel 1 (
    echo [ERRO] Nao foi possivel acessar: %BASE_DIR%
    pause
    exit /b 1
)

:: Verificar pasta origem
echo [INFO] Verificando pasta origem...
if not exist "%SOURCE_DIR%" (
    echo [ERRO] Pasta origem nao existe: %SOURCE_DIR%
    pause
    exit /b 1
)

:: Criar lista temporaria de arquivos (MÉTODO OTIMIZADO)
echo [INFO] Criando lista de arquivos... (pode demorar com muitos arquivos)
set "temp_list=%TEMP%\photo_list_%RANDOM%.txt"

(
for %%e in (%IMG_EXTENSIONS%) do (
    dir "%SOURCE_DIR%\*.%%e" /b /a-d 2>nul
)
) > "%temp_list%"

:: Carregar arquivos em array file[]
set i=0
for /f "delims=" %%a in (%temp_list%) do (
    set /a i+=1
    set "file[!i!]=%%a"
)
set total=!i!

echo [INFO] Total de arquivos encontrados: !total!

:: Verificar se ha arquivos
if !total! equ 0 (
    echo [ERRO] Nenhum arquivo de imagem encontrado!
    del "%temp_list%" 2>nul
    pause
    exit /b 1
)

if !total! lss %NUM_PHOTOS% (
    echo [AVISO] Apenas !total! arquivos disponiveis. Copiando todos.
    set NUM_PHOTOS=!total!
)

:: Preparar pasta destino (limpa, sem backup)
echo [INFO] Preparando pasta destino...
if exist "%DEST_DIR%" (
    rmdir /s /q "%DEST_DIR%" 2>nul
)
mkdir "%DEST_DIR%" 2>nul
if errorlevel 1 (
    echo [ERRO] Nao foi possivel criar pasta destino
    del "%temp_list%" 2>nul
    pause
    exit /b 1
)

:: Criar log
set "LOGFILE=%DEST_DIR%\copy_log_%date:~-4%%date:~3,2%%date:~0,2%_%time:~0,2%%time:~3,2%.txt"
set "LOGFILE=!LOGFILE: =0!"

(
echo Log da Operacao - %date% %time%
echo Origem: %SOURCE_DIR% ^(!total! arquivos^)
echo Destino: %DEST_DIR%
echo Solicitados: %NUM_PHOTOS%
echo.
) > "!LOGFILE!"

:: ======= SELECIONAR ARQUIVOS ALEATORIOS UNICOS =========
set "selected="
set count=0

:select_random
if !count! geq %NUM_PHOTOS% goto proceed_copy
set /a idx=(%RANDOM% %% !total!) + 1
echo !selected! | find " !idx! " >nul
if errorlevel 1 (
    set "selected=!selected! !idx! "
    set /a count+=1
)
goto select_random

:proceed_copy
echo [INFO] Iniciando copia aleatoria otimizada...
echo.

set copied=0
set errors=0
set start_time=%time%

for %%j in (!selected!) do (
    set "filename=!file[%%j]!"
    if exist "%SOURCE_DIR%\!filename!" (
        copy "%SOURCE_DIR%\!filename!" "%DEST_DIR%\" >nul 2>nul
        if errorlevel 1 (
            echo [ERRO] !filename!
            echo !filename! - ERRO >> "!LOGFILE!"
            set /a errors+=1
        ) else (
            set /a copied+=1
            echo !filename! >> "!LOGFILE!"
            set /a remainder=!copied! %% 10
            if !remainder! equ 0 (
                set /a percent=!copied!*100/%NUM_PHOTOS%
                echo [!percent!%%] !copied!/!NUM_PHOTOS! - !filename!
            )
            set /a bar_check=!copied! %% 25
            if !bar_check! equ 0 (
                call :show_progress_simple !copied! %NUM_PHOTOS%
            )
        )
    )
)

:: Limpeza de arquivos temporarios
del "%temp_list%" 2>nul

set end_time=%time%

:: Barra final
call :show_progress_simple !copied! %NUM_PHOTOS%

:: Verificacao de integridade rapida
echo.
echo [INFO] Verificando resultado...
set copied_count=0
for %%f in ("%DEST_DIR%\*.*") do (
    set "fname=%%~nxf"
    if not "!fname:~0,8!"=="copy_log" set /a copied_count+=1
)

:: Relatorio final
echo.
echo ===============================================================================
echo                            OPERACAO CONCLUIDA
echo ===============================================================================
echo.
echo Status: CONCLUIDA
echo Arquivos na origem: !total!
echo Arquivos copiados: !copied!/%NUM_PHOTOS%
echo Erros: !errors!
echo Verificacao: !copied_count! arquivos no destino
echo Inicio: !start_time!
echo Termino: !end_time!
echo Log: !LOGFILE!

if !copied_count! neq !copied! (
    echo.
    echo [AVISO] Discrepancia: Esperados !copied!, Encontrados !copied_count!
)

:: Salvar estatisticas
echo. >> "!LOGFILE!"
echo RESULTADO: !copied!/%NUM_PHOTOS% copiados, !errors! erros >> "!LOGFILE!"
echo VERIFICACAO: !copied_count! arquivos no destino >> "!LOGFILE!"
echo HORARIO: !start_time! ate !end_time! >> "!LOGFILE!"

echo.
echo ===============================================================================
echo Pressione qualquer tecla para finalizar...
pause >nul
exit /b 0

:: ===== FUNCAO SIMPLES DE PROGRESSO =====
:show_progress_simple
set /a prog=%1*20/%2
set "bar="
for /l %%i in (1,1,!prog!) do set "bar=!bar!#"
set /a spaces=20-!prog!
for /l %%i in (1,1,!spaces!) do set "bar=!bar!-"
set /a pct=%1*100/%2
echo    [!bar!] !pct!%%
goto :eof
