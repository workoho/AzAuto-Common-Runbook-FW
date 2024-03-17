<#PSScriptInfo
.VERSION 1.0.0
.GUID 3e9f0b5b-be2f-4c10-bdfa-25d8b4550e67
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
    Version 1.0.0 (2024-02-25)
    - Initial release.
#>

<#
.SYNOPSIS
    Get active directory roles of current user

.DESCRIPTION
    This script retrieves the active directory roles assigned to the current user using the Microsoft Graph API.

.EXAMPLE
    PS> Common_0002__Get-MgDirectoryRoleActiveAssignment.ps1

    Retrieves the active directory roles assigned to the current user.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param()

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

# Avoid using Microsoft.Graph.Identity.Governance module as it requires too much memory in Azure Automation
$params = @{
    OutputType  = 'PSObject'
    Method      = 'GET'
    Uri         = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=PrincipalId eq %27$($env:MG_PRINCIPAL_ID)%27&`$expand=roleDefinition"
    ErrorAction = 'Stop'
    Verbose     = $false
}

try {
    $return = (Invoke-MgGraphRequest @params).value
}
catch {
    Throw $_
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
