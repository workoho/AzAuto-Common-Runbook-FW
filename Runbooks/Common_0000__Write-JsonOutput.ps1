<#PSScriptInfo
.VERSION 1.0.0
.GUID fd95f377-4c0a-4dfa-addd-14cf6dca99cf
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
    Write text in JSON format to output stream

.DESCRIPTION
    This script is used to write text in JSON format to the output stream. It takes an input object and converts it to JSON using the ConvertTo-Json cmdlet. The converted JSON is then written to the output stream.

.PARAMETER InputObject
    Specifies the object to be converted to JSON.

.PARAMETER ConvertToParam
    Specifies additional parameters to be passed to the ConvertTo-Json cmdlet.

.EXAMPLE
    PS> Common_0000__Write-JsonOutput.ps1 -InputObject $data -ConvertToParam @{ Depth = 5; Compress = $false }
    This example converts the $data object to JSON with a depth of 5 and without compression, and writes it to the output stream.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    $InputObject,

    [hashtable]$ConvertToParam
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
# Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"

$params = if ($ConvertToParam) { $ConvertToParam.Clone() } else { @{} }
if ($null -eq $params.Compress) {
    $params.Compress = $true
    if ($VerbosePreference -eq 'Continue') { $params.Compress = $false }
}
if ($null -eq $params.Depth) { $params.Depth = 100 }

Write-Output $($InputObject | ConvertTo-Json @params)

# Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
