<#PSScriptInfo
.VERSION 1.0.0
.GUID a71f281b-4d20-4829-a814-18baff4dade7
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
    This script validates if the current user has active assignments of the listed roles in Microsoft Entra ID.

.DESCRIPTION
    The script checks if the specified directory roles are assigned or missing in the Entra ID. It also verifies if the script is running with the required permissions and provides warnings or errors accordingly.

.PARAMETER Roles
    Specifies an array of directory roles to be checked.
    Could be a mix of role display names, role template IDs, or complex hash objects.
    A hash object may look like:

    @{
        roleTemplateId = <roleTemplateId>
        DisplayName = <DisplayName>
        optional = <[System.Boolean]>
    }

    Optional roles are not required to be assigned. If an optional role is missing, the script will not throw an exception.
    As a default, all roles are mandatory and missing roles will throw an exception.

.PARAMETER AllowGlobalAdministratorInAzureAutomation
    Specifies whether running the script with Global Administrator permissions in Azure Automation is allowed. Default is $false.

.PARAMETER AllowPrivilegedRoleAdministratorInAzureAutomation
    Specifies whether running the script with Privileged Role Administrator permissions in Azure Automation is allowed. Default is $false.

.PARAMETER AllowSuperseededRoleWithDirectoryScope
    Specifies whether superseeded roles with a directory scope are allowed. Default is $true.
    When set to $false, the script will throw an exception if a role is missing in a directory scope. If the same role is assigned in the root directory scope, it will be ignored.
    That way, when a role with a directory scope is requested, it must be assigned in the requested directory scope as well.

.EXAMPLE
    PS> Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 -Roles @( @{ TemplateId = '62e90394-69f5-4237-9190-012177145e10'; DisplayName = 'Global Administrator' }, 'Privileged Role Administrator' )

    This example confirms the active assignments of the "Global Administrator" and "Privileged Role Administrator" directory roles.
#>

[CmdletBinding()]
Param(
    [Parameter(mandatory = $true)]
    [Array]$Roles,

    [Boolean]$AllowGlobalAdministratorInAzureAutomation = $false,
    [Boolean]$AllowPrivilegedRoleAdministratorInAzureAutomation = $false,
    [Boolean]$AllowSuperseededRoleWithDirectoryScope = $true
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$missingRoles = [System.Collections.ArrayList]::new()
$return = ./Common_0002__Get-MgDirectoryRoleActiveAssignment.ps1
$GlobalAdmin = $return | Where-Object { $_.RoleDefinition.TemplateId -eq '62e90394-69f5-4237-9190-012177145e10' }
$PrivRoleAdmin = $return | Where-Object { $_.RoleDefinition.TemplateId -eq 'e8611ab8-c189-46e8-94e1-60213ab1f814' }

# Check if running with Global Administrator permissions in Azure Automation
if ($GlobalAdmin) {
    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        if (-Not $AllowGlobalAdministratorInAzureAutomation) {
            Write-Error 'Running this script with Global Administrator permissions in Azure Automation is prohibited.' -ErrorAction Stop
            exit
        }
        Write-Warning '[COMMON]: - Runbooks running with Global Administrator permissions in Azure Automation is a HIGH RISK!' -Verbose -WarningAction Continue
    }
    else {
        Write-Warning '[COMMON]: - Running with Global Administrator permissions: You should reconsider following the principle of least privilege.' -Verbose -WarningAction Continue
    }

    # Check if running with active Global Administrator permissions
    if (-Not $AllowGlobalAdministratorInAzureAutomation -and
        -Not (
            $Roles | Where-Object {
                (
                    ($_.GetType().Name -eq 'String') -and
                    $_ -eq 'Global Administrator'
                ) -or
                (
                    ($_.GetType().Name -ne 'String') -and
                    (
                        ($_.TemplateId -eq '62e90394-69f5-4237-9190-012177145e10') -or
                        ($_.DisplayName -eq 'Global Administrator')
                    )
                )
            }
        )
    ) {
        Write-Warning '[COMMON]: - +++ATTENTION+++ Running with active Global Administrator permissions, but it was not explicitly requested by the script!' -Verbose -WarningAction Continue
    }
}

