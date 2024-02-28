<#PSScriptInfo
.VERSION 1.0.0
.GUID 05a03d22-11a6-4114-8241-6e02a66d00fc
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
    Imports Azure Automation variables to PowerShell environment variables.

.DESCRIPTION
    This script is used to import Azure Automation variables to PowerShell environment variables.
    It connects to the Azure Automation account, retrieves the variables, and sets them as environment variables in the current PowerShell session.

    Note that only variables of type String are imported, variables of other types are skipped.
    This is because Azure Automation variables can be of multiple types, and only String values can be set for environment variables.

.PARAMETER Variable
    Specifies an array of variable names to import. If provided, only the specified variables will be imported. If not provided, all variables will be imported.

.EXAMPLE
    PS> Import-AzAutomationVariableToPSEnv -Variable "Variable1", "Variable2"

    Imports only the variables "Variable1" and "Variable2" from Azure Automation to PowerShell environment variables.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Array]$Variable
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {

    #region [COMMON] CONNECTIONS ---------------------------------------------------
    ./Common_0001__Connect-AzAccount.ps1
    #endregion ---------------------------------------------------------------------

    try {
        if ([string]::IsNullOrEmpty($env:AZURE_AUTOMATION_ResourceGroupName)) {
            Throw 'Missing environment variable $env:AZURE_AUTOMATION_ResourceGroupName'
        }
        elseif ([string]::IsNullOrEmpty($env:AZURE_AUTOMATION_AccountName)) {
            Throw 'Missing environment variable $env:AZURE_AUTOMATION_AccountName'
        }
        else {
            $AutomationVariables = Get-AzAutomationVariable -ResourceGroupName $env:AZURE_AUTOMATION_ResourceGroupName -AutomationAccountName $env:AZURE_AUTOMATION_AccountName -Verbose:$false
        }
    }
    catch {
        Throw $_
    }

    $AutomationVariables | & {
        process {
            if (($null -ne $script:Variable) -and ($_.Name -notin $script:Variable)) { return }
            if (
                $_.Value.GetType().Name -ne 'String' -and
                $_.Value.GetType().Name -ne 'Boolean'
            ) {
                Write-Verbose "[COMMON]: - SKIPPING $($_.Name) because it is not a String or Boolean but '$($_.Value.GetType().Name)'"
                return
            }
            elseif ([string]::IsNullOrEmpty($_.Value)) {
                Write-Verbose "[COMMON]: - SKIPPING $($_.Name) because it has NullOrEmpty value"
                return
            }
            Write-Verbose "[COMMON]: - Setting `$env:$($_.Name)"
            [Environment]::SetEnvironmentVariable($_.Name, [string]$_.Value)
        }
    }
}
else {
    Write-Verbose '[COMMON]: - Not running in Azure Automation. Script environment variables must be set manually before local run.'
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
