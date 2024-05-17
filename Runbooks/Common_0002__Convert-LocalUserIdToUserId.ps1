<#PSScriptInfo
.VERSION 1.0.1
.GUID 56ccfd86-ec40-4815-815a-00656a08952d
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
    Version 1.0.1 (2024-05-17)
    - Small memory optimization.
#>

<#
.SYNOPSIS
    Convert local User Principal Name like user@contoso.com or user_contoso.com#EXT@tenant.onmicrosoft.com to a user name like user@contoso.com.

.DESCRIPTION
    This script converts local User Principal Names (UPNs) to user names. It takes an array of UPNs as input and returns an array of corresponding user names.
    This is useful to convert UPNs of external users to the actual login names the users use to sign in and retreive emails.

    The conversion rules are as follows:
    - If the input is a valid GUID, it is returned as is.
    - If the input is in the format "username_domain#EXT@tenant", it is converted to "username@domain".
    - If the input is in the format "username@domain", it is returned as is.
    - If the input does not match any of the above formats, a warning is issued and the input is returned as is.

.PARAMETER UserId
    Specifies an array of User Principal Names (UPNs) to be converted to user names.

.EXAMPLE
    PS> Common_0002__Convert-LocalUserIdToUserId.ps1 -UserId "user1@contoso.com", "user2_contoso.com#EXT@tenant.onmicrosoft.com"

    This example converts two UPNs to user names and returns the result.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(mandatory = $true)]
    [Array]$UserId
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$return = [System.Collections.ArrayList]::new($UserId.Count)

$UserId | & {
    process {
        if ($_.GetType().Name -ne 'String') {
            Write-Error "[COMMON]: - Input array UserId contains item of type $($_.GetType().Name)"
            return
        }
        if ([string]::IsNullOrEmpty($_)) {
            Write-Error '[COMMON]: - Input array UserId contains IsNullOrEmpty string'
            return
        }
        switch -Regex ($_) {
            '^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$' {
                [void] $script:return.Add($_)
                break
            }
            "^(.+)_([^_]+\..+)#EXT#@(.+)$" {
                [void] $script:return.Add( "$(($Matches[1]).ToLower())@$(($Matches[2]).ToLower())" )
                break
            }
            '^(.+)@(.+)$' {
                [void] $script:return.Add($_)
                break
            }
            default {
                Write-Warning "[COMMON]: - Could not convert $_ to user name."
                [void] $script:return.Add($_)
                break
            }
        }
    }
}

Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return.ToArray()