# Check if running with Privileged Role Administrator permissions in Azure Automation
if ($PrivRoleAdmin) {
    if ('AzureAutomation/' -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
        if (-Not $AllowPrivilegedRoleAdministratorInAzureAutomation) {
            Write-Error 'Running this script with Privileged Role Administrator permissions in Azure Automation is prohibited.' -ErrorAction Stop
            exit
        }
        Write-Verbose '[COMMON]: - WARNING: Runbooks running with Privileged Role Administrator permissions in Azure Automation is a HIGH RISK!' -Verbose
    }

    # Check if running with active Privileged Role Administrator permissions
    if (-Not $AllowPrivilegedRoleAdministratorInAzureAutomation -and
        -Not (
            $Roles | Where-Object {
                (
                    ($_.GetType().Name -eq 'String') -and
                    $_ -eq 'Privileged Role Administrator'
                ) -or
                (
                    ($_.GetType().Name -ne 'String') -and
                    (
                        ($_.TemplateId -eq 'e8611ab8-c189-46e8-94e1-60213ab1f814') -or
                        ($_.DisplayName -eq 'Privileged Role Administrator')
                    )
                )
            }
        )
    ) {
        Write-Warning '[COMMON]: - +++ATTENTION+++ Running with active Privileged Role Administrator permissions, but it was not explicitly requested by the script!' -Verbose -WarningAction Continue
    }
}

# Loop through each role and check if it is assigned or missing
foreach (
    $Item in (
        # Roles may either be defined by a simple string, or hash.
        # Make this array containing unique role definitions only.
        $Roles | Group-Object -Property { $_.GetType().Name } | ForEach-Object {
            if ($_.Name -eq 'String') {
                $_.Group | Select-Object -Unique
            }
            else {
                $_.Group | Group-Object -Property DisplayName, TemplateId, DirectoryScopeId | ForEach-Object {
                    $_.Group[0]
                }
            }
        }
    )
) {
    $DirectoryScopeId = if ($Item -is [String]) { '/' } elseif ($Item.DirectoryScopeId) { $Item.DirectoryScopeId } else { '/' }
    $TemplateId = if ($Item -is [String]) { if ($Item -match '^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$') { $Item } else { $null } } else { $Item.TemplateId }
    $DisplayName = if ($Item -is [String]) { if ($Item -notmatch '^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$') { $Item } else { $null } } else { $Item.DisplayName }
    $Optional = if ($Item -is [String]) { $false } else { $Item.Optional }
    $AssignedRole = $return | Where-Object { ($_.DirectoryScopeId -eq $DirectoryScopeId) -and (($_.RoleDefinition.TemplateId -eq $TemplateId) -or ($_.RoleDefinition.DisplayName -eq $DisplayName)) }
    $superseededRole = $false
    if (-Not $AssignedRole -and $DirectoryScopeId -ne '/' -and $AllowSuperseededRoleWithDirectoryScope) {
        $superseededRole = $true
        $AssignedRole = $return | Where-Object { ($_.DirectoryScopeId -eq '/') -and (($_.RoleDefinition.TemplateId -eq $TemplateId) -or ($_.RoleDefinition.DisplayName -eq $DisplayName)) }
    }
    if ($AssignedRole) {
        if ($superseededRole) {
            Write-Warning "[COMMON]: - Superseeded directory role by root directory scope: $($AssignedRole.RoleDefinition.DisplayName) ($($AssignedRole.RoleDefinition.TemplateId)), Directory Scope: $($AssignedRole.DirectoryScopeId). You might want to reduce permission scope to Administrative Unit $DirectoryScopeId only."
        }
        else {
            Write-Verbose "[COMMON]: - Confirmed directory role: $($AssignedRole.RoleDefinition.DisplayName) ($($AssignedRole.RoleDefinition.TemplateId)), Directory Scope: $($AssignedRole.DirectoryScopeId)"
        }
    }
    else {
        if ($Optional) {
            Write-Verbose "[COMMON]: - Missing optional directory role permission: $DisplayName $(if ($TemplateId -and ($TemplateId -ne $DisplayName)) { "($TemplateId)" }), Directory Scope: $DirectoryScopeId"
        }
        elseif ($GlobalAdmin -and $DirectoryScopeId -ne '/') {
            Write-Warning "[COMMON]: - Missing scoped directory role permission: $DisplayName $(if ($TemplateId -and ($TemplateId -ne $DisplayName)) { "($TemplateId)" }), Directory Scope: $DirectoryScopeId"
        }
        elseif ($GlobalAdmin) {
            Write-Warning "[COMMON]: - Superseeded directory role by active Global Administrator: $DisplayName $(if ($TemplateId -and ($TemplateId -ne $DisplayName)) { "($TemplateId)" }), Directory Scope: $DirectoryScopeId"
        }
        else {
            [void] $missingRoles.Add(@{ DirectoryScopeId = $DirectoryScopeId; TemplateId = $TemplateId; DisplayName = $DisplayName })
        }
    }
}

# Throw an error if there are missing mandatory directory role permissions
if ($missingRoles.Count -gt 0) {
    Write-Error "Missing mandatory directory role permissions:`n$($missingRoles | ConvertTo-Json)" -ErrorAction Stop
    exit
}

# Cleanup variables at the end of the script
Get-Variable | Where-Object { $StartupVariables -notcontains @($_.Name, 'return') } | ForEach-Object { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false }
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
return $return
