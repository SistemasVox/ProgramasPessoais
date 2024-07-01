# Desabilita o eco de comandos
$ErrorActionPreference = "Stop"

Write-Output ""
Write-Output "Interfaces de Rede:"
Write-Output ""

# Lista as interfaces de rede
$interfaces = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
$i = 0
$interfaceMap = @{}

foreach ($interface in $interfaces) {
    $i++
    Write-Output "$i. $($interface.Name)"
    $interfaceMap[$i.ToString()] = $interface.Name
}

Write-Output ""
$selection = Read-Host "Selecione o numero da interface que voce deseja alterar"
$interfaceName = $interfaceMap[$selection]

if ([string]::IsNullOrEmpty($interfaceName)) {
    Write-Output "Seleção inválida. Saindo..."
    exit
}

$dnsServers = "1.0.0.1,1.1.1.1,9.9.9.9,9.9.9.10,156.154.71.22,8.8.4.4,156.154.70.22,8.8.8.8,8.26.56.26,8.20.247.20,208.67.222.222,208.67.220.220,216.146.35.35,216.146.36.36"
$dnsServersArray = $dnsServers -split ','

$j = 1
foreach ($dns in $dnsServersArray) {
    if ($j -eq 1) {
        Write-Output "netsh interface ipv4 set dnsservers name='$interfaceName' static $dns primary"
        netsh interface ipv4 set dnsservers name="$interfaceName" static $dns primary
    } else {
        Write-Output "netsh interface ipv4 add dnsservers name='$interfaceName' address=$dns index=$j"
        netsh interface ipv4 add dnsservers name="$interfaceName" address=$dns index=$j
    }
    $j++
}

Write-Output ""
Write-Output "Servidores DNS alterados para a interface $interfaceName"

Write-Output ""
Write-Output "Limpando cache do DNS..."
ipconfig /flushdns

Write-Output ""
Write-Output "Cache do DNS limpo!"
Pause
