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

Write-Host "Abriendo túnel con $destino ..."
$tunel = Start-Process ssh -ArgumentList '-N', $destino -PassThru -NoNewWindow

$listo = $false
for ($i = 0; $i -lt 30 -and -not $tunel.HasExited; $i++) {
    if (Get-NetTCPConnection -LocalPort $puertos.Grafana -State Listen -ErrorAction SilentlyContinue) { $listo = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $listo) {
    if (-not $tunel.HasExited) { Stop-Process -Id $tunel.Id }
    throw 'El túnel no se abrió. Prueba a mano: ssh -v ' + $destino
}

Write-Host "Grafana: http://localhost:$($puertos.Grafana)  (usuario admin)"
Write-Host "Cockpit: http://localhost:$($puertos.Cockpit)  (tu usuario del servidor)"
if (-not $SinNavegador) {
    Start-Process "http://localhost:$($puertos.Grafana)"
    Start-Process "http://localhost:$($puertos.Cockpit)"
}

Write-Host 'Túnel activo. Presiona Ctrl+C para cerrarlo.'
try { Wait-Process -Id $tunel.Id } finally {
    if (-not $tunel.HasExited) { Stop-Process -Id $tunel.Id }
}
