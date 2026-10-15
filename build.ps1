<#
  Builds the published scripts (dist\install.ps1, change-tv.ps1, uninstall.ps1) from src\.

  Each published script is self-contained, so it works with "irm <url> | iex":
    #BUILD-INLINE <file>          the block up to #BUILD-END is replaced by <file>'s contents
    #BUILD-EMBED <file> $<name>   the block is replaced by: $<name> = @' <built file> '@
  Published files must be plain ASCII, so they read the same however they are downloaded.
#>
param([string]$OutDir = (Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'

function Expand-Source {
    param([string]$Name)
    $lines = New-Object System.Collections.Generic.List[string]
    $skipping = $false
    foreach ($line in (Get-Content -LiteralPath (Join-Path $src $Name))) {
        if ($line -match '^#BUILD-INLINE (\S+)$') {
            $lines.Add("# ===== begin $($Matches[1]) =====")
            $lines.AddRange([string[]](Expand-Source $Matches[1]))
            $lines.Add("# ===== end $($Matches[1]) =====")
            $skipping = $true
        } elseif ($line -match '^#BUILD-EMBED (\S+) \$(\w+)$') {
            $variable = $Matches[2]
            $body = [string[]](Expand-Source $Matches[1])
            if ($body -match "^'@") { throw "$($Matches[1]) has a line starting with '@ and can't be embedded." }
            $lines.Add("`$$variable = @'")
            $lines.AddRange($body)
            $lines.Add("'@")
            $skipping = $true
        } elseif ($line -eq '#BUILD-END') {
            $skipping = $false
        } elseif (-not $skipping) {
            $lines.Add($line)
        }
    }
    return , $lines.ToArray()
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# watcher.ps1 is built too, for linting and reading; it is published inside install.ps1, not on its own.
foreach ($name in 'install.ps1', 'change-tv.ps1', 'uninstall.ps1', 'watcher.ps1') {
    $text = (Expand-Source $name) -join "`r`n"
    if ($text -match '[^\x09\x0A\x0D\x20-\x7E]') { throw "$name contains non-ASCII characters." }
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
    if ($errors) { throw "$name does not parse: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))" }
    [System.IO.File]::WriteAllText((Join-Path $OutDir $name), $text + "`r`n", $utf8NoBom)
    Write-Host "Built $(Join-Path $OutDir $name)"
}
