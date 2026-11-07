<#PSScriptInfo
.VERSION 1.0.0
.GUID fda5d103-410a-435c-915d-d79e586ade6d
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
    Version 1.0.0 (2026-11-08)
    - Check the listed app roles and delegated permission scopes, and stop with the missing ones. Before, the runbook checked nothing.
    - Accept the application ID or the object ID of the service principal in AppId, and name a service principal that is not found.
    - Check nothing for a delegated sign-in, because the user's own assignments do not show what the session may do.
    Version 0.0.1 (2024-01-18)
    - Draft release.
    - Added basic structure, but no functionality yet.
#>

<#
.SYNOPSIS
    Validate if the identity of this session has the listed app roles and delegated permission scopes in Microsoft Entra

.DESCRIPTION
    Common runbook that can be used by other runbooks. It can not be started as an Azure Automation job directly.

.PARAMETER Permissions
    Collection of Apps and their desired permissions. A hash object may look like:

    @{
        [System.String]DisplayName = <DisplayName>
        [System.String]AppId = <application ID or object ID of the service principal>
        AppRoles = @(
            'Directory.Read.All'
            'User.Read.All'
        )
        Oauth2PermissionScopes = @{
            Admin = @(
                'offline_access'
                'openid'
                'profile'
            )
            '<User-ObjectId>' = @(
            )
        }
    }

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(mandatory = $true)]
    [Array]$Permissions
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$missingPermissions = [System.Collections.ArrayList]::new()

# The check reads the permissions of the identity itself. A delegated sign-in acts with the roles and consents of the
# user and of the client app instead, which the user's own assignments do not show.
if ((Get-MgContext).AuthType -eq 'Delegated') {
    Write-Verbose '[COMMON]: - Delegated sign-in: app permissions are not checked.'
}
else {
    $AppPermissions = @(./Common_0002__Get-MgAppPermission.ps1 -App @($Permissions | & { process { if ($_.AppId) { $_.AppId } else { $_.DisplayName } } }))

    foreach ($Permission in $Permissions) {
        $AppName = if ($Permission.DisplayName) { $Permission.DisplayName } else { $Permission.AppId }
        # AppId may hold the application ID or the object ID of the service principal.
        $Assigned = $AppPermissions | Where-Object {
            ($Permission.AppId -and ($_.AppId -eq $Permission.AppId -or $_.Id -eq $Permission.AppId)) -or
            (-not $Permission.AppId -and $_.DisplayName -eq $Permission.DisplayName)
        } | Select-Object -First 1

        if ($null -eq $Assigned) {
            [void] $missingPermissions.Add("${AppName}: service principal not found in this tenant")
            continue
        }

        foreach ($AppRole in @($Permission.AppRoles)) {
            if ([string]::IsNullOrEmpty($AppRole)) { continue }
            if (@($Assigned.AppRoles) -notcontains $AppRole) {
                [void] $missingPermissions.Add("${AppName}: app role $AppRole")
            }
        }

        if ($Permission.Oauth2PermissionScopes) {
            foreach ($Principal in $Permission.Oauth2PermissionScopes.Keys) {
                foreach ($Scope in @($Permission.Oauth2PermissionScopes[$Principal])) {
                    if ([string]::IsNullOrEmpty($Scope)) { continue }
                    if (@($Assigned.Oauth2PermissionScopes[$Principal]) -notcontains $Scope) {
                        [void] $missingPermissions.Add("${AppName}: delegated scope $Scope for $Principal")
                    }
                }
            }
        }
    }
}

# Throw an error if there are missing mandatory app permissions
if ($missingPermissions.Count -gt 0) {
    Write-Error "Missing mandatory app permissions of this identity:`n$($missingPermissions -join "`n")`nGrant them to the service principal of this identity, then run the runbook again." -ErrorAction Stop
    exit
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
