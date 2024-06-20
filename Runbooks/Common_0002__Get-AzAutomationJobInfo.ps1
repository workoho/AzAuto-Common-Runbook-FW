<#PSScriptInfo
.VERSION 1.3.0
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
    Version 1.3.0 (2024-06-20)
    - Remove StartedBy parameter because it is no longer possible to
      retrieve the user who started the job from Azure Activity Log due to
      missmatch between job ID and Azure Resource ID.

<#
.SYNOPSIS
    This script retrieves information about the current Azure Automation job.

.DESCRIPTION
    The script is designed to be used as a runbook within Azure Automation.
    It retrieves information about the current job, such as creation time, start time, automation account details, and runbook details.

    Note that the script will only work when Common_0001__Connect-AzAccount.ps1 has been executed before as it relies on environment variables set by that script.
    Otherwise, the script will generate some dummy information, for example during local development.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param()

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
    $PSPrivateMetadata.JobId -and
    $env:AZURE_AUTOMATION_RUNBOOK_JOB_CreationTime -and
    $env:AZURE_AUTOMATION_RUNBOOK_JOB_StartTime -and
    $env:AZURE_AUTOMATION_AccountId
) {
    $return.JobId = $PSPrivateMetadata.JobId
    $return.CreationTime = [datetime]::Parse($env:AZURE_AUTOMATION_RUNBOOK_JOB_CreationTime).ToUniversalTime()
    $return.StartTime = [datetime]::Parse($env:AZURE_AUTOMATION_RUNBOOK_JOB_StartTime).ToUniversalTime()

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

    $params = @{
        Path = "$($env:AZURE_AUTOMATION_AccountId)/runbooks/$($return.Runbook.Name)&api-version=2023-11-01"
    }
    $tags = (./Common_0001__Invoke-AzRestMethod.ps1 $params).Content.tags

    $return.Runbook.ScriptVersion = $tags.'Script.Version'
    $return.Runbook.ScriptGuid = $tags.'Script.Guid'
}
else {
    $return.CreationTime = [datetime]::UtcNow
    $return.StartTime = $return.CreationTime
    $return.Runbook = @{
        Name = (Get-Item $MyInvocation.PSCommandPath).BaseName
    }

    Test-ScriptFileInfo $($return.Runbook.Name + '.ps1') -ErrorAction Stop | Select-Object -Property Version, Guid | ForEach-Object { $return.Runbook.ScriptVersion = $_.Version; $return.Runbook.ScriptGuid = $_.Guid }
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
