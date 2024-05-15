<#PSScriptInfo
.VERSION 1.2.1
.GUID 1dc765c0-4922-4142-a945-13206df25f13
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
    Version 1.2.1 (2024-05-15)
    - Require version 2.8 of Az.Accounts module. This is currently required as Az 11.2.0 does not work correctly in PowerShell 5.1 in Azure Automation.
#>

<#
.SYNOPSIS
    Connects to Azure using either a Managed Service Identity or an interactive session.

.DESCRIPTION
    This runbook connects to Azure using either a Managed Service Identity or an interactive session, depending on the execution environment.

    The script also retrieves the following information about the current Azure Automation Account and sets them as environment variables:
    - AZURE_AUTOMATION_SubscriptionId
    - AZURE_AUTOMATION_ResourceGroupName
    - AZURE_AUTOMATION_AccountName
    - AZURE_AUTOMATION_IDENTITY_PrincipalId
    - AZURE_AUTOMATION_IDENTITY_TenantId
    - AZURE_AUTOMATION_IDENTITY_Type
    - AZURE_AUTOMATION_RUNBOOK_Name
    - AZURE_AUTOMATION_RUNBOOK_CreationTime
    - AZURE_AUTOMATION_RUNBOOK_LastModifiedTime
    - AZURE_AUTOMATION_RUNBOOK_JOB_CreationTime
    - AZURE_AUTOMATION_RUNBOOK_JOB_StartTime

    This information can be used by other runbooks afterwards to retrieve details about the current runbook and job.

.PARAMETER Tenant
    Specifies the Azure AD tenant ID to use for authentication. If not provided, the default tenant will be used.

.PARAMETER Subscription
    Specifies the Azure subscription ID to use. If not provided, the default subscription will be used.

.PARAMETER Permissions
    Specifies the permissions to check for the current Azure context. The permissions are specified as a hashtable with the Azure scope as the key and the Azure role as the value. The scope can be any valid Azure scope, such as a subscription, resource group, or resource. The role can be either the name or the ID of the Azure role.

.EXAMPLE
    PS> Common_0001__Connect-AzAccount.ps1 -Tenant 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -Subscription 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    Connects to Azure using the specified tenant and subscription.

.EXAMPLE
    PS> Common_0001__Connect-AzAccount.ps1 -Permissions @{'/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyResourceGroup' = 'Contributor'}

    Connects to Azure using the default tenant and subscription and checks if the current context has the specified permissions.

.EXAMPLE
    PS> Common_0001__Connect-AzAccount.ps1
    Connects to Azure using the default tenant and subscription.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [string]$Tenant,
    [string]$Subscription,
    [object]$Permissions
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

#region [COMMON] ENVIRONMENT ---------------------------------------------------
$WarningPreference = 'SilentlyContinue'
if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    ./Common_0000__Import-Module.ps1 -Modules @(
        @{ Name = 'Az.Accounts'; MinimumVersion = '2.8.0'; MaximumVersion = '2.9.65535' } # This is currently required as Az 11.2.0 does not work correctly in PowerShell 5.1 in Azure Automation.
    ) 1> $null
} else {
    ./Common_0000__Import-Module.ps1 -Modules @(
        @{ Name = 'Az.Accounts'; MinimumVersion = '2.8.0'; MaximumVersion = '2.65535' }
    ) 1> $null
}
$WarningPreference = 'Continue'
#endregion ---------------------------------------------------------------------

