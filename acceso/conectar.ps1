param(
    [switch]$Lan,
    [switch]$SinNavegador
)

$ErrorActionPreference = 'Stop'
$destino = if ($Lan) { 'servidor-mon-lan' } else { 'servidor-mon' }
$puertos = @{ Grafana = 13000; Cockpit = 19090 }

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw 'No encuentro ssh. Instala el cliente OpenSSH de Windows.'
}
if (-not $Lan -and -not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
    throw 'No encuentro cloudflared. Instálalo con: winget install --id Cloudflare.cloudflared'
}

foreach ($p in $puertos.Values) {
    if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) {
        throw "El puerto local $p ya está en uso. Cierra el túnel anterior o lo que use ese puerto."
    }
}

function Abrir-Tunel {
    $proceso = Start-Process ssh -ArgumentList '-N', $destino -PassThru -NoNewWindow
    for ($i = 0; $i -lt 30 -and -not $proceso.HasExited; $i++) {
        if (Get-NetTCPConnection -LocalPort $puertos.Grafana -State Listen -ErrorAction SilentlyContinue) { return $proceso }
        Start-Sleep -Seconds 1
    }
    if (-not $proceso.HasExited) { Stop-Process -Id $proceso.Id }
    return $null
}

Write-Host "Abriendo túnel con $destino ..."
$tunel = Abrir-Tunel
if (-not $tunel) { throw 'El túnel no se abrió. Prueba a mano: ssh -v ' + $destino }

Write-Host "Grafana: http://localhost:$($puertos.Grafana)  (usuario admin)"
Write-Host "Cockpit: http://localhost:$($puertos.Cockpit)  (tu usuario del servidor)"
if (-not $SinNavegador) {
    Start-Process "http://localhost:$($puertos.Grafana)"
    Start-Process "http://localhost:$($puertos.Cockpit)"
}

Write-Host 'Túnel activo. Se reconecta solo si el servidor se reinicia. Ctrl+C para cerrarlo.'
try {
    while ($true) {
        Wait-Process -Id $tunel.Id
        Write-Host "$(Get-Date -Format HH:mm:ss) Túnel caído. Reintentando cada 10 s ..."
        do {
            Start-Sleep -Seconds 10
            $tunel = Abrir-Tunel
        } until ($tunel)
        Write-Host "$(Get-Date -Format HH:mm:ss) Túnel restablecido."
    }
} finally {
    if ($tunel -and -not $tunel.HasExited) { Stop-Process -Id $tunel.Id }
}
