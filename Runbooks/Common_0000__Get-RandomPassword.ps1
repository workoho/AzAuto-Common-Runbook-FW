<#PSScriptInfo
.VERSION 1.2.0
.GUID 710022f9-8ea6-49a9-8a1a-0714ff253fe0
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
    Version 1.2.0 (2024-05-17)
    - Small memory optimization.
    - Additional error handling.
    - Use cryptographically secure random number generator.
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

.PARAMETER maxSpecial
    The maximum number of special characters allowed in the password. Default is unlimited.

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
    [Int32]$minSpecial = 0,
    [Int32]$maxSpecial = -1
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

#region [COMMON] INPUT VALIDATION ----------------------------------------------
if ($length -lt $minLower + $minUpper + $minNumber + $minSpecial) {
    Write-Error 'Password length must be greater than or equal to the sum of minLower, minUpper, minNumber, and minSpecial.' -ErrorAction Stop
    exit 1
}
#endregion ---------------------------------------------------------------------

#region [COMMON] FUNCTIONS -----------------------------------------------------
function Get-CryptoRandomNumber([Int32]$maxValue) {
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $randomByte = [byte[]]::new(4)
    $rng.GetBytes($randomByte)
    $randomNumber = [System.BitConverter]::ToUInt32($randomByte, 0)
    return $randomNumber % $maxValue
}
function Get-RandomCharacter([Int32]$length, [string]$characters) {
    if ($length -lt 1) { return '' }
    $random = 1..$length | ForEach-Object {
        Get-CryptoRandomNumber $characters.Length
    }
    $private:ofs = ''
    return [string]$characters[$random]
}
function Get-ScrambleString([string]$inputString) {
    $characterArray = $inputString.ToCharArray()
    $scrambledArray = [System.Text.StringBuilder]::new()
    0..($characterArray.Length - 1) | ForEach-Object {
        $randomIndex = Get-CryptoRandomNumber $characterArray.Length
        $scrambledArray.Append($characterArray[$randomIndex]) | Out-Null
        $characterArray = $characterArray[0..($randomIndex - 1)] + $characterArray[($randomIndex + 1)..($characterArray.Length - 1)]
    }
    return $scrambledArray.ToString()
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

if ($maxSpecial -eq 0) {
    $specialCharsNeeded = 0
}
elseif ($maxSpecial -le -1) {
    $specialCharsNeeded = [Math]::Min($specialCharsNeeded, $maxSpecial)
}

# Initialize a counter for special characters
$specialCharCount = 0

try {
    # Generate the password
    $return = [System.Text.StringBuilder]::new()
    if ($lowerCharsNeeded -gt 0) {
        [void] $return.Append((Get-RandomCharacter -length $lowerCharsNeeded -characters $lowerChars))
    }
    if ($upperCharsNeeded -gt 0) {
        [void] $return.Append((Get-RandomCharacter -length $upperCharsNeeded -characters $upperChars))
    }
    if ($numberCharsNeeded -gt 0) {
        [void] $return.Append((Get-RandomCharacter -length $numberCharsNeeded -characters $numberChars))
    }
    if ($specialCharsNeeded -gt 0) {
        [void] $return.Append((Get-RandomCharacter -length $specialCharsNeeded -characters $specialChars))
        $specialCharCount += $specialCharsNeeded
    }

    $remainingChars = $length - $return.Length
    if ($remainingChars -gt 0) {
        while ($remainingChars -gt 0) {
            if ($maxSpecial -le -1 -or $specialCharCount -lt $maxSpecial) {
                $combinedChars = $lowerChars + $upperChars + $numberChars + $specialChars
            }
            else {
                $combinedChars = $lowerChars + $upperChars + $numberChars
            }

            $randomChar = Get-RandomCharacter -length 1 -characters $combinedChars
            [void] $return.Append($randomChar)

            if ($specialChars.Contains($randomChar) -and ($maxSpecial -le -1 -or $specialCharCount -lt $maxSpecial)) {
                $specialCharCount++
            }
            $remainingChars = $length - $return.Length
        }
    }
    $return = Get-ScrambleString $return.ToString()
}
catch {
    Throw "An error occurred: $_"
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
