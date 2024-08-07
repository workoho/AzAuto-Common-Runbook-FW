<#PSScriptInfo
.VERSION 1.3.1
.GUID 05273e10-2a70-42aa-82d3-7881324beead
.AUTHOR Julian Pawlowski
.COMPANYNAME Workoho GmbH
.COPYRIGHT © 2024 Workoho GmbH
.TAGS
.LICENSEURI https://github.com/workoho/AzAuto-Common-Runbook-FW/LICENSE.txt
.PROJECTURI https://github.com/workoho/AzAuto-Common-Runbook-FW
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
    Version 1.3.1 (2024-07-05)
    - Only implicitly connect to Azure when running in PowerShell Desktop Edition to avoid conflicts with Microsoft Graph modules in PowerShell 5.1
#>

<#
.SYNOPSIS
    Connects to Microsoft Graph and performs authorization checks.

.DESCRIPTION
    This script connects to Microsoft Graph using the specified scopes and performs authorization checks to ensure that the required scopes are available.

    The script also creates the following environment variables so that other scripts can use them:
    - $env:MG_PRINCIPAL_TYPE: The type of the principal ('Delegated' or 'Application').
    - $env:MG_PRINCIPAL_ID: The ID of the principal.
    - $env:MG_PRINCIPAL_DISPLAYNAME: The display name of the principal.

    This is in particular useful during local development when an interactive account is used, while in Azure Automation, a service principal is used.
    By using the environment variables, other scripts can easily determine the type of the principal and use the principal ID and display name without having to call Microsoft Graph again.

.PARAMETER Scopes
    An array of Microsoft Graph scopes required for the script.

.PARAMETER TenantId
    The ID of the tenant to connect to.

.EXAMPLE
    PS> Common_0001__Connect-MgGraph.ps1 -Scopes @('User.Read', 'Mail.Read') -TenantId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

    Connects to Microsoft Graph using the specified scopes and the specified tenant ID.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Array]$Scopes,
    [string]$TenantId
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
if (-Not $Global:hasRunBefore) { $Global:hasRunBefore = @{} }
if (-Not $Global:hasRunBefore.ContainsKey((Get-Item $PSCommandPath).Name)) {
    Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"

    # It is important to run Connect-AzAccount first to avoid conflicts with the Microsoft Graph modules in PowerShell 5.1
    # See https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/2148#issuecomment-1637535115
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Write-Verbose 'Implicitly connecting to Azure first to avoid conflicts with Microsoft Graph modules in PowerShell 5.1 ...'
        ./Common_0001__Connect-AzAccount.ps1
    }
}
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

./Common_0000__Import-Module.ps1 -Modules @(
    @{ Name = 'Microsoft.Graph.Authentication'; MinimumVersion = '2.0'; MaximumVersion = '2.65535' }
) 1> $null

function Get-MgMissingScope ([Array]$Scopes) {
    $MissingScopes = [System.Collections.ArrayList]::new()

    foreach ($Scope in $Scopes) {
        if ($WhatIfPreference -and ($Scope -like '*Write*')) {
            Write-Verbose "[COMMON]: - What If: Removed $Scope from required Microsoft Graph scopes"
            [void] $script:Scopes.Remove($Scope)
        }
        elseif ($Scope -notin @((Get-MgContext).Scopes)) {
            [void] $MissingScopes.Add($Scope)
        }
    }
    return $MissingScopes
}

$params = @{
    NoWelcome    = $true
    ContextScope = 'Process'
    ErrorAction  = 'Stop'
}
if ($TenantId) {
    if (
        $TenantId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $TenantId -eq '00000000-0000-0000-0000-000000000000'
    ) {
        Throw '[COMMON]: - Invalid tenant ID. The tenant ID must be a valid GUID.'
    }
    $params.TenantId = $TenantId
}

