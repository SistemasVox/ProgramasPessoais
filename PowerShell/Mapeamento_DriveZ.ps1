$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument '/c net use Z: /delete /yes && net use Z: "\\10.98.0.11\Departamento Pessoal" /persistent:yes'
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "Mapear Unidade Z" -Action $action -Trigger $trigger -Description "Mapeia a unidade Z no startup" -RunLevel Highest
