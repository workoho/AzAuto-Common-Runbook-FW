<#PSScriptInfo
.VERSION 1.0.0
.GUID 559c2a2a-cf2d-46d5-a39b-4ca644a4075b
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
    Write information to information stream and return back object

.DESCRIPTION
    This script is used to write information to the information stream and return back an object.
    This is a wrapper around Write-Information cmdlet that returns the same message as an object so it can afterwards be added to a collection of informations in your runbook.
    The collecation may be used to return all errors at once at the end of the runbook, for example when you want to send a response to a calling system using a webhook.

    The data structure generally follows more the one of the Write-Error cmdlet to allow adding more information for your calling system.
    The data that Write-Information cmdlet will output is only the message property of the object.

.PARAMETER Param
    Specifies the parameter to be used for the information message. It can be a string or an object.

.EXAMPLE
    PS> $script:returnInformation = [System.Collections.ArrayList]::new()
    PS> [void] $script:returnInformation.Add(( ./Common_0000__Write-Information.ps1 @{
                Message           = "Your information message here."
                Category         = 'NotEnabled'
                TargetName       = $refUserObj.UserPrincipalName
                TargetObject     = $refUserObj.Id
                TargetType       = 'UserId'
                CategoryActivity = 'Account Provisioning'
                CategoryReason   = 'Your Reason.'
                Tags             = 'UserId', 'Account Provisioning'
            }))

    This example outputs an information message to the information stream and adds the same message to the $script:returnInformation collection.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    $Param
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.'; exit }
# Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"

$params = if ($Param) {
    if ($Param -is [String]) {
        @{ MessageData = $Param }
    }
    else {
        $Param.Clone()
    }
}
else {
    @{}
}

if (-Not $params.MessageData -and $params.Message) {
    $params.MessageData = $params.Message
    $params.Remove('Message')
}
$iparams = @{}
$params.Keys | & {
    process {
        if ($_ -notin 'MessageData', 'Tags', 'InformationAction') { return }
        $iparams.$_ = $params.$_
    }
}
$params.Message = $params.MessageData
$params.Remove('MessageData')

Write-Information @iparams

# Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $params
