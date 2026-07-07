param([string]$Expr)
$ErrorActionPreference = "Stop"
$j = Invoke-RestMethod -Uri "http://127.0.0.1:9223/json" -TimeoutSec 5
$page = $j | Where-Object { $_.type -eq "page" } | Select-Object -First 1
$wsUrl = $page.webSocketDebuggerUrl

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$wsUrl, $ct).Wait()

# Build CDP message
$msg = @{
  id = 1
  method = "Runtime.evaluate"
  params = @{
    expression = $Expr
    returnByValue = $true
    awaitPromise = $true
  }
} | ConvertTo-Json -Depth 6 -Compress

$bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
$seg = New-Object System.ArraySegment[byte] (,$bytes)
$ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()

# Receive (may span multiple frames; loop until we get our id=1 result)
$sb = New-Object System.Text.StringBuilder
$buffer = New-Object byte[] 16384
for ($iter = 0; $iter -lt 50; $iter++) {
  $seg2 = New-Object System.ArraySegment[byte] (,$buffer)
  $result = $ws.ReceiveAsync($seg2, $ct)
  $result.Wait()
  $r = $result.Result
  $chunk = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $r.Count)
  [void]$sb.Append($chunk)
  if ($r.EndOfMessage) {
    $txt = $sb.ToString()
    if ($txt -match '"id"\s*:\s*1') { Write-Output $txt; break }
    $sb.Clear() | Out-Null
  }
}
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $ct).Wait()
