# Pester 5 tests for the pure functions in src\core.ps1 (no TV or network needed).

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\core.ps1')

    # Real output from a TCL QM7K (Android TV 14) showing HDMI 1, trimmed.
    $script:TclOnHdmi1 = @'
  mWakefulness=Awake
  mFocusedApp=ActivityRecord{4518449 u0 com.tcl.tv/com.tcl.player.TVActivity t1024}
  inputMap: inputId -> TvInputState
  sessionStateMap: ITvInputSession -> SessionState
    android.os.Binder@b2698ca: com.android.server.tv.TvInputManagerService$SessionState@c04d2bd
      inputId: com.tcl.tvinput/.TvPassThroughService/HW15
  mainSessionToken: android.os.Binder@b2698ca
    TvInputHardwareInfo {id=15, type=9, audio_type=0, audio_addr=null, hdmi_port=1, cable_connection_status=2}
    TvInputHardwareInfo {id=16, type=9, audio_type=0, audio_addr=null, hdmi_port=2, cable_connection_status=2}
'@
}

Describe 'ConvertFrom-AdbConnect' {
    It 'reads "<Text>" as <Expected>' -TestCases @(
        @{ Text = 'connected to 192.168.1.50:5555'; Expected = 'Connected' }
        @{ Text = 'already connected to 192.168.1.50:5555'; Expected = 'Connected' }
        @{ Text = "* daemon not running; starting now at tcp:15037`n* daemon started successfully`nconnected to 10.0.0.5:5555"; Expected = 'Connected' }
        @{ Text = 'failed to authenticate to 192.168.1.50:5555'; Expected = 'Unauthorized' }
        @{ Text = "failed to connect to '192.168.1.9:5555': No connection could be made because the target machine actively refused it. (10061)"; Expected = 'Failed' }
        @{ Text = 'cannot connect to 192.168.1.9:5555: A connection attempt failed (10060)'; Expected = 'Failed' }
        @{ Text = 'timed out'; Expected = 'Failed' }
        @{ Text = ''; Expected = 'Failed' }
    ) {
        ConvertFrom-AdbConnect $Text | Should -Be $Expected
    }
}

Describe 'ConvertTo-AdbRequest' {
    It 'prefixes "<Text>" with its length in 4 hex digits' -TestCases @(
        @{ Text = 'host:version'; Expected = '000Chost:version' }
        @{ Text = 'shell:input keyevent 223'; Expected = '0018shell:input keyevent 223' }
        @{ Text = 'host:connect:192.168.1.50:5555'; Expected = '001Ehost:connect:192.168.1.50:5555' }
    ) {
        ConvertTo-AdbRequest $Text | Should -Be $Expected
    }
}

Describe 'Invoke-AdbServer' {
    It 'reports ServerDown, without throwing, when no adb server is listening' {
        $result = Invoke-AdbServer -Config ([pscustomobject]@{ adbServerPort = 1; tvIp = '192.0.2.1' }) -Request 'host:version' -TimeoutMs 1000
        $result.Ok | Should -BeFalse
        $result.ServerDown | Should -BeTrue
    }
}

Describe 'ConvertFrom-AdbState' {
    It 'reads "<Text>" as <Expected>' -TestCases @(
        @{ Text = 'device'; Expected = 'device' }
        @{ Text = "device`r`n"; Expected = 'device' }
        @{ Text = "error: device unauthorized.`nThis adb server's `$ADB_VENDOR_KEYS is not set`nOtherwise check for a confirmation dialog on your device."; Expected = 'unauthorized' }
        @{ Text = 'error: device offline'; Expected = 'offline' }
        @{ Text = "error: device '192.168.1.9:5555' not found"; Expected = 'missing' }
        @{ Text = ''; Expected = 'missing' }
    ) {
        ConvertFrom-AdbState $Text | Should -Be $Expected
    }
}

