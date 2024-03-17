<#PSScriptInfo
.VERSION 1.0.0
.GUID 4c450bb0-4cb7-45f8-9b1d-3d7a0bf6c489
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
    This script is used to perform general setup tasks for an Azure Automation account.

.DESCRIPTION
    The Invoke-Setup.ps1 script is responsible for setting up an Azure Automation account by executing various sub-scripts.
    It supports parameters for updating variables, runtime environments, and runbooks.

    Usually, this script is called without parameters to execute all sub-scripts with their default parameters.
    However, it can also be called with specific parameters to update only certain parts of the Azure Automation account.
    Alternatively, you may call the sub-scripts directly with sometimes more specific parameters.

.PARAMETER VariableName
    Specifies the name of the variable to update.

.PARAMETER UpdateVariableValue
    Indicates whether to update the value of the variable.

.PARAMETER RuntimeEnvironmentName
    Specifies the name of the runtime environment.

.PARAMETER RuntimeEnvironmentPackage
    Specifies the package for the runtime environment.

.PARAMETER RunbookName
    Specifies the name of the runbook.

.PARAMETER UpdateAndPublishRunbook
    Indicates whether to update and publish the runbook.

.PARAMETER PublishDraftRunbook
    Indicates whether to publish the draft version of the runbook.

.PARAMETER DiscardDraftRunbook
    Indicates whether to discard the draft version of the runbook.

.PARAMETER AdministrativeUnit
    Specifies the name or ID of the administrative unit in Microsoft Entra.

.PARAMETER Group
    Specifies the name or ID of the group in Microsoft Entra.

.EXAMPLE
    Invoke-Setup.ps1

    This example executes all sub-scripts with their default parameters.

.EXAMPLE
    Invoke-Setup.ps1 -VariableName "MyVariable" -UpdateVariableValue

    This example executes all sub-scripts with their default parameters,
    except that it only updates the value of the automation variable "MyVariable".
#>

#Requires -Module @{ ModuleName='Az.Accounts'; ModuleVersion='2.16.0' }
#Requires -Module @{ ModuleName='Az.Resources'; ModuleVersion='6.16.0' }
#Requires -Module @{ ModuleName='Az.Automation'; ModuleVersion='1.10.0' }
#Requires -Module @{ ModuleName='Microsoft.Graph.Authentication'; ModuleVersion='2.15.0' }
#Requires -Module @{ ModuleName='Microsoft.Graph.Users'; ModuleVersion='2.15.0' }
#Requires -Module @{ ModuleName='Microsoft.Graph.Groups'; ModuleVersion='2.15.0' }
#Requires -Module @{ ModuleName='Microsoft.Graph.Identity.Governance'; ModuleVersion='2.15.0' }
#Requires -Module @{ ModuleName='Microsoft.Graph.Beta.Identity.DirectoryManagement'; ModuleVersion='2.15.0' }

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'Medium'
)]
Param (
    [array]$VariableName,
    [switch]$UpdateVariableValue,
    [array]$RuntimeEnvironmentName,
    [array]$RuntimeEnvironmentPackage,
    [array]$RunbookName,
    [switch]$UpdateAndPublishRunbook,
    [switch]$PublishDraftRunbook,
    [switch]$DiscardDraftRunbook,
    [array]$AdministrativeUnit,
    [array]$Group
)

if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    Throw 'This script must be run interactively by a privileged administrator account.'
}
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

Write-Host "`n==========================================`n| Azure Automation Account General Setup |`n==========================================" -ForegroundColor Cyan

try {
    Push-Location
    Set-Location $PSScriptRoot

    if ($commonBoundParameters) {
        .\Set-AzAutomationAccount.ps1 @commonBoundParameters
        .\Set-AzAutomationRuntimeEnvironment.ps1 -RuntimeEnvironmentName $RuntimeEnvironmentName -RuntimeEnvironmentPackage $RuntimeEnvironmentPackage @commonBoundParameters
        .\Set-AzAutomationRunbook.ps1 -RunbookName $RunbookName -UpdateAndPublishRunbook:$UpdateAndPublishRunbook -PublishDraftRunbook:$PublishDraftRunbook -DiscardDraftRunbook:$DiscardDraftRunbook @commonBoundParameters
        .\Set-EntraAdministrativeUnit.ps1 -AdministrativeUnit $AdministrativeUnit @commonBoundParameters
        .\Set-EntraGroup.ps1 -Group $Group @commonBoundParameters
        .\Set-AzAutomationManagedIdentity.ps1 @commonBoundParameters
        .\Set-AzAutomationVariable.ps1 -VariableName $VariableName -UpdateVariableValue:$UpdateVariableValue @commonBoundParameters
    }
    else {
        .\Set-AzAutomationAccount.ps1
        .\Set-AzAutomationRuntimeEnvironment.ps1 -RuntimeEnvironmentName $RuntimeEnvironmentName -RuntimeEnvironmentPackage $RuntimeEnvironmentPackage
        .\Set-AzAutomationRunbook.ps1 -RunbookName $RunbookName -UpdateAndPublishRunbook:$UpdateAndPublishRunbook -PublishDraftRunbook:$PublishDraftRunbook -DiscardDraftRunbook:$DiscardDraftRunbook
        .\Set-EntraAdministrativeUnit.ps1 -AdministrativeUnit $AdministrativeUnit
        .\Set-EntraGroup.ps1 -Group $Group
        .\Set-AzAutomationManagedIdentity.ps1
        .\Set-AzAutomationVariable.ps1 -VariableName $VariableName -UpdateVariableValue:$UpdateVariableValue
    }
}
catch {
    Write-Error "$_" -ErrorAction Stop
    exit
}
finally {
    Pop-Location
}

Write-Host "`nThe setup of the Azure Automation account has been completed successfully.`n" -ForegroundColor Green

Write-Verbose "---END of $((Get-Item $PSCommandPath).Name)---"
