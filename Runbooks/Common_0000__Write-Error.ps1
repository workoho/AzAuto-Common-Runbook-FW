<#PSScriptInfo
.VERSION 1.0.0
.GUID 1e45ba32-bbcf-46f8-a759-05e36e67ac09
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
    Write error to error stream and return back object

.DESCRIPTION
    This script is used to write an error to the error stream and return an object back an object.
    This is a wrapper around Write-Error cmdlet that returns the same message as an object so it can afterwards be added to a collection of errors in your runbook.
    The collecation may be used to return all errors at once at the end of the runbook, for example when you want to send a response to a calling system using a webhook.

.PARAMETER Param
    Specifies the parameter to be used for the error message. It can be a string or an object.

.EXAMPLE
    PS> $script:returnError = [System.Collections.ArrayList]::new()
    PS> [void] $script:returnError.Add(( ./Common_0000__Write-Error.ps1 @{
                Message           = "Your error message here."
                ErrorId           = '500'
                Category          = 'OperationStopped'
                TargetName        = $ReferralUserId
                TargetObject      = $null
                RecommendedAction = 'Try again later.'
                CategoryActivity  = 'Persisent Error'
                CategoryReason    = "No other items are processed due to persistent error before."
            }))

    This example outputs an error message to the error stream and adds the same message to the $script:returnError collection.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    $Param
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
# Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"

$return = if ($Param) {
    if ($Param -is [String]) {
        @{ Message = $Param }
    }
    else {
        $Param.Clone()
    }
}
else {
    @{}
}

Write-Error @return

# Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
