<#PSScriptInfo
.VERSION 1.3.0
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
    Version 1.3.0 (2024-06-04)
    - Split setting of environment variables into two steps to enforce setting them after connecting to Microsoft Graph only.
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
    Please note that this information involves connecting to Microsoft Graph.
    However, due to incompatible modules, it is important that this script connects to Azure first before a connection to Microsoft Graph is established.
    Only then the environment variables can be set correctly. This is why the environment variables are set in a separate step using the parameter SetEnvVarsAfterMgConnect.

.PARAMETER Tenant
    Specifies the Azure AD tenant ID to use for authentication. If not provided, the default tenant will be used.

.PARAMETER Subscription
    Specifies the Azure subscription ID to use. If not provided, the default subscription will be used.

.PARAMETER SetEnvVarsAfterMgConnect
    Specifies whether to set environment variables after connecting to Microsoft Graph. Default is $false.

.EXAMPLE
    PS> Common_0001__Connect-AzAccount.ps1 -Tenant 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -Subscription 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    Connects to Azure using the specified tenant and subscription.

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
    [bool]$SetEnvVarsAfterMgConnect
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

#region [COMMON] ENVIRONMENT ---------------------------------------------------
./Common_0000__Import-Module.ps1 -Modules @(
    @{ Name = 'Az.Accounts' }
) 1> $null
#endregion ---------------------------------------------------------------------

#region [COMMON] FUNCTIONS -----------------------------------------------------
function Set-EnvVarsAfterMgConnect {
    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        Write-Verbose '[COMMON]: - Running in Azure Automation - Generating connection environment variables'

        if ([string]::IsNullOrEmpty($env:MG_PRINCIPAL_DISPLAYNAME)) {
            Throw '[COMMON]: - Missing environment variable $env:MG_PRINCIPAL_DISPLAYNAME. Please run Common_0001__Connect-MgGraph.ps1 first.'
        }

        #region [COMMON] ENVIRONMENT ---------------------------------------------------
        try {
            if ($null -eq $global:PSModuleAutoloadingPreference) {
                $null = Get-AutomationVariable -Name DummyVar -ErrorAction SilentlyContinue -WhatIf
            }
            else {
                $AutoloadingPreference = $global:PSModuleAutoloadingPreference
                $global:PSModuleAutoloadingPreference = 'All'
                $null = Get-AutomationVariable -Name DummyVar -ErrorAction SilentlyContinue -WhatIf
                $global:PSModuleAutoloadingPreference = $AutoloadingPreference
            }
        }
        catch {
            # Do nothing. We just want to trigger auto import of Orchestrator.AssetManagement.Cmdlets
        }

        ./Common_0000__Import-Module.ps1 -Modules @(
            @{ Name = 'Az.Automation'; MinimumVersion = '1.7'; MaximumVersion = '1.65535' }
        ) 1> $null
        #endregion ---------------------------------------------------------------------

        $AzAutomationAccount = Get-AzAutomationAccount -ErrorAction Stop -Verbose:$false | Where-Object { $_.AutomationAccountName -eq $env:MG_PRINCIPAL_DISPLAYNAME }
        if ($AzAutomationAccount) {
            Write-Verbose '[COMMON]: - Retrieved Automation Account details'
            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_SubscriptionId', $AzAutomationAccount.SubscriptionId)
            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_ResourceGroupName', $AzAutomationAccount.ResourceGroupName)
            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_AccountName', $AzAutomationAccount.AutomationAccountName)
            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_IDENTITY_PrincipalId', $AzAutomationAccount.Identity.PrincipalId)
            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_IDENTITY_TenantId', $AzAutomationAccount.Identity.TenantId)
            [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_IDENTITY_Type', $AzAutomationAccount.Identity.Type)

            if ($PSPrivateMetadata.JobId) {

                $AzAutomationJob = Get-AzAutomationJob -ResourceGroupName $AzAutomationAccount.ResourceGroupName -AutomationAccountName $AzAutomationAccount.AutomationAccountName -Id $PSPrivateMetadata.JobId -ErrorAction Stop -Verbose:$false
                if ($AzAutomationJob) {
                    Write-Verbose '[COMMON]: - Retrieved Automation Job details'
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_RUNBOOK_Name', $AzAutomationJob.RunbookName)
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_RUNBOOK_JOB_CreationTime', $AzAutomationJob.CreationTime.ToUniversalTime())
                    [Environment]::SetEnvironmentVariable('AZURE_AUTOMATION_RUNBOOK_JOB_StartTime', $AzAutomationJob.StartTime.ToUniversalTime())

                    $AzAutomationRunbook = Get-AzAutomationRunbook -ResourceGroupName $AzAutomationAccount.ResourceGroupName -AutomationAccountName $AzAutomationAccount.AutomationAccountName -Name $AzAutomationJob.RunbookName -ErrorAction Stop -Verbose:$false
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
        Write-Verbose '[COMMON]: - Not running in Azure Automation - no connection environment variables set.'
    }
}
#endregion ---------------------------------------------------------------------

if (Get-AzContext) {
    if ($SetEnvVarsAfterMgConnect -eq $true) {
        try {
            Set-EnvVarsAfterMgConnect
        }
        catch {
            Write-Error $_.Exception.Message -ErrorAction Stop
            exit
        }
    }
}
else {
    $Context = $null
    $params = @{
        Scope       = 'Process'
        ErrorAction = 'Stop'
    }

    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        Write-Verbose '[COMMON]: - Using system-assigned Managed Service Identity'
        $params.Identity = $true
    }
    elseif (
        $env:GITHUB_CODESPACE_TOKEN -or
        $env:AWS_CLOUD9_USER
    ) {
        Write-Verbose '[COMMON]: - Using device code authentication'
        $params.UseDeviceAuthentication = $true
    }
    else {
        Write-Verbose '[COMMON]: - Using interactive sign in'
    }

    try {
        if ($Tenant) {
            if (
                $Tenant -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
                $Tenant -eq '00000000-0000-0000-0000-000000000000'
            ) {
                Throw '[COMMON]: - Invalid tenant ID. The tenant ID must be a valid GUID.'
            }
            $params.Tenant = $Tenant
        }
        if ($Subscription) { $params.Subscription = $Subscription }

        Write-Information 'Connecting to Microsoft Azure ...' -InformationAction Continue
        $Context = (Connect-AzAccount @params).context
        $Context = Set-AzContext -SubscriptionName $Context.Subscription -DefaultProfile $Context

        if ($SetEnvVarsAfterMgConnect -eq $true) {
            Set-EnvVarsAfterMgConnect
        }
    }
    catch {
        Write-Error "Microsoft Azure connection error: $($_.Exception.Message)" -ErrorAction Stop
        exit
    }
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
