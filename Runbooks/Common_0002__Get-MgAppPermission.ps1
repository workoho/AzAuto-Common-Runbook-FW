<#PSScriptInfo
.VERSION 0.1.0
.GUID b39dc20f-f5de-4f6b-958e-41762df89805
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
    Version 0.1.0 (2026-11-08)
    - Read every page of the app role assignments and permission grants, and stop on a failed read instead of returning nothing.
    - Return the object ID of each application as well.
    Version 0.0.4 (2026-11-08)
    - Keep the caller's variables when cleaning up. Before, the cleanup removed variables with the AllScope option, such as $HOME, for the whole session.
    Version 0.0.3 (2024-06-18)
    - Initial draft.
#>

<#
.SYNOPSIS
    Retrieves the application permissions and OAuth2 permission scopes for the specified applications.

.DESCRIPTION
    This script retrieves the application permissions and OAuth2 permission scopes for the specified applications.

.PARAMETER App
    Specifies the applications for which to retrieve the permissions and scopes. If not specified, all applications
    associated with the user or service principal will be considered.

.EXAMPLE
    PS> Get-MgAppPermission -App 'MyApp1', 'MyApp2'

    Retrieves the permissions and scopes for the applications 'MyApp1' and 'MyApp2'.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Array]$App
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

# Reads every page of a collection. A failed read throws, so that it is not taken for an empty collection.
function Get-MgCollection ([string] $Uri) {
    $items = [System.Collections.ArrayList]::new()
    while ($Uri) {
        $page = Invoke-MgGraphRequest -Uri $Uri -ErrorAction Stop -Verbose:$false
        if ($page.value) { [void] $items.AddRange(@($page.value)) }
        $Uri = $page.'@odata.nextLink'
    }
    $items
}

try {
    $return = [System.Collections.ArrayList]::new()

    $PrincipalPath = if ((Get-MgContext).AuthType -eq 'Delegated') { 'users' } else { 'servicePrincipals' }
    $AppRoleAssignments = @(Get-MgCollection "/v1.0/$PrincipalPath/$($env:MG_PRINCIPAL_ID)/appRoleAssignments")
    $PermissionGrants = @(Get-MgCollection "/v1.0/$PrincipalPath/$($env:MG_PRINCIPAL_ID)/oauth2PermissionGrants")

    if ($null -eq $App) {
        $Apps = [System.Collections.ArrayList]::new()
        foreach ($Item in $AppRoleAssignments) {
            [void] $Apps.Add($Item.ResourceId)
        }
    }
    else {
        $Apps = $App | Select-Object -Unique
    }

    foreach ($Item in $Apps) {
        $DisplayName = $null
        $AppId = $null
        $AppResource = $null

        if ($Item -is [String]) {
            if ($Item -match '^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$') {
                $AppId = $Item
            }
            else {
                $DisplayName = $Item
            }
        }
        elseif ($Item.AppId) {
            $AppId = $Item.AppId
        }
        elseif ($Item.DisplayName) {
            $DisplayName = $Item.DisplayName
        }

        if ($AppId) {
            $AppResource = @((Invoke-MgGraphRequest -Uri "/v1.0/servicePrincipals?`$filter=servicePrincipalType eq 'Application' and (id eq '$($AppId)' or appId eq '$($AppId)')" -Verbose:$false).value)
        }
        elseif ($DisplayName) {
            $AppResource = @((Invoke-MgGraphRequest -Uri "/v1.0/servicePrincipals?`$filter=servicePrincipalType eq 'Application' and displayName eq '$($DisplayName)'" -Verbose:$false).value)
        }

        if (-Not $AppResource) {
            Write-Warning "[COMMON]: - Unable to find application: $DisplayName $(if ($AppId) { $AppId })"
            continue
        }

        $AppRoles = [System.Collections.ArrayList]::new()
        if ($AppRoleAssignments) {
            foreach ($appRoleId in (($AppRoleAssignments | Where-Object resourceId -eq $AppResource.id).appRoleId | Select-Object -Unique)) {
                [void] $AppRoles.Add(($AppResource.appRoles | Where-Object id -eq $appRoleId).value)
            }
        }

        $Oauth2PermissionScopes = @{}
        if ($PermissionGrants) {
            foreach ($Permissions in ($PermissionGrants | Where-Object resourceId -eq $AppResource.id)) {
                foreach ($Permission in $Permissions) {
                    $PrincipalTypeName = 'Admin'
                    if ($Permission.consentType -ne 'AllPrincipals') {
                        $PrincipalTypeName = $Permission.principalId
                    }
                    $Permission.scope.Trim() -split ' ' | ForEach-Object {
                        if (-Not $Oauth2PermissionScopes.$PrincipalTypeName) {
                            $Oauth2PermissionScopes.$PrincipalTypeName = [System.Collections.ArrayList]::new()
                        }
                        [void] ($Oauth2PermissionScopes.$PrincipalTypeName).Add($_)
                    }
                }
            }
        }

        [void] $return.Add(
            @{
                Id                     = $AppResource.id
                AppId                  = $AppResource.appId
                DisplayName            = $AppResource.displayName
                AppRoles               = $AppRoles
                Oauth2PermissionScopes = $Oauth2PermissionScopes
            }
        )
    }
}
catch {
    Throw $_
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name -and $_.Name -ne 'return' } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
