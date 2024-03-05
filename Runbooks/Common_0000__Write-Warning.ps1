<#PSScriptInfo
.VERSION 1.0.0
.GUID b78c31c3-d20e-4128-86d5-8cb454b8b314
.AUTHOR Julian Pawlowski
.COMPANYNAME Workoho GmbH
.COPYRIGHT © 2024 Workoho GmbH
.TAGS
.LICENSEURI https://github.com/Workoho/AzAuto-Common-Runbook-FW/LICENSE.txt
.PROJECTURI https://github.com/Workoho/AzAuto-Common-Runbook-FW
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
    Write warning to warning stream and return back object

.DESCRIPTION
    This script is used to write a warning message to the warning stream and return back an object.
    This is a wrapper around Write-Warning cmdlet that returns the same message as an object so it can afterwards be added to a collection of warnings in your runbook.
    The collecation may be used to return all errors at once at the end of the runbook, for example when you want to send a response to a calling system using a webhook.

    The data structure generally follows more the one of the Write-Error cmdlet to allow adding more information for your calling system.
    The data that Write-Warning cmdlet will output is only the message property of the object.

.PARAMETER Param
    Specifies the parameter to be used for the warning message. It can be a string or an object.

.EXAMPLE
    PS> $script:returnWarning = [System.Collections.ArrayList]::new()
    PS> [void] $script:returnWarning.Add(( ./Common_0000__Write-Warning.ps1 @{
                Message           = "Your warning message here."
                ErrorId           = '201'
                Category          = 'OperationStopped'
                TargetName        = $ReferralUserId
                TargetObject      = $null
                RecommendedAction = 'Try again later.'
                CategoryActivity  = 'Persisent Error'
                CategoryReason    = "No other items are processed due to persistent error before."
            }))

    This example outputs an warning message to the warning stream and adds the same message to the $script:returnWarning collection.

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

$params = if ($Param) {
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
if (-not [string]::IsNullOrEmpty($params.Message)) {
    Write-Warning -Message $($params.Message)
}

# Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $params
