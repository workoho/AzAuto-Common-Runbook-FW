<#PSScriptInfo
.VERSION 1.2.0
.GUID e392dfb1-8ca4-4f5c-b073-c453ce004891
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
    Version 1.2.0 (2024-06-11)
    - Remove dependency on Az.Monitor and Az.Resources modules
#>

<#
.SYNOPSIS
    This script retrieves information about the current Azure Automation job.

.DESCRIPTION
    The script is designed to be used as a runbook within Azure Automation.
    It retrieves information about the current job, such as creation time, start time, automation account details, and runbook details.

    Note that the script will only work when Common_0001__Connect-AzAccount.ps1 has been executed before as it relies on environment variables set by that script.
    Otherwise, the script will generate some dummy information, for example during local development.

.PARAMETER StartedBy
    If set to $true, the script will wait for the job activity log to appear and retrieve the user who started the job.
    This is useful when you want to know who started the job, for example to send an email to the user.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [bool]$StartedBy = $false
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$return = @{
    CreationTime      = $null
    StartTime         = $null
    AutomationAccount = $null
    Runbook           = $null
}

if (
    $env:AZURE_AUTOMATION_RUNBOOK_JOB_CreationTime -and
    $env:AZURE_AUTOMATION_RUNBOOK_JOB_StartTime -and
    $env:AZURE_AUTOMATION_ResourceGroupName
) {
    $return.JobId = $PSPrivateMetadata.JobId
    $return.CreationTime = [datetime]::Parse($env:AZURE_AUTOMATION_RUNBOOK_JOB_CreationTime).ToUniversalTime()
    $return.StartTime = [datetime]::Parse($env:AZURE_AUTOMATION_RUNBOOK_JOB_StartTime).ToUniversalTime()

    if ($StartedBy) {
        $StartTime = ($return.CreationTime).AddMinutes(-5)
        $JobInfo = @{}
        $TimeoutLoop = 0
        while ($null -eq $return.StartedBy -and $TimeoutLoop -lt 9 ) {
            Write-Verbose "[COMMON]: - Waiting for job activity log to appear ..."
            $TimeoutLoop++

            $params = @{
                Method = 'GET'
                Path   = "/subscriptions/$((Get-AzContext).Subscription.Id)/providers/Microsoft.Insights/EventTypes/management/values?`$select=Authorization,Caller&`$filter=eventTimestamp ge $([System.Web.HttpUtility]::UrlEncode($StartTime.ToString('o'))) and resourceGroupName eq '$($env:AZURE_AUTOMATION_ResourceGroupName)'&api-version=2015-04-01"
            }
            $Log = (./Common_0001__Invoke-AzRestMethod.ps1 $params).Content.value | Where-Object { $_.authorization.action -eq 'Microsoft.Automation/automationAccounts/jobs/write' -and $_.authorization.scope -like "*$($PSPrivateMetadata.JobId)" }

            if ($Log) {
                Write-Verbose "[COMMON]: - Found caller $($Log.Caller) for job ID $($PSPrivateMetadata.JobId) ..."
                $return.StartedBy = $Log.Caller
            }

            $Log = $null
            [System.GC]::Collect()
            if ($null -eq $return.StartedBy) { Start-Sleep 10 }
        }
    }

    $return.AutomationAccount = @{
        SubscriptionId    = $env:AZURE_AUTOMATION_SubscriptionId
        ResourceGroupName = $env:AZURE_AUTOMATION_ResourceGroupName
        Name              = $env:AZURE_AUTOMATION_AccountName
        Identity          = @{
            PrincipalId = $env:AZURE_AUTOMATION_IDENTITY_PrincipalId
            TenantId    = $env:AZURE_AUTOMATION_IDENTITY_TenantId
            Type        = $env:AZURE_AUTOMATION_IDENTITY_Type
        }
    }
    $return.Runbook = @{
        Name             = $env:AZURE_AUTOMATION_RUNBOOK_Name
        CreationTime     = [datetime]::Parse($env:AZURE_AUTOMATION_RUNBOOK_CreationTime).ToUniversalTime()
        LastModifiedTime = [datetime]::Parse($env:AZURE_AUTOMATION_RUNBOOK_LastModifiedTime).ToUniversalTime()
    }
}
else {
    $return.CreationTime = [datetime]::UtcNow
    $return.StartTime = $return.CreationTime
    $return.Runbook = @{
        Name = (Get-Item $MyInvocation.MyCommand).BaseName
    }
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
