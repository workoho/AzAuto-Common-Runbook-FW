<#PSScriptInfo
.VERSION 1.3.0
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
    Version 1.3.0 (2024-06-06)
    - Use Invoke-AzRestMethod
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
    # Implicitly connect to Azure Graph API using the Common_0001__Connect-MgGraph.ps1 script.
    # This will ensure the connections are established in the correct order, while still retrieving the necessary environment variables.
    ./Common_0001__Connect-MgGraph.ps1
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
                $params = @{
                    Method      = 'GET'
                    Path        = "$($env:AZURE_AUTOMATION_AccountId)/jobs?api-version=2023-11-01"
                    ErrorAction = 'Stop'
                    Verbose     = $false
                    Debug       = $false
                }
                (./Common_0001__Invoke-AzRestMethod.ps1 $params).Content.value.properties |
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
                                    jobId        = $_.jobId
                                    creationTime = [DateTime]::Parse($_.creationTime).ToUniversalTime()
                                }
                            )
                        }
                    }
                }
            }
            catch {
                Throw $_
            }

            $activeJobs = @($activeJobs | Sort-Object -Property creationTime)
            $currentJob = $activeJobs | Where-Object { $_.jobId -eq $PSPrivateMetadata.JobId }

            if ($null -eq $currentJob) {
                $waitTime = $((Get-Random -Minimum (3000 / $WaitStep) -Maximum (8000 / $WaitStep)) * $WaitStep)
                $waitTimeInSeconds = [Math]::Round($waitTime / 1000, 2)
                Write-Warning "[INFO]: - Current job not found (yet) in the list of active jobs. Waiting for $waitTimeInSeconds seconds to appear."
                Start-Sleep -Milliseconds $waitTime
            }
            elseif ($currentJob.jobId -eq $activeJobs[0].jobId) {
                Write-Verbose "[INFO]: - Current job is at the top of the queue."
                $DoLoop = $false
                $return = $true
            }
            elseif ($RetryCount -ge $MaxRetry) {
                Write-Warning "[INFO]: - Maximum retry count reached. Exiting loop."
                $DoLoop = $false
                $return = $false
            }
            else {
                $RetryCount++
                $waitTime = $((Get-Random -Minimum ($WaitMin / $WaitStep) -Maximum ($WaitMax / $WaitStep)) * $WaitStep)
                $waitTimeInSeconds = [Math]::Round($waitTime / 1000, 2)
                $warningCounter += $waitTimeInSeconds
                $rank = 1
                for ($i = 0; $i -lt $activeJobs.Length; $i++) {
                    if ($activeJobs[$i].jobId -eq $currentJob.jobId) {
                        $rank = $i + 1
                        break
                    }
                }
                if ($warningCounter -ge $warningInterval) {
                    Write-Warning "[INFO]: - Waiting for concurrent jobs: I am at rank $($rank) out of $($activeJobs.Count) active jobs. Waiting for $waitTimeInSeconds seconds. Next status update will be in $warningInterval seconds."
                    $warningCounter = 0
                }
                else {
                    Write-Verbose "[INFO]: - Waiting for concurrent jobs: I am at rank $($rank) out of $($activeJobs.Count) active jobs. Waiting for $waitTimeInSeconds seconds."
                }
                Start-Sleep -Milliseconds $waitTime
            }

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
