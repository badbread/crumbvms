param([string]$Out)
$ErrorActionPreference = "Stop"
$j = Invoke-RestMethod -Uri "http://127.0.0.1:9223/json" -TimeoutSec 5
$page = $j | Where-Object { $_.type -eq "page" } | Select-Object -First 1
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).Wait()
$msg = '{"id":1,"method":"Page.captureScreenshot","params":{"format":"png"}}'
$bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
$seg = New-Object System.ArraySegment[byte] (,$bytes)
$ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
$sb = New-Object System.Text.StringBuilder
$buffer = New-Object byte[] 65536
for ($i=0; $i -lt 4000; $i++) {
  $seg2 = New-Object System.ArraySegment[byte] (,$buffer)
  $r = $ws.ReceiveAsync($seg2, $ct); $r.Wait()
  [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buffer,0,$r.Result.Count))
  if ($r.Result.EndOfMessage) { if ($sb.ToString() -match '"id"\s*:\s*1') { break } else { $sb.Clear()|Out-Null } }
}
$resp = $sb.ToString() | ConvertFrom-Json
[IO.File]::WriteAllBytes($Out, [Convert]::FromBase64String($resp.result.data))
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $ct).Wait()
"saved $Out"
