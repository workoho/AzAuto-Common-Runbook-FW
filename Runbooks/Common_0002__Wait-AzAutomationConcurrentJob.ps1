<#PSScriptInfo
.VERSION 1.0.0
.GUID 7c2ab51e-4863-474e-bfcf-6854d3c3a688
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
    Version 1.0.0 (2024-01-18)
    - First release.
#>

<#
.SYNOPSIS
    This script is used to wait for concurrent jobs in Azure Automation.

.DESCRIPTION
    This script checks for the presence of concurrent jobs in Azure Automation and waits until the current job is at the top of the queue.

.EXAMPLE
    PS> Common_0002__Wait-AzAutomationConcurrentJob.ps1

    Waits for concurrent jobs in Azure Automation.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param()

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {

    #region [COMMON] CONNECTIONS ---------------------------------------------------
    ./Common_0001__Connect-AzAccount.ps1
    #endregion ---------------------------------------------------------------------

    if ([string]::IsNullOrEmpty($env:AZURE_AUTOMATION_ResourceGroupName)) {
        Throw 'Missing environment variable $env:AZURE_AUTOMATION_ResourceGroupName.'
    }
    if ([string]::IsNullOrEmpty($env:AZURE_AUTOMATION_AccountName)) {
        Throw 'Missing environment variable $env:AZURE_AUTOMATION_AccountName.'
    }
    if ([string]::IsNullOrEmpty($env:AZURE_AUTOMATION_RUNBOOK_Name)) {
        Throw 'Missing environment variable $env:AZURE_AUTOMATION_RUNBOOK_Name.'
    }

    if ($env:AZURE_AUTOMATION_ResourceGroupName -and $env:AZURE_AUTOMATION_AccountName -and $env:AZURE_AUTOMATION_RUNBOOK_Name) {

        $DoLoop = $true
        $RetryCount = 1
        $MaxRetry = 300

        $WaitMin = 25000
        $WaitMax = 30000
        $WaitStep = 100

        do {
            try {
                $jobs = Get-AzAutomationJob -ResourceGroupName $env:AZURE_AUTOMATION_ResourceGroupName -AutomationAccountName $env:AZURE_AUTOMATION_AccountName -RunbookName $env:AZURE_AUTOMATION_RUNBOOK_Name -ErrorAction Stop -Verbose:$false
            }
            catch {
                Throw $_
            }
            $activeJobs = $jobs | Where-Object { $_.status -eq 'Running' -or $_.status -eq 'Queued' -or $_.status -eq 'New' -or $_.status -eq 'Activating' -or $_.status -eq 'Resuming' } | Sort-Object -Property CreationTime
            Clear-Variable -Name jobs

            $jobRanking = [System.Collections.ArrayList]::new()
            $rank = 0

            foreach ($activeJob in $activeJobs) {
                $rank++
                $activeJob | Add-Member -MemberType NoteProperty -Name jobRanking -Value $rank -Force
                $null = $jobRanking.Add($activeJob)
            }

            $currentJob = $activeJobs | Where-Object { $_.JobId -eq $PSPrivateMetadata.JobId }
            Clear-Variable -Name activeJobs

            If ($currentJob.jobRanking -eq 1) {
                $DoLoop = $false
                $return = $true
            }
            elseif ($RetryCount -ge $MaxRetry) {
                $DoLoop = $false
                $return = $false
            }
            else {
                $RetryCount += 1
                Write-Verbose "[COMMON]: - $(Get-Date -Format yyyy-MM-dd-hh-mm-ss.ffff) Waiting for concurrent jobs: I am at rank $($currentJob.jobRanking) ..." -Verbose
                Start-Sleep -Milliseconds $((Get-Random -Minimum ($WaitMin / $WaitStep) -Maximum ($WaitMax / $WaitStep)) * $WaitStep)
            }
        } While ($DoLoop)
    }
}
else {
    Write-Verbose '[COMMON]: - Not running in Azure Automation: Concurrency check NOT ACTIVE.'
    $return = $true
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
