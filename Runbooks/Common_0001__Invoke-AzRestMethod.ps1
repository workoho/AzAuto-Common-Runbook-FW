<#PSScriptInfo
.VERSION 1.0.0
.GUID 0a0e5eb3-0470-427e-b264-9bab18f90617
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
    Version 1.0.0 (2024-06-06)
    - Initial release.
#>

<#
.SYNOPSIS
    Wrapper for Invoke-AzRestMethod to add retries for rate limiting and service unavailable errors.

.DESCRIPTION
    This script is a wrapper for the Invoke-AzRestMethod script to add retries in case of rate limiting or service unavailable errors.
    The script will retry the request up to 5 times with an exponential backoff strategy. The script will also handle the Retry-After header for rate limiting errors.
    Note that when using batch requests, each response must be checked for rate limiting separately as this script only handles this for the batch request itself.

.PARAMETER Params
    The parameters to pass to the Invoke-AzRestMethod cmdlet using splatting.

.OUTPUTS
    The response from the Azure REST API request.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [hashtable] $Params
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$maxRetries = 5
$retryCount = 0
$baseWaitTime = 1 # start with 1 second

if ($Params.Payload -is [System.Collections.IEnumerable]) {
    $Params.Payload = $Params.Payload | ConvertTo-Json -Depth 10
}

do {
    try {
        $response = Az.Accounts\Invoke-AzRestMethod @Params
        if (-not [string]::IsNullOrEmpty($response.Content) -and $response.Content -match '^\s*{') {
            if ($PSVersionTable.PSEdition -eq 'Desktop') {
                $response | Add-Member -NotePropertyName 'Content' -NotePropertyValue $($response.Content | ConvertFrom-Json) -Force
            } else {
                $response | Add-Member -NotePropertyName 'Content' -NotePropertyValue $($response.Content | ConvertFrom-Json -Depth 10) -Force
            }
        }
        $rateLimitExceeded = $false
    }
    catch {
        if ($null -eq $_.Exception.Response) {
            Throw "Network error: $($_.Exception.Message)"
        }
        if ($_.Exception.Response.StatusCode -eq 404) {
            $rateLimitExceeded = $false
        }
        elseif (
            $_.Exception.Response.StatusCode -eq 429 -or
            $_.Exception.Response.StatusCode -eq 503
        ) {
            $waitTime = [math]::max($_.Exception.Response.Headers['Retry-After'] -as [int], $baseWaitTime)
            $jitter = Get-Random -Minimum 0 -Maximum 0.5 # random jitter between 0 and 0.5 seconds, with decimal precision
            $waitTime += $jitter
            Clear-Variable -Name response
            [System.GC]::Collect()

            if ($_.Exception.Response.StatusCode -eq 429) {
                Write-Verbose "[COMMON]: - Rate limit exceeded, retrying in $waitTime seconds..."
            }
            else {
                Write-Verbose "[COMMON]: - Service unavailable, retrying in $waitTime seconds..."
            }

            Start-Sleep -Milliseconds ($waitTime * 1000) # convert wait time to milliseconds for Start-Sleep
            $retryCount++
            $baseWaitTime *= 1.5 # client side exponential backoff
            $rateLimitExceeded = $true
        }
        else {
            $errorMessage = $_.Exception.Response.Content.ReadAsStringAsync().Result | ConvertFrom-Json
            Throw "Error $($_.Exception.Response.StatusCode.value__) $($_.Exception.Response.StatusCode): [$($errorMessage.error.code)] $($errorMessage.error.message)"
        }
    }
} while ($rateLimitExceeded -and $retryCount -lt $maxRetries)

if ($rateLimitExceeded) {
    Throw "Rate limit exceeded after $maxRetries retries."
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"

return $response
