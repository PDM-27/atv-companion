@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # These are interactive console scripts: Write-Host is how they talk to the user, and
        # nothing may leak into the pipeline when they run as "irm <url> | iex".
        'PSAvoidUsingWriteHost',
        # Interactive scripts, not reusable cmdlets: -WhatIf / -Confirm would add nothing.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
