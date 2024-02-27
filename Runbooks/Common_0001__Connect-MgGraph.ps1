<#PSScriptInfo
.VERSION 1.0.0
.GUID 05273e10-2a70-42aa-82d3-7881324beead
.AUTHOR Julian Pawlowski
.COMPANYNAME Workoho GmbH
.COPYRIGHT © 2024 Workoho GmbH
.TAGS
.LICENSEURI https://github.com/Workoho/AzAuto-Common-Runbook-FW/LICENSE.txt
.PROJECTURI https://github.com/Workoho/AzAuto-Common-Runbook-FW
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
    Version 1.0.0 (2024-02-25)
    - Initial release.
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
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

./Common_0000__Import-Module.ps1 -Modules @(
    @{ Name = 'Microsoft.Graph.Authentication'; MinimumVersion = '2.0'; MaximumVersion = '2.65535' }
) 1> $null

function Get-MgMissingScope ([Array]$Scopes) {
    $MissingScopes = [System.Collections.ArrayList]::new()

    foreach ($Scope in $Scopes) {
        if ($WhatIfPreference -and ($Scope -like '*Write*')) {
            Write-Verbose "[COMMON]: - What If: Removed $Scope from required Microsoft Graph scopes"
            $null = $script:Scopes.Remove($Scope)
        }
        elseif ($Scope -notin @((Get-MgContext).Scopes)) {
            $null = $MissingScopes.Add($Scope)
        }
    }
    return $MissingScopes
}

$params = @{
    NoWelcome    = $true
    ContextScope = 'Process'
    ErrorAction  = 'Stop'
}
if ($TenantId) { $params.TenantId = $TenantId }
if (
    -Not (Get-MgContext) -or
    $params.TenantId -ne (Get-MgContext).TenantId
) {
    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        Write-Verbose '[COMMON]: - Using system-assigned Managed Service Identity'
        $params.Identity = $true
    }
    elseif ($Scopes) {
        Write-Verbose '[COMMON]: - Using interactive sign in'
        $params.Scopes = $Scopes
    }

    if (
        $env:GITHUB_CODESPACE_TOKEN -or
        $env:AWS_CLOUD9_USER
    ) {
        $params.UseDeviceAuthentication = $true
    }

    try {
        Write-Information 'Connecting to Microsoft Graph ...' -InformationAction Continue
        if ($params.UseDeviceAuthentication) {
            Connect-MgGraph @params
        }
        else {
            Connect-MgGraph @params 1> $null
        }
    }
    catch {
        Write-Error $_.Exception.Message -ErrorAction Stop
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
        if ($params.UseDeviceAuthentication) {
            Connect-MgGraph @params
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

try {
    $Principal = $null

    if ((Get-Module).Name -match 'Microsoft.Graph.Beta') {
        if ((Get-MgContext).AuthType -eq 'Delegated') {
            ./Common_0000__Import-Module.ps1 -Modules @(
                @{ Name = 'Microsoft.Graph.Beta.Users'; MinimumVersion = '2.0'; MaximumVersion = '2.65535' }
            ) 1> $null

            [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_TYPE', 'Delegated')
            $Principal = Get-MgBetaUser -UserId (Get-MgContext).Account -ErrorAction Stop -Verbose:$false
        }
        else {
            ./Common_0000__Import-Module.ps1 -Modules @(
                @{ Name = 'Microsoft.Graph.Beta.Applications'; MinimumVersion = '2.0'; MaximumVersion = '2.65535' }
            ) 1> $null

            [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_TYPE', 'Application')
            $Principal = Get-MgBetaServicePrincipalByAppId -AppId (Get-MgContext).ClientId -ErrorAction Stop -Verbose:$false
        }
    }
    else {
        if ((Get-MgContext).AuthType -eq 'Delegated') {
            ./Common_0000__Import-Module.ps1 -Modules @(
                @{ Name = 'Microsoft.Graph.Users'; MinimumVersion = '2.0'; MaximumVersion = '2.65535' }
            ) 1> $null

            [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_TYPE', 'Delegated')
            $Principal = Get-MgUser -UserId (Get-MgContext).Account -ErrorAction Stop -Verbose:$false
        }
        else {
            ./Common_0000__Import-Module.ps1 -Modules @(
                @{ Name = 'Microsoft.Graph.Applications'; MinimumVersion = '2.0'; MaximumVersion = '2.65535' }
            ) 1> $null

            [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_TYPE', 'Application')
            $Principal = Get-MgServicePrincipalByAppId -AppId (Get-MgContext).ClientId -ErrorAction Stop -Verbose:$false
        }
    }

    [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_ID', $Principal.Id)
    [Environment]::SetEnvironmentVariable('MG_PRINCIPAL_DISPLAYNAME', $Principal.DisplayName)
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Stop
    exit
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
