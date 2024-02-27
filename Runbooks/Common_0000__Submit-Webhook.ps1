<#PSScriptInfo
.VERSION 1.0.0
.GUID 35ab128e-c286-4240-9437-b4f2cd045650
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
    Send data to web service

.DESCRIPTION
    This script sends data to a web service using the specified URI and request body. It supports converting the body to different formats such as HTML, JSON, and XML. The script is designed to be used as a runbook and should not be run directly.

.PARAMETER Uri
    The URI of the web service to send the request to.

.PARAMETER Body
    The request body to send to the web service.

.PARAMETER Param
    Optional. Additional parameters to include in the web request.

.PARAMETER ConvertTo
    Optional. The format to convert the request body to. Supported values are 'Html', 'Json', 'Xml', where 'Json' is the default.

.PARAMETER ConvertToParam
    Optional. Additional parameters to pass to the conversion cmdlets.

.OUTPUTS
    The response from the web service.

.EXAMPLE
    PS> Common_0000__Submit-Webhook.ps1 -Uri 'https://example.com/webhook' -Body 'Hello, world!' -ConvertTo 'Json'

    Sends a JSON-formatted request body to the specified URI.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(mandatory = $true)]
    [String]$Uri,

    [Parameter(mandatory = $true)]
    [String]$Body,

    [Hashtable]$Param,
    [String]$ConvertTo = 'Json',
    [Hashtable]$ConvertToParam
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$WebRequestParams = if ($Param) { $Param.Clone() } else { @{} }
$WebRequestParams.Uri = $Uri

if (-Not $WebRequestParams.Method) { $WebRequestParams.Method = 'POST' }
if (-Not $WebRequestParams.UseBasicParsing) { $WebRequestParams.UseBasicParsing = $true }

$ConvertToParams = if ($ConvertToParam) { $ConvertToParam.Clone() } else { @{} }

Switch ($ConvertTo) {
    'Html' {
        $WebRequestParams.Body = $Body | ConvertTo-Html @ConvertToParams
    }
    'Json' {
        if ($null -eq $ConvertToParams.Depth) { $ConvertToParams.Depth = 100 }
        if ($null -eq $ConvertToParams.Compress) { $ConvertToParams.Compress = $true }
        $WebRequestParams.Body = $Body | ConvertTo-Json @ConvertToParams
    }
    'Xml' {
        if ($null -eq $ConvertToParams.Depth) { $ConvertToParams.Depth = 100 }
        $WebRequestParams.Body = $Body | ConvertTo-Xml @ConvertToParams
    }
    default {
        $WebRequestParams.Body = $Body
    }
}

$return = Invoke-WebRequest @WebRequestParams

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