Describe 'ConvertFrom-TvView' {
    It 'reads power, app and input from a TCL TV showing HDMI 1' {
        $view = ConvertFrom-TvView $script:TclOnHdmi1
        $view.Power | Should -Be 'On'
        $view.App | Should -Be 'com.tcl.tv/com.tcl.player.TVActivity'
        $view.Input | Should -Be 'com.tcl.tvinput/.TvPassThroughService/HW15'
        $view.HdmiPort | Should -Be '1'
    }
    It 'reads mWakefulness=<State> as <Expected>' -TestCases @(
        @{ State = 'Awake'; Expected = 'On' }
        @{ State = 'Dreaming'; Expected = 'On' }
        @{ State = 'Asleep'; Expected = 'Off' }
        @{ State = 'Dozing'; Expected = 'Off' }
        @{ State = 'Weird'; Expected = 'Unknown' }
    ) {
        (ConvertFrom-TvView "  mWakefulness=$State").Power | Should -Be $Expected
    }
    It 'returns Unknown and empty values for empty output' {
        $view = ConvertFrom-TvView ''
        $view.Power | Should -Be 'Unknown'
        $view.App | Should -BeNullOrEmpty
        $view.Input | Should -BeNullOrEmpty
    }
    It 'picks the main session when there are several' {
        $text = @'
    android.os.Binder@aaa: com.android.server.tv.TvInputManagerService$SessionState@1
      inputId: com.example/.Tuner/HW1
    android.os.Binder@bbb: com.android.server.tv.TvInputManagerService$SessionState@2
      inputId: com.example/.Hdmi/HW3
  mainSessionToken: android.os.Binder@bbb
'@
        (ConvertFrom-TvView $text).Input | Should -Be 'com.example/.Hdmi/HW3'
    }
    It 'reads an app in front, such as a streaming app' {
        (ConvertFrom-TvView '  mFocusedApp=ActivityRecord{1a2b3c u0 com.netflix.ninja/.MainActivity t55}').App | Should -Be 'com.netflix.ninja/.MainActivity'
    }
}

Describe 'Test-ShowingPc' {
    BeforeAll {
        $script:Config = [pscustomobject]@{ pcApp = 'com.tcl.tv/com.tcl.player.TVActivity'; pcInput = 'com.tcl.tvinput/.TvPassThroughService/HW15' }
        function New-View($App, $TvInput, $Power = 'On') { [pscustomobject]@{ Power = $Power; App = $App; Input = $TvInput } }
    }
    It 'is Yes when the TV shows the PC input' {
        Test-ShowingPc (New-View -App 'com.tcl.tv/com.tcl.player.TVActivity' -TvInput 'com.tcl.tvinput/.TvPassThroughService/HW15') $script:Config | Should -Be 'Yes'
    }
    It 'is Yes for another screen of the same TV app on the same input' {
        Test-ShowingPc (New-View -App 'com.tcl.tv/com.tcl.player.Other' -TvInput 'com.tcl.tvinput/.TvPassThroughService/HW15') $script:Config | Should -Be 'Yes'
    }
    It 'is No when another app is in front' {
        Test-ShowingPc (New-View -App 'com.netflix.ninja/.MainActivity' -TvInput '') $script:Config | Should -Be 'No'
    }
    It 'is No when the TV shows another HDMI input' {
        Test-ShowingPc (New-View -App 'com.tcl.tv/com.tcl.player.TVActivity' -TvInput 'com.tcl.tvinput/.TvPassThroughService/HW16') $script:Config | Should -Be 'No'
    }
    It 'is Unknown when the TV does not report what it shows' {
        Test-ShowingPc (New-View -App '' -TvInput '') $script:Config | Should -Be 'Unknown'
    }
    It 'is Unknown when the TV is off' {
        Test-ShowingPc (New-View -App 'com.tcl.tv/com.tcl.player.TVActivity' -TvInput 'com.tcl.tvinput/.TvPassThroughService/HW15' -Power 'Off') $script:Config | Should -Be 'Unknown'
    }
    It 'is Unknown when the PC input was never recorded' {
        Test-ShowingPc (New-View -App 'com.netflix.ninja/.MainActivity' -TvInput '') ([pscustomobject]@{ pcApp = ''; pcInput = '' }) | Should -Be 'Unknown'
    }
}

