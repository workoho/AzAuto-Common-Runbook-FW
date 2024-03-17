<#PSScriptInfo
.VERSION 1.0.0
.GUID c2401e63-ecea-4895-b13a-7b63340215fd
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
    This script checks if Azure role assignments are active for the current user.

.DESCRIPTION
    This script is used to validate Azure role assignments for the current user.
    It checks if the roles are assigned directly to the current user or if they are assigned transitively through groups.

    Also, it checks if the requested roles are included in other higher roles through the role hierarchy.
    For example, when Reader role is requested, Contributor and Owner roles are also checked.

    If any mandatory roles are missing, an error is thrown.

.PARAMETER Roles
    The Roles parameter specifies the roles to be checked.
    It should be a hashtable where the keys represent the scope and the values represent the role definitions.
    The role definitions can be specified either by RoleDefinitionId or DisplayName.
    Multiple roles can be specified for the same scope by using an array of role definitions.

.EXAMPLE
    PS> Common_0003__Confirm-AzRoleActiveAssignment.ps1 -Roles @{
            '/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/MyResourceGroup/providers/Microsoft.Storage/storageAccounts/MyStorageAccount' = 'Storage Account Contributor'
            '/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/MyResourceGroup/providers/Microsoft.Web/sites/MyWebApp' = @{
                DisplayName = 'Contributor'
                Optional = $true
            }
            '/subscriptions/12345678-1234-1234-1234-1234567890ab/resourceGroups/MyResourceGroup/providers/Microsoft.Web/sites/MyWebApp' = @{
                RoleDefinitionId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
            }
        }
#>

