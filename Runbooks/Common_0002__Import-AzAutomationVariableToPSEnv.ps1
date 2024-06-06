<#PSScriptInfo
.VERSION 1.3.0
.GUID 05a03d22-11a6-4114-8241-6e02a66d00fc
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
    Version 1.3.0 (2024-06-06)
    - Use Invoke-AzRestMethod
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

try {
    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {

        #region [COMMON] CONNECTIONS ---------------------------------------------------
        # Implicitly connect to Azure Graph API using the Common_0001__Connect-MgGraph.ps1 script.
        # This will ensure the connections are established in the correct order, while still retrieving the necessary environment variables.
        ./Common_0001__Connect-MgGraph.ps1
        #endregion ---------------------------------------------------------------------

        if ([string]::IsNullOrEmpty($env:AZURE_AUTOMATION_AccountId)) {
            Throw 'Missing environment variable $env:AZURE_AUTOMATION_AccountId'
        }
        else {
            $retryCount = 0
            $success = $false
            $AutomationVariables = $null
            $lastError = $null
            $apiVersion = '2023-11-01'

            while (-not $success -and $retryCount -lt 5) {
                try {
                    $params = @{
                        Path = "$($env:AZURE_AUTOMATION_AccountId)/variables?api-version=$apiVersion"
                        Method = 'GET'
                        ErrorAction = 'Stop'
                    }
                    $AutomationVariables = (./Common_0001__Invoke-AzRestMethod.ps1 $params).Content.value
                    $success = $true
                }
                catch {
                    $lastError = $_
                    $retryCount++
                    Start-Sleep -Seconds (5 * $retryCount) # exponential backoff
                }
            }

            if (-not $success) {
                throw "Failed to get automation variables after 5 attempts. Last error: $lastError"
            }
        }

        $AutomationVariables | & {
            process {
                if ($_.Name -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$') {
                    Write-Warning "[COMMON]: - Skipping variable '$($_.Name)' because its name contains invalid characters, starts with a digit, or contains a space."
                    return
                }
                if (($null -ne $script:Variable) -and ($_.Name -notin $script:Variable)) { return }
                if ($_.properties.isEncrypted) {
                    # Get-AutomationVariable is an internal cmdlet that is not available in the Az module.
                    # It is part of the Automation internal module Orchestrator.AssetManagement.Cmdlets.
                    # https://learn.microsoft.com/en-us/azure/automation/shared-resources/modules#internal-cmdlets
                    $_.properties.value = Orchestrator.AssetManagement.Cmdlets\Get-AutomationVariable -Name $_.Name
                }
                $_.properties.value = $_.properties.value.Trim('"')

                if ($_.properties.value -eq 'true' -or $_.properties.value -eq 'false') {
                    Write-Verbose "[COMMON]: - Setting `$env:$($_.Name) as boolean string value"
                    if ($_.properties.value -eq 'true') {
                        [Environment]::SetEnvironmentVariable($_.Name, 'True')
                    }
                    else {
                        [Environment]::SetEnvironmentVariable($_.Name, 'False')
                    }
                }
                elseif ([string]::new($_.properties.value).Length -gt 32767) {
                    Write-Verbose "[COMMON]: - SKIPPING variable '$($_.Name)' because it is too long"
                }
                elseif ([string]::new($_.properties.value) -eq '') {
                    Write-Verbose "[COMMON]: - Setting `$env:$($_.Name) as empty string value"
                    [Environment]::SetEnvironmentVariable($_.Name, "''")
                }
                else {
                    Write-Verbose "[COMMON]: - Setting `$env:$($_.Name) as string value"
                    [Environment]::SetEnvironmentVariable($_.Name, $_.properties.value)
                }
            }
        }
        Write-Verbose "[COMMON]: - Successfully imported automation variables to PowerShell environment variables"
    }
    else {
        Write-Verbose "[COMMON]: - Running in local environment"
        if (Test-Path -Path "$PSScriptRoot/../scripts/AzAutoFWProject/Set-AzAutomationVariableAsPSEnv.ps1") {
            & "$PSScriptRoot/../scripts/AzAutoFWProject/Set-AzAutomationVariableAsPSEnv.ps1" -Variable $Variable -Verbose:$VerbosePreference
        }
        else {
            Write-Warning "[COMMON]: - Set-AzAutomationVariableAsPSEnv.ps1 not found in $PSScriptRoot/../scripts/AzAutoFWProject"
        }
    }
}
catch {
    Throw $_
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
