<#PSScriptInfo
.VERSION 1.1.2
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
    Version 1.1.2 (2024-06-22)
    - Fixed issue with date conversion in PowerShell 5
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
if ($null -eq $InputObject -or $InputObject.count -eq 0) { "{}"; exit }
if (-Not $Global:hasRunBefore) { $Global:hasRunBefore = @{} }
if (-Not $Global:hasRunBefore.ContainsKey((Get-Item $PSCommandPath).Name)) {
    Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
}
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

function Convert-DateTimeInObject {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        [psobject]$InputObject
    )

    process {
        function Process-Object {
            param (
                [psobject]$Obj
            )

            if ($Obj -is [System.Collections.IDictionary]) {
                $keys = @($Obj.Keys)  # Create a copy of the keys to avoid modification issues
                foreach ($key in $keys) {
                    $value = $Obj[$key]
                    if ($value -is [DateTime]) {
                        Write-Debug "Converting DateTime property '$key'"
                        $Obj[$key] = $value.ToString("o")
                    }
                    elseif ($value -is [PSObject] -or $value -is [System.Collections.IDictionary] -or ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string]))) {
                        Process-Object -Obj $value
                    }
                }
            }
            elseif ($Obj -is [PSObject]) {
                $properties = @($Obj.PSObject.Properties)  # Create a copy of the properties to avoid modification issues
                foreach ($property in $properties) {
                    if ($property.IsSettable) {
                        $value = $property.Value
                        if ($value -is [DateTime]) {
                            Write-Debug "Converting DateTime property '$($property.Name)'"
                            $Obj.$($property.Name) = $value.ToString("o")
                        }
                        elseif ($value -is [PSObject] -or $value -is [System.Collections.IDictionary] -or ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string]))) {
                            Process-Object -Obj $value
                        }
                    }
                }
            }
            elseif ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
                foreach ($item in $Obj) {
                    if ($item -is [PSObject] -or $item -is [System.Collections.IDictionary] -or ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string]))) {
                        Process-Object -Obj $item
                    }
                }
            }
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
            foreach ($item in $InputObject) {
                if ($item -is [PSObject] -or $item -is [System.Collections.IDictionary] -or ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string]))) {
                    Process-Object -Obj $item
                }
            }
        }
        elseif ($InputObject -is [PSObject] -or $InputObject -is [System.Collections.IDictionary] -or ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string]))) {
            Process-Object -Obj $InputObject
        }

        $InputObject
    }
}

try {
    $params = if ($ConvertToParam) { $ConvertToParam.Clone() } else { @{} }
    if ($null -eq $params.Compress) {
        if ($VerbosePreference -eq 'Continue' -or $DebugPreference -eq 'Continue') {
            $params.Compress = $false
        }
        else {
            $params.Compress = $true
        }
        Write-Verbose "Setting default compression to $($params.Compress)"
    }
    if ($null -eq $params.Depth) {
        Write-Verbose "Setting default depth to 5"
        $params.Depth = 5
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Write-Output $($InputObject | Convert-DateTimeInObject | ConvertTo-Json @params)
    }
    else {
        Write-Output $($InputObject | ConvertTo-Json @params)
    }
}
catch {
    Throw $_.Exception.Message
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
if (-Not $Global:hasRunBefore.ContainsKey((Get-Item $PSCommandPath).Name)) {
    $Global:hasRunBefore[(Get-Item $PSCommandPath).Name] = $true
    Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
}
