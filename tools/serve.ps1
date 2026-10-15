<#
  Serves dist\ at http://localhost:8000/ to test "irm <url> | iex" before publishing.
  Files are sent as application/octet-stream, like GitHub release downloads.
      .\tools\serve.ps1
      irm http://localhost:8000/install.ps1 | iex      (in another, normal PowerShell window)
#>
param([int]$Port = 8000, [string]$Root = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'))
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $Root at http://localhost:$Port/  (close this window to stop)"
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $file = Join-Path $Root ([System.IO.Path]::GetFileName($context.Request.Url.AbsolutePath))
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $context.Response.ContentType = 'application/octet-stream'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $context.Response.StatusCode = 404
        }
        $context.Response.Close()
        Write-Host "$(Get-Date -Format HH:mm:ss) $($context.Request.Url.AbsolutePath) -> $($context.Response.StatusCode)"
    }
} finally {
    $listener.Stop()
}