[CmdletBinding()]
Param(
    [Parameter(mandatory = $true)]
    [object]$Roles
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

./Common_0001__Connect-MgGraph.ps1 -TenantId (Get-AzContext).Tenant.Id

$missingRoles = [System.Collections.ArrayList]::new()
$currentUser = Get-AzADUser -SignedIn
$currentUserGroups = (Get-MgUserTransitiveMemberOf -UserId $currentUser.Id).Id
$return = @{}
$cache = @{}

$roleHierarchy = [ordered]@{
    'Automation Job Operator' = @{
        Id       = '4fe576fe-1146-4730-92eb-48519fa6bf9f'
        Includes = @(
            @{ Id = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'; DisplayName = 'Reader' }
            @{ Id = '5fb5aef8-1081-4b8e-bb16-9d5d0385bab5'; DisplayName = 'Automation Runbook Operator' }
        )
        Excludes = @()
    }
    'Automation Operator'     = @{
        Id       = 'd3881f73-407a-4167-8283-e981cbba0404'
        Includes = @(
            @{ Id = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'; DisplayName = 'Reader' }
            @{ Id = '5fb5aef8-1081-4b8e-bb16-9d5d0385bab5'; DisplayName = 'Automation Runbook Operator' }
            @{ Id = '4fe576fe-1146-4730-92eb-48519fa6bf9f'; DisplayName = 'Automation Job Operator' }
        )
        Excludes = @()
    }
    'Automation Contributor'  = @{
        Id       = 'f353d9bd-d4a6-484e-a77a-8050b599b867'
        Includes = @(
            @{ Id = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'; DisplayName = 'Reader' }
            @{ Id = '4fe576fe-1146-4730-92eb-48519fa6bf9f'; DisplayName = 'Automation Job Operator' }
            @{ Id = 'd3881f73-407a-4167-8283-e981cbba0404'; DisplayName = 'Automation Operator' }
            @{ Id = '5fb5aef8-1081-4b8e-bb16-9d5d0385bab5'; DisplayName = 'Automation Runbook Operator' }
        )
        Excludes = @()
    }
    Contributor               = @{
        Id       = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
        Includes = @(
            @{ Id = '*'; DisplayName = 'AllOtherRoles' }
        )
        Excludes = @(
            @{ Id = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'; DisplayName = 'Role Based Access Control Administrator' }
            @{ Id = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'; DisplayName = 'User Access Administrator' }
        )
    }
    Owner                     = @{
        Id       = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        Includes = @(
            @{ Id = '*'; DisplayName = 'AllOtherRoles' }
        )
        Excludes = @()
    }
}

# Loop through each role and check if it is assigned or missing
$Roles.GetEnumerator() | & {
    process {
        $Scope = $_.Key
        $return[$Scope] = New-Object System.Collections.ArrayList
        $ScopeRoles = if ($_.Value -is [string[]] -or $_.Value -is [array] -or $_.Value -is [System.Collections.ArrayList]) { $_.Value } elseif ($_.Value -is [string]) { @($_.Value) } else {
            Write-Error "Invalid type for Azure role definition: $($_.Value.GetType().Name)" -ErrorAction Stop
            exit
        }

        $ScopeRoles | & {
            process {
                $Role = if ($_ -is [hashtable]) {
                    $_
                }
                elseif ($_ -is [string]) {
                    if ($_ -match '^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$') {
                        @{ RoleDefinitionId = $_ }
                    }
                    else {
                        @{ DisplayName = $_ }
                    }
                }
                else {
                    Write-Error "Invalid type for Azure role definition: $($_.GetType().Name)" -ErrorAction Stop
                    exit
                }

                if ($null -eq $cache[$Scope]) { $cache[$Scope] = Get-AzRoleAssignment -Scope $Scope -ErrorAction SilentlyContinue }

                $found = $cache[$Scope] | Where-Object {
                    $_.ObjectType -eq 'User' -and
                    $_.ObjectId -eq $currentUser.Id -and (
                        ($_.RoleDefinitionId -eq $Role.RoleDefinitionId) -or
                        ($_.RoleDefinitionName -eq $Role.DisplayName)
                    )
                }
                if ($found) {
                    Write-Verbose "[COMMON]: - Confirmed direct Azure role assignment: $($Role.DisplayName) ($($Role.RoleDefinitionId)), Scope: $Scope"
                    [void] $return[$Scope].Add($found)
                    return
                }

                $found = $cache[$Scope] | Where-Object {
                    $_.ObjectType -eq 'Group' -and
                    $currentUserGroups -contains $_.ObjectId -and (
                        ($_.RoleDefinitionId -eq $Role.RoleDefinitionId) -or
                        ($_.RoleDefinitionName -eq $Role.DisplayName)
                    )
                }
                if ($found) {
                    Write-Verbose "[COMMON]: - Confirmed transitive Azure role assignment: $($Role.DisplayName) ($($Role.RoleDefinitionId)), Scope: $Scope"
                    [void] $return[$Scope].Add($found)
                    return
                }
                else {
                    # Check if the role is included in one of the $roleHierarchy roles above it
                    $higherRoles = $null
                    if ($null -ne $Role.RoleDefinitionId) {
                        $higherRoles = $roleHierarchy.GetEnumerator() | Where-Object { ($_.Value.Includes.Id -contains $Role.RoleDefinitionId -or $_.Value.Includes.Id -contains '*') -and $_.Value.Excludes.Id -notcontains $Role.RoleDefinitionId }
                    }
                    if (-not $higherRoles -and $null -ne $Role.DisplayName) {
                        $higherRoles = $roleHierarchy.GetEnumerator() | Where-Object { ($_.Value.Includes.DisplayName -contains $Role.DisplayName -or $_.Value.Includes.DisplayName -contains 'AllOtherRoles') -and $_.Value.Excludes.DisplayName -notcontains $Role.DisplayName }
                    }

                    foreach ($entry in $higherRoles) {
                        $higherRoleDisplayName, $higherRole = $entry.Key, $entry.Value
                        Write-Verbose "[COMMON]: - Checking for higher Azure role assignment: $($higherRoleDisplayName) ($($higherRole.Id)), Scope: $Scope"

                        $found = $cache[$Scope] | Where-Object {
                            $_.ObjectType -eq 'User' -and
                            $_.ObjectId -eq $currentUser.Id -and (
                                ($_.RoleDefinitionId -eq $higherRole.Id) -or
                                ($_.RoleDefinitionName -eq $higherRoleDisplayName)
                            )
                        }
                        if ($found) {
                            Write-Verbose "[COMMON]: - Confirmed higher direct Azure role assignment: $($higherRoleDisplayName) ($($higherRole.Id)), Scope: $Scope"
                            [void] $return[$Scope].Add($found)
                            return
                        }

                        $found = $cache[$Scope] | Where-Object {
                            $_.ObjectType -eq 'Group' -and
                            $currentUserGroups -contains $_.ObjectId -and (
                                ($_.RoleDefinitionId -eq $higherRole.Id) -or
                                ($_.RoleDefinitionName -eq $higherRoleDisplayName)
                            )
                        }
                        if ($found) {
                            Write-Verbose "[COMMON]: - Confirmed higher transitive Azure role assignment: $($higherRoleDisplayName) ($($higherRole.Id)), Scope: $Scope"
                            [void] $return[$Scope].Add($found)
                            return
                        }
                    }

                    if ($Role.Optional) {
                        Write-Verbose "[COMMON]: - Missing optional Azure role assignment: $($Role.DisplayName) ($($Role.RoleDefinitionId)), Scope: $Scope"
                    }
                    else {
                        [void] $missingRoles.Add(@{ Scope = $Scope; RoleDefinitionId = $Role.RoleDefinitionId; DisplayName = $Role.DisplayName })
                    }
                }
            }
        }
    }
}

# Throw an error if there are missing mandatory active Azure role assignments
if ($missingRoles.Count -gt 0) {
    Write-Error "Missing mandatory Azure role permissions:`n$($missingRoles | ConvertTo-Json)" -ErrorAction Stop
    exit
}

# Cleanup variables at the end of the script
Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
