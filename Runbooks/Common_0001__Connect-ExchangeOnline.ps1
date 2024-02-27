<#PSScriptInfo
.VERSION 1.0.0
.GUID 2d55eb0b-3e2e-425a-a7de-5d12cbe5a149
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
    Connects to Exchange Online and performs necessary actions.

.DESCRIPTION
    This script connects to Exchange Online and performs necessary actions based on the provided parameters. It checks if a connection already exists and if it is active. If the connection is not active or does not exist, it establishes a new connection.

.PARAMETER Organization
    Specifies the organization to connect to in Exchange Online.

.PARAMETER CommandName
    Specifies the Exchange Online commands to load. If not provided, all commands will be loaded.
    This parameter is useful when you want to load only specific commands to reduce memory consumption.

.EXAMPLE
    PS> Common_0001__Connect-ExchangeOnline.ps1 -Organization "contoso.com" -CommandName "Get-Mailbox"

    Connects to the Exchange Online organization "contoso.com" and loads only the "Get-Mailbox" command.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(mandatory = $true)]
    [String]$Organization,

    [Array]$CommandName
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

#region [COMMON] ENVIRONMENT ---------------------------------------------------
./Common_0000__Import-Module.ps1 -Modules @(
    @{ Name = 'ExchangeOnlineManagement'; MinimumVersion = '3.4'; MaximumVersion = '3.65535' }
) 1> $null
#endregion ---------------------------------------------------------------------

$params = @{
    Organization = $Organization
    ShowBanner   = $false
    ShowProgress = $false
    ErrorAction  = 'Stop'
}

$Connection = $null

try {
    $Connection = Get-ConnectionInformation -ErrorAction Stop
}
catch {
    # Ignore
}

if (
    ($Connection) -and
    (
        (($Connection | Where-Object Organization -eq $params.Organization).State -ne 'Connected') -or
        (($Connection | Where-Object Organization -eq $params.Organization).tokenStatus -ne 'Active')
    )
) {
    $Connection | Where-Object Organization -eq $params.Organization | ForEach-Object {
        try {
            Disconnect-ExchangeOnline `
                -ConnectionId $_.ConnectionId `
                -Confirm:$false `
                -InformationAction SilentlyContinue `
                -ErrorAction Stop 1> $null
        }
        catch {
            Write-Output '' 1> $null
        }
    }
    $Connection = $null
}

if (-Not ($Connection)) {
    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        $params.ManagedIdentity = $true
        $params.SkipLoadingCmdletHelp = $true
        $params.SkipLoadingFormatData = $true
    }

    if (
        $env:GITHUB_CODESPACE_TOKEN -or
        $env:AWS_CLOUD9_USER
    ) {
        $params.Device = $true
    }

    if ($CommandName) {
        $params.CommandName = $CommandName
    }
    elseif ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        Write-Warning '[COMMON]: - Loading all Exchange Online commands. For improved memory consumption, consider adding -CommandName parameter with only required commands to be loaded.'
    }

    try {
        $OrigVerbosePreference = $global:VerbosePreference
        $global:VerbosePreference = 'SilentlyContinue'
        Write-Information 'Connecting to Exchange Online ...' -InformationAction Continue
        if ($params.Device) {
            Connect-ExchangeOnline @params
        }
        else {
            Connect-ExchangeOnline @params 1> $null
        }
        $global:VerbosePreference = $OrigVerbosePreference
    }
    catch {
        Write-Error $_.Exception.Message -ErrorAction Stop
        exit
    }
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
