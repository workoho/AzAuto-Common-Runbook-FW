# Each runbook ends with a cleanup of the variables it created. It must not remove a variable of the caller.
BeforeDiscovery {
    $script:CleanupLines = foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot '../Runbooks') -Filter '*.ps1') {
        $line = Get-Content -Path $file.FullName | Where-Object { $_ -match '^\s*Get-Variable \| Where-Object \{ \$StartupVariables' } | Select-Object -First 1
        if ($line) { @{ Runbook = $file.Name; Line = $line } }
    }
}

Describe 'Variable cleanup at the end of <Runbook>' -ForEach $script:CleanupLines {
    BeforeAll {
        $script:Child = Join-Path $TestDrive 'child.ps1'
        Set-Content -Path $script:Child -Value @(
            '$StartupVariables = (Get-Variable | & { process { $_.Name } })'
            '$createdByRunbook = 1'
            $Line
        )
        # A fresh process of the same PowerShell, because Pester runs a test in its own scopes, which hides the effect.
        $script:Shell = (Get-Process -Id $PID).Path
    }

    # $HOME has the options ReadOnly and AllScope. The faulty cleanup removed it for the whole session.
    It 'keeps $HOME of the caller' {
        & $script:Shell -NoProfile -NonInteractive -Command "& '$script:Child'; [bool] `$HOME" | Should -Be 'True'
    }
}
