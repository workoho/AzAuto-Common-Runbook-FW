<#PSScriptInfo
.VERSION 1.0.0
.GUID 66ac2035-7460-40e8-a4c2-aa7e0816f117
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
    This script retrieves detailed information about the user type based on the provided user object.

.DESCRIPTION
    The script takes an input parameter, UserObject, which represents the user object containing information about the user.
    It then determines various properties of the user, such as whether the user is an internal user, whether the user is authenticated using email OTP, Facebook, Google, Microsoft account, or external Azure AD, whether the user is federated, and the type of guest or external user.

    The resulting hash contains the following properties:
    - IsInternal: Indicates whether the user is an internal user.
    - IsEmailOTPAuthentication: Indicates whether the user is authenticated using email OTP.
    - IsFacebookAccount: Indicates whether the user is authenticated using a Facebook account.
    - IsGoogleAccount: Indicates whether the user is authenticated using a Google account.
    - IsMicrosoftAccount: Indicates whether the user is authenticated using a Microsoft account.
    - IsExternalEntraAccount: Indicates whether the user is authenticated using an external Azure AD account.
    - IsFederated: Indicates whether the user is federated.
    - GuestOrExternalUserType: Indicates the type of guest or external user.

    Each property is determined based on the information present in the UserObject. If a property is not applicable or cannot be determined, it will be set to $null.

.PARAMETER UserObject
    The user object containing information about the user.

.EXAMPLE
    PS> $UserObject = Get-MgUser -UserId 'john.doe@example.com'
    PS> Common_0002__Get-MgUserTypeDetail.ps1 -UserObject $UserObject

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(mandatory = $true)]
    [Object]$UserObject
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
# $StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$return = @{
    IsInternal               = $null
    IsEmailOTPAuthentication = $null
    IsFacebookAccount        = $null
    IsGoogleAccount          = $null
    IsMicrosoftAccount       = $null
    IsExternalEntraAccount   = $null
    IsFederated              = $null
    GuestOrExternalUserType  = $null
}

if (-Not [string]::IsNullOrEmpty($UserObject.Identities)) {
    if (
        (($UserObject.Identities).Issuer -contains 'mail') -or
        (($UserObject.Identities).SignInType -contains 'emailAddress')
    ) {
        Write-Verbose '[COMMON]: - IsEmailOTPAuthentication'
        $return.IsEmailOTPAuthentication = $true
    }
    else {
        $return.IsEmailOTPAuthentication = $false
    }

    if (($UserObject.Identities).Issuer -contains 'facebook.com') {
        Write-Verbose '[COMMON]: - IsFacebookAccount'
        $return.IsFacebookAccount = $true
    }
    else {
        $return.IsFacebookAccount = $false
    }

    if (($UserObject.Identities).Issuer -contains 'google.com') {
        Write-Verbose '[COMMON]: - IsGoogleAccount'
        $return.IsGoogleAccount = $true
    }
    else {
        $return.IsGoogleAccount = $false
    }

    if (($UserObject.Identities).Issuer -contains 'MicrosoftAccount') {
        Write-Verbose '[COMMON]: - IsMicrosoftAccount'
        $return.IsMicrosoftAccount = $true
    }
    else {
        $return.IsMicrosoftAccount = $false
    }

    if (($UserObject.Identities).Issuer -contains 'ExternalAzureAD') {
        Write-Verbose '[COMMON]: - ExternalAzureAD'
        $return.IsExternalEntraAccount = $true
    }
    else {
        $return.IsExternalEntraAccount = $false
    }

    if (
        ($UserObject.Identities).SignInType -contains 'federated'
    ) {
        Write-Verbose '[COMMON]: - IsFederated'
        $return.IsFederated = $true
    }
    else {
        $return.IsFederated = $false
    }
}

if (
    (-Not [string]::IsNullOrEmpty($UserObject.UserType)) -and
    (-Not [string]::IsNullOrEmpty($UserObject.UserPrincipalName))
) {
    if ($UserObject.UserType -eq 'Member') {
        if ($UserObject.UserPrincipalName -notmatch '^.+#EXT#@.+\.onmicrosoft\.com$') {
            $return.GuestOrExternalUserType = 'None'
        }
        else {
            $return.GuestOrExternalUserType = 'b2bCollaborationMember'
        }
    }
    elseif ($UserObject.UserType -eq 'Guest') {
        if ($UserObject.UserPrincipalName -notmatch '^.+#EXT#@.+\.onmicrosoft\.com$') {
            $return.GuestOrExternalUserType = 'internalGuest'
        }
        else {
            $return.GuestOrExternalUserType = 'b2bCollaborationGuest'
        }
    }
    else {
        $return.GuestOrExternalUserType = 'otherExternalUser'
    }
    Write-Verbose "[COMMON]: - GuestOrExternalUserType: $($return.GuestOrExternalUserType)"
}

if (
    ($return.IsEmailOTPAuthentication -eq $false) -and
    ($return.IsFacebookAccount -eq $false) -and
    ($return.IsGoogleAccount -eq $false) -and
    ($return.IsMicrosoftAccount -eq $false) -and
    ($return.IsExternalEntraAccount -eq $false) -and
    ($return.IsFederated -eq $false) -and
    ($return.GuestOrExternalUserType -eq 'None')
) {
    Write-Verbose "[COMMON]: - IsInternal: True"
    $return.IsInternal = $true
}
elseif (
    ($null -ne $return.IsEmailOTPAuthentication) -and
    ($null -ne $return.IsFacebookAccount) -and
    ($null -ne $return.IsGoogleAccount) -and
    ($null -ne $return.IsMicrosoftAccount) -and
    ($null -ne $return.IsExternalEntraAccount) -and
    ($null -ne $return.IsFederated) -and
    ($null -ne $return.GuestOrExternalUserType)
) {
    Write-Verbose "[COMMON]: - IsInternal: False"
    $return.IsInternal = $false
}
else {
    Write-Warning "[COMMON]: - IsInternal: UNKNOWN"
}

# Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
