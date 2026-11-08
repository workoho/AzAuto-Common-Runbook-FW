# Findings of Test-Compatibility.ps1 that do not apply to Windows PowerShell 5.1, each with its reason.
@{
    Accepted     = @(
        @{
            Script  = 'Common_0001__Invoke-AzRestMethod.ps1'
            Rule    = 'PSUseCompatibleCommands'
            Message = "*'Depth'*'ConvertFrom-Json'*"
            Reason  = 'The call runs only on PowerShell 7, in the branch after the PSEdition check.'
        }
    )
    ExcludeFiles = @()
}