Describe 'Test-IPv4' {
    It 'accepts <Text>' -TestCases @(
        @{ Text = '192.168.1.50' }, @{ Text = '10.0.0.1' }, @{ Text = '172.16.5.4' }, @{ Text = '1.2.3.4' }
    ) {
        Test-IPv4 $Text | Should -BeTrue
    }
    It 'rejects "<Text>"' -TestCases @(
        @{ Text = '' }, @{ Text = 'tv' }, @{ Text = '192.168.1' }, @{ Text = '192.168.1.1.1' }, @{ Text = '256.1.1.1' },
        @{ Text = '192.168.01.1' }, @{ Text = '127.0.0.1' }, @{ Text = '0.1.2.3' }, @{ Text = '224.0.0.1' }, @{ Text = ' 192.168.1.2' }
    ) {
        Test-IPv4 $Text | Should -BeFalse
    }
}

Describe 'Set-InstallMode' {
    It 'points everything at %LOCALAPPDATA%\ATVCompanion by default (just for me)' {
        . Set-InstallMode
        $InstallDir | Should -Be (Join-Path $env:LOCALAPPDATA 'ATVCompanion')
        $ConfigPath | Should -Be (Join-Path $env:LOCALAPPDATA 'ATVCompanion\config.json')
        $AdbPath | Should -Be (Join-Path $env:LOCALAPPDATA 'ATVCompanion\platform-tools\adb.exe')
        $WatcherPath | Should -Be (Join-Path $env:LOCALAPPDATA 'ATVCompanion\watcher.ps1')
    }
    It 'splits program and settings for the whole PC' {
        . Set-InstallMode -Machine
        $AdbPath | Should -Be (Join-Path $env:ProgramFiles 'ATVCompanion\platform-tools\adb.exe')
        $WatcherPath | Should -Be (Join-Path $env:ProgramFiles 'ATVCompanion\watcher.ps1')
        $ConfigPath | Should -Be (Join-Path $env:ProgramData 'ATVCompanion\config.json')
        $LogPath | Should -Be (Join-Path $env:ProgramData 'ATVCompanion\log.txt')
    }
    It 'only changes the paths of the scope it is dot-sourced into' {
        & { . Set-InstallMode -Machine }
        . Set-InstallMode
        $ConfigPath | Should -Be (Join-Path $env:LOCALAPPDATA 'ATVCompanion\config.json')
    }
}

Describe 'Config files' {
    It 'returns $null when there is no config file' {
        Read-Config -Path (Join-Path $TestDrive 'missing.json') | Should -BeNullOrEmpty
    }
    It 'returns $null for a damaged config file' {
        $path = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $path -Value '{ not json'
        Read-Config -Path $path | Should -BeNullOrEmpty
    }
    It 'saves and reads back settings' {
        $path = Join-Path $TestDrive 'config.json'
        $config = New-Object PSObject -Property $ConfigDefaults
        $config.tvIp = '192.168.1.50'
        $config.followDisplay = $false
        Save-Config $config -Path $path
        $read = Read-Config -Path $path
        $read.tvIp | Should -Be '192.168.1.50'
        $read.followDisplay | Should -BeFalse
        $read.adbServerPort | Should -Be 15037
        Test-Path "$path.tmp" | Should -BeFalse
    }
    It 'fills in settings missing from an older config file' {
        $path = Join-Path $TestDrive 'old.json'
        Set-Content -LiteralPath $path -Value '{ "tvIp": "10.0.0.7" }'
        $read = Read-Config -Path $path
        $read.tvIp | Should -Be '10.0.0.7'
        $read.leaveTvAloneWhenInUse | Should -BeTrue
        $read.adbServerPort | Should -Be 15037
    }
}