if (
    -Not (Get-MgContext) -or
    (
        $null -ne $params.TenantId -and
        $params.TenantId -ne (Get-MgContext).TenantId
    )
) {
    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        Write-Verbose '[COMMON]: - Using system-assigned Managed Service Identity'
        $params.Identity = $true
    }
    elseif (
        $env:GITHUB_CODESPACE_TOKEN -or
        $env:AWS_CLOUD9_USER
    ) {
        Write-Verbose '[COMMON]: - Using device code authentication'
        $params.UseDeviceCode = $true
        if ($Scopes) { $params.Scopes = $Scopes }
    }
    else {
        Write-Verbose '[COMMON]: - Using interactive sign in'
        if ($Scopes) { $params.Scopes = $Scopes }
    }

    try {
        if ($params.UseDeviceCode) {
            Write-Host "Please select the account you want to login with.`n" -ForegroundColor Yellow
            Write-Host -NoNewline "`e[1;37;44m[Login to Graph]`e[0m "
            Connect-MgGraph @params | ForEach-Object {
                if ($_ -is [string] -and $_ -cmatch ' ([A-Z0-9]{9}) ') {
                    $_ -replace $Matches[1], "`e[4m$($Matches[1])`e[24m"
                }
                else {
                    $_
                }
            } | Out-Host
        }
        else {
            Write-Information 'Connecting to Microsoft Graph ...' -InformationAction Continue
            Connect-MgGraph @params 1> $null
        }
    }
    catch {
        Write-Error "Microsoft Graph connection error: $($_.Exception.Message)" -ErrorAction Stop
        exit
    }
}

$MissingScopes = Get-MgMissingScope -Scopes $Scopes

if ($MissingScopes) {
    if (
        ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) -or
        ((Get-MgContext).AuthType -ne 'Delegated')
    ) {
        Write-Error "Missing Microsoft Graph authorization scopes:`n`n$($MissingScopes -join "`n")" -ErrorAction Stop
        exit
    }

    if ($Scopes) { $params.Scopes = $Scopes }
    try {
        Write-Information 'Missing scopes, re-connecting to Microsoft Graph ...' -InformationAction Continue
        if ($params.UseDeviceCode) {
            Write-Host "Please select the account you want to login with.`n" -ForegroundColor Yellow
            Write-Host -NoNewline "`e[1;37;44m[Login to Graph]`e[0m "
            Connect-MgGraph @params | ForEach-Object {
                if ($_ -is [string] -and $_ -cmatch ' ([A-Z0-9]{9}) ') {
                    $_ -replace $Matches[1], "`e[4m$($Matches[1])`e[24m"
                }
                else {
                    $_
                }
            } | Out-Host
        }
        else {
            Connect-MgGraph @params 1> $null
        }
    }
    catch {
        Write-Error $_.Exception.Message -ErrorAction Stop
        exit
    }

    if (
        (-Not (Get-MgContext)) -or
        ((Get-MgMissingScope -Scopes $Scopes).Count -gt 0)
    ) {
        Write-Error "Missing Microsoft Graph authorization scopes:`n`n$($MissingScopes -join "`n")" -ErrorAction Stop
        exit
    }
}

if (
    [string]::IsNullOrEmpty($env:MG_PRINCIPAL_ID) -or
    [string]::IsNullOrEmpty($env:MG_PRINCIPAL_DISPLAYNAME)
) {
    try {
        $Context = Get-MgContext -ErrorAction Stop -Verbose:$false

        if ($Context.AuthType -eq 'Delegated') {
            [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_TYPE', 'Delegated')
            Write-Verbose "[COMMON]: - Getting user details for $($Context.Account) ..."
            $Principal = Invoke-MgGraphRequest -Uri "/v1.0/users/$($Context.Account)?`$select=id,displayName" -ErrorAction Stop -Verbose:$false
        }
        else {
            [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_TYPE', 'Application')
            Write-Verbose "[COMMON]: - Getting service principal details for $($Context.ClientId) ..."
            $Principal = (Invoke-MgGraphRequest -Uri "/v1.0/servicePrincipals?`$select=id,displayName&`$filter=appId eq '$($Context.ClientId)'" -ErrorAction Stop -Verbose:$false).Value[0]
        }

        Write-Verbose "[COMMON]: - Setting environment MG_PRINCIPAL_ID to '$($Principal.Id)' and MG_PRINCIPAL_DISPLAYNAME to '$($Principal.DisplayName)' ..."
        [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_ID', $Principal.Id)
        [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_DISPLAYNAME', $Principal.DisplayName)

        # Depending on the Connect-AzAccount above, we may now read out all
        # the details about the Automation Account and its managed identity
        if (
            -Not $Global:hasRunBefore.ContainsKey((Get-Item $PSCommandPath).Name) -and
            $PSVersionTable.PSEdition -eq 'Desktop'
        ) {
            ./Common_0001__Connect-AzAccount.ps1 -SetEnvVarsAfterMgConnect $true
        }
    }
    catch {
        Write-Error $_.Exception.Message -ErrorAction Stop
        exit
    }
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
if (-Not $Global:hasRunBefore.ContainsKey((Get-Item $PSCommandPath).Name)) {
    $Global:hasRunBefore[(Get-Item $PSCommandPath).Name] = $true
    Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
}