if (-Not (Get-AzContext)) {
    $Context = $null
    $params = @{
        Scope       = 'Process'
        ErrorAction = 'Stop'
    }

    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        Write-Verbose '[COMMON]: - Using system-assigned Managed Service Identity'
        $params.Identity = $true
    }
    else {
        Write-Verbose '[COMMON]: - Using interactive sign in'
    }

    if (
        $env:GITHUB_CODESPACE_TOKEN -or
        $env:AWS_CLOUD9_USER
    ) {
        $params.UseDeviceAuthentication = $true
    }

    try {
        Write-Information 'Connecting to Microsoft Azure ...' -InformationAction Continue
        if ($Tenant) { $params.Tenant = $Tenant }
        if ($Subscription) { $params.Subscription = $Subscription }
        $Context = (Connect-AzAccount @params).context

        $Context = Set-AzContext -SubscriptionName $Context.Subscription -DefaultProfile $Context

        if ($params.Identity -eq $true) {
            Write-Verbose '[COMMON]: - Running in Azure Automation - Generating connection environment variables'

            try {
                if ($null -eq $global:PSModuleAutoloadingPreference) {
                    $null = Get-AutomationVariable -Name DummyVar -ErrorAction SilentlyContinue
                }
                else {
                    $AutoloadingPreference = $global:PSModuleAutoloadingPreference
                    $global:PSModuleAutoloadingPreference = 'All'
                    $null = Get-AutomationVariable -Name DummyVar -ErrorAction SilentlyContinue
                    $global:PSModuleAutoloadingPreference = $AutoloadingPreference
                }
            }
            catch {
                # Do nothing. We just want to trigger auto import of Orchestrator.AssetManagement.Cmdlets
            }

            if ($env:MG_PRINCIPAL_DISPLAYNAME) {
                #region [COMMON] ENVIRONMENT ---------------------------------------------------
                ./Common_0000__Import-Module.ps1 -Modules @(
                    @{ Name = 'Az.Automation'; MinimumVersion = '1.7'; MaximumVersion = '1.65535' }
                ) 1> $null
                #endregion ---------------------------------------------------------------------

                $AzAutomationAccount = Get-AzAutomationAccount -DefaultProfile $Context -ErrorAction Stop -Verbose:$false | Where-Object { $_.AutomationAccountName -eq $env:MG_PRINCIPAL_DISPLAYNAME }
                if ($AzAutomationAccount) {
                    Write-Verbose '[COMMON]: - Retrieved Automation Account details'
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_SubscriptionId', $AzAutomationAccount.SubscriptionId)
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_ResourceGroupName', $AzAutomationAccount.ResourceGroupName)
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_AccountName', $AzAutomationAccount.AutomationAccountName)
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_IDENTITY_PrincipalId', $AzAutomationAccount.Identity.PrincipalId)
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_IDENTITY_TenantId', $AzAutomationAccount.Identity.TenantId)
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_IDENTITY_Type', $AzAutomationAccount.Identity.Type)

                    if ($PSPrivateMetadata.JobId) {

                        $AzAutomationJob = Get-AzAutomationJob -DefaultProfile $Context -ResourceGroupName $AzAutomationAccount.ResourceGroupName -AutomationAccountName $AzAutomationAccount.AutomationAccountName -Id $PSPrivateMetadata.JobId -ErrorAction Stop -Verbose:$false
                        if ($AzAutomationJob) {
                            Write-Verbose '[COMMON]: - Retrieved Automation Job details'
                            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_RUNBOOK_Name', $AzAutomationJob.RunbookName)
                            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_RUNBOOK_JOB_CreationTime', $AzAutomationJob.CreationTime.ToUniversalTime())
                            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_RUNBOOK_JOB_StartTime', $AzAutomationJob.StartTime.ToUniversalTime())

                            $AzAutomationRunbook = Get-AzAutomationRunbook -DefaultProfile $Context -ResourceGroupName $AzAutomationAccount.ResourceGroupName -AutomationAccountName $AzAutomationAccount.AutomationAccountName -Name $AzAutomationJob.RunbookName -ErrorAction Stop -Verbose:$false
                            if ($AzAutomationRunbook) {
                                Write-Verbose '[COMMON]: - Retrieved Automation Runbook details'
                                [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_RUNBOOK_CreationTime', $AzAutomationRunbook.CreationTime.ToUniversalTime())
                                [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_RUNBOOK_LastModifiedTime', $AzAutomationRunbook.LastModifiedTime.ToUniversalTime())
                            }
                            else {
                                Throw "[COMMON]: - Unable to find own Automation Runbook details for runbook name $($AzAutomationJob.RunbookName)"
                            }
                        }
                        else {
                            Throw "[COMMON]: - Unable to find own Automation Job details for job Id $($PSPrivateMetadata.JobId)"
                        }
                    }
                    else {
                        Throw '[COMMON]: - Missing global variable $PSPrivateMetadata.JobId'
                    }
                }
                else {
                    Throw "[COMMON]: - Unable to find own Automation Account details for '$env:MG_PRINCIPAL_DISPLAYNAME'"
                }
            }
            else {
                Throw '[COMMON]: - Missing environment variable $env:MG_PRINCIPAL_DISPLAYNAME. Please run Common_0001__Connect-MgGraph.ps1 first.'
            }
        }
        else {
            Write-Verbose '[COMMON]: - Not running in Azure Automation - no connection environment variables set.'
        }
    }
    catch {
        Write-Error $_.Exception.Message -ErrorAction Stop
        exit
    }
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
