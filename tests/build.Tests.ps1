# Pester 5 tests for build.ps1: the published scripts must be complete and self-contained.

BeforeAll {
    $script:Out = Join-Path $TestDrive 'dist'
    & (Join-Path $PSScriptRoot '..\build.ps1') -OutDir $script:Out 6>$null
}

Describe 'Published script <Name>' -ForEach @(
    @{ Name = 'install.ps1' }, @{ Name = 'change-tv.ps1' }, @{ Name = 'uninstall.ps1' }
) {
    BeforeAll {
        $script:Text = [System.IO.File]::ReadAllText((Join-Path $script:Out $Name))
    }
    It 'parses without errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:Text, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
    It 'has no build markers or references to other source files left' {
        $script:Text | Should -Not -Match '#BUILD-'
        $script:Text | Should -Not -Match 'PSScriptRoot'
    }
    It 'is plain ASCII without a byte order mark' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Out $Name))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'contains the shared code' {
        $script:Text | Should -Match 'function Invoke-Adb'
        $script:Text | Should -Match 'function Uninstall-UserInstall'
        $script:Text | Should -Match 'function Uninstall-MachineInstall'
    }
}

Describe 'The service program embedded in install.ps1' {
    It 'compiles with the C# compiler that ships with Windows' {
        $installer = [System.IO.File]::ReadAllText((Join-Path $script:Out 'install.ps1'))
        $match = [regex]::Match($installer, "(?s)\`$ServiceSource = @'\r?\n(.*?)\r?\n'@")
        $match.Success | Should -BeTrue
        $source = Join-Path $TestDrive 'ATVCompanionService.cs'
        $exe = Join-Path $TestDrive 'ATVCompanionService.exe'
        Set-Content -LiteralPath $source -Value $match.Groups[1].Value
        $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        $output = & $csc /nologo /target:exe /warnaserror+ "/out:$exe" $source 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join ' ')
        Test-Path $exe | Should -BeTrue
    }
}

Describe 'The watcher embedded in install.ps1' {
    It 'is complete and parses on its own' {
        $installer = [System.IO.File]::ReadAllText((Join-Path $script:Out 'install.ps1'))
        $match = [regex]::Match($installer, "(?s)\`$WatcherSource = @'\r?\n(.*?)\r?\n'@")
        $match.Success | Should -BeTrue
        $watcher = $match.Groups[1].Value
        $watcher | Should -Match 'function Invoke-TvWake'
        $watcher | Should -Match 'function Invoke-Adb'
        $watcher | Should -Not -Match 'PSScriptRoot'
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($watcher, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
}
