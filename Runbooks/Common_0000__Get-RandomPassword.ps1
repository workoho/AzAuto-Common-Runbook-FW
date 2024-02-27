<#PSScriptInfo
.VERSION 1.0.0
.GUID 710022f9-8ea6-49a9-8a1a-0714ff253fe0
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
    Generates a random password with specified length and character requirements.

.DESCRIPTION
    This script generates a random password by combining characters from different character sets, such as lowercase letters, uppercase letters, numbers, and special characters. The length of the password and the minimum number of characters required from each set can be specified as parameters.

.PARAMETER length
    The length of the generated password.

.PARAMETER minLower
    The minimum number of lowercase letters required in the password. Default is 0.

.PARAMETER minUpper
    The minimum number of uppercase letters required in the password. Default is 0.

.PARAMETER minNumber
    The minimum number of numbers required in the password. Default is 0.

.PARAMETER minSpecial
    The minimum number of special characters required in the password. Default is 0.

.OUTPUTS
    System.String
    The generated random password.

.EXAMPLE
    PS> Common_0000__Get-RandomPassword.ps1 -length 12 -minLower 2 -minUpper 2 -minNumber 2 -minSpecial 2
    Generates a random password with a length of 12, including at least 2 lowercase letters, 2 uppercase letters, 2 numbers, and 2 special characters.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory)]
    [Int32]$length,

    [Int32]$minLower = 0,
    [Int32]$minUpper = 0,
    [Int32]$minNumber = 0,
    [Int32]$minSpecial = 0
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

#region [COMMON] FUNCTIONS -----------------------------------------------------
function Get-RandomCharacter([Int32]$length, [string]$characters) {
    if ($length -lt 1) { return '' }
    if (Get-Command Get-SecureRandom -ErrorAction SilentlyContinue) {
        $random = 1..$length | & { process { Get-SecureRandom -Maximum $characters.Length } }
    }
    else {
        $random = 1..$length | & { process { Get-Random -Maximum $characters.Length } }
    }
    $private:ofs = ''
    return [string]$characters[$random]
}
function Get-ScrambleString([string]$inputString) {
    $characterArray = $inputString.ToCharArray()
    if (Get-Command Get-SecureRandom -ErrorAction SilentlyContinue) {
        return -join ($characterArray | Get-SecureRandom -Count $characterArray.Length)
    }
    else {
        return -join ($characterArray | Get-Random -Count $characterArray.Length)
    }
}
#endregion ---------------------------------------------------------------------

# Define character sets
$lowerChars = 'abcdefghijklmnopqrstuvwxyz'
$upperChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
$numberChars = '0123456789'
$specialChars = "~`!@#$%^&*()_-+={[}]|\:;`"'<,>.?/"

# Calculate the number of characters needed for each set
$totalChars = $minLower + $minUpper + $minNumber + $minSpecial
$remainingChars = $length - $totalChars
$lowerCharsNeeded = [Math]::Max($minLower - $remainingChars, 0)
$upperCharsNeeded = [Math]::Max($minUpper - $remainingChars, 0)
$numberCharsNeeded = [Math]::Max($minNumber - $remainingChars, 0)
$specialCharsNeeded = [Math]::Max($minSpecial - $remainingChars, 0)

# Generate the password
$return = [System.Text.StringBuilder]::new()
if ($lowerCharsNeeded -gt 0) {
    $null = $return.Append((Get-RandomCharacter -length $lowerCharsNeeded -characters $lowerChars))
}
if ($upperCharsNeeded -gt 0) {
    $null = $return.Append((Get-RandomCharacter -length $upperCharsNeeded -characters $upperChars))
}
if ($numberCharsNeeded -gt 0) {
    $null = $return.Append((Get-RandomCharacter -length $numberCharsNeeded -characters $numberChars))
}
if ($specialCharsNeeded -gt 0) {
    $null = $return.Append((Get-RandomCharacter -length $specialCharsNeeded -characters $specialChars))
}
$remainingChars = $length - $return.Length
if ($remainingChars -gt 0) {
    $null = $return.Append((Get-RandomCharacter -length $remainingChars -characters ($lowerChars + $upperChars + $numberChars + $specialChars)))
}
$return = Get-ScrambleString $return.ToString()

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
