<#PSScriptInfo
.VERSION 1.2.0
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
    Version 1.2.0 (2024-05-21)
    - Use pipeline to process jobs to avoid memory issues.
    - Add explicit garbage collection.
    - Be less verbose about queue position.
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
        $warningCounter = 0
        $warningInterval = 180  # 3 minutes / 1 second sleep

        do {
            $activeJobs = New-Object System.Collections.ArrayList

            try {
                # Get all jobs for the runbook and process using pipeline to avoid memory issues
                Get-AzAutomationJob -ResourceGroupName $env:AZURE_AUTOMATION_ResourceGroupName -AutomationAccountName $env:AZURE_AUTOMATION_AccountName -RunbookName $env:AZURE_AUTOMATION_RUNBOOK_Name -ErrorAction Stop -Verbose:$false |
                & {
                    process {
                        if (
                            $_.status -eq 'Running' -or
                            $_.status -eq 'Queued' -or
                            $_.status -eq 'New' -or
                            $_.status -eq 'Activating' -or
                            $_.status -eq 'Resuming'
                        ) {
                            [void] $activeJobs.Add(
                                @{
                                    JobId        = $_.JobId
                                    CreationTime = $_.CreationTime
                                }
                            )
                        }
                    }
                }
            }
            catch {
                Throw $_
            }

            $activeJobs = @($activeJobs | Sort-Object -Property CreationTime -Descending)
            $currentJob = $activeJobs | Where-Object { $_.JobId -eq $PSPrivateMetadata.JobId }

            if ($null -eq $currentJob) {
                $waitTime = $((Get-Random -Minimum (3000 / $WaitStep) -Maximum (8000 / $WaitStep)) * $WaitStep)
                $waitTimeInSeconds = [Math]::Round($waitTime / 1000, 2)
                Write-Warning "[INFO]: - $(Get-Date -Format yyyy-MM-dd-hh-mm-ss.ffff) Current job not found (yet) in the list of active jobs. Waiting for $waitTimeInSeconds seconds to appear."
                Start-Sleep -Milliseconds $waitTime
            }
            elseif ($currentJob.JobId -eq $activeJobs[0].JobId) {
                Write-Verbose "[INFO]: - $(Get-Date -Format yyyy-MM-dd-hh-mm-ss.ffff) Current job is at the top of the queue."
                $DoLoop = $false
                $return = $true
            }
            elseif ($RetryCount -ge $MaxRetry) {
                Write-Warning "[INFO]: - $(Get-Date -Format yyyy-MM-dd-hh-mm-ss.ffff) Maximum retry count reached. Exiting loop."
                $DoLoop = $false
                $return = $false
            }
            else {
                $RetryCount++
                $waitTime = $((Get-Random -Minimum ($WaitMin / $WaitStep) -Maximum ($WaitMax / $WaitStep)) * $WaitStep)
                $waitTimeInSeconds = [Math]::Round($waitTime / 1000, 2)
                $rank = 0
                for ($i = 0; $i -lt $activeJobs.Length; $i++) {
                    if ($activeJobs[$i].jobId -eq $currentJob.JobId) {
                        $rank = $i
                        break
                    }
                }
                if ($warningCounter % $warningInterval -eq 0) {
                    Write-Warning "[INFO]: - $(Get-Date -Format yyyy-MM-dd-hh-mm-ss.ffff) Waiting for concurrent jobs: I am at rank $($rank) out of $($activeJobs.Count) active jobs. Waiting for $waitTimeInSeconds seconds. Next status update will be in $warningInterval seconds."
                }
                else {
                    Write-Verbose "[INFO]: - $(Get-Date -Format yyyy-MM-dd-hh-mm-ss.ffff) Waiting for concurrent jobs: I am at rank $($rank) out of $($activeJobs.Count) active jobs. Waiting for $waitTimeInSeconds seconds."
                }
                Start-Sleep -Milliseconds $waitTime
            }

            $warningCounter++
            Clear-Variable -Name activeJobs
            Clear-Variable -Name currentJob
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        } while ($DoLoop)
    }
}
else {
    Write-Verbose '[COMMON]: - Not running in Azure Automation: Concurrency check NOT ACTIVE.'
    $return = $true
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
