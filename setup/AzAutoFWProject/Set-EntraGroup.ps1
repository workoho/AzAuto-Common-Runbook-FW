<#PSScriptInfo
.VERSION 1.0.0
.GUID 3126245a-3628-4290-b364-8d33c55b2a1c
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
    This script sets up groups in the Microsoft Entra tenant of the Azure Automation Account.

.DESCRIPTION
    This script is used to create groups in the Microsoft Entra tenant of the Azure Automation Account.

.PARAMETER Group
    The name or ID of the group to be created or updated.
#>

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'High'
)]
Param(
    [array]$Group
)

if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    Write-Error 'This script must be run interactively by a privileged administrator account.' -ErrorAction Stop
    exit
}
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

Write-Host "`n`nGroup Setup`n===========`n" -ForegroundColor White

#region Read Project Configuration
$config = $null
$configScriptPath = Join-Path (Get-Item $PSScriptRoot).Parent.Parent.FullName (Join-Path 'scripts' (Join-Path 'AzAutoFWProject' 'Get-AzAutoFWConfig.ps1'))
if (
    (Test-Path $configScriptPath -PathType Leaf) -and
    (
        ((Get-Item $configScriptPath).LinkType -ne "SymbolicLink") -or
        (
            Test-Path -LiteralPath (
                Resolve-Path -Path (
                    Join-Path -Path (Split-Path $configScriptPath) -ChildPath (
                        Get-Item -LiteralPath $configScriptPath | Select-Object -ExpandProperty Target
                    )
                )
            ) -PathType Leaf
        )
    )
) {
    if ($commonBoundParameters) {
        $config = & $configScriptPath @commonBoundParameters
    }
    else {
        $config = & $configScriptPath
    }
}
else {
    Write-Error 'Project configuration incomplete: Run ./scripts/Update-AzAutoFWProject.ps1 first.' -ErrorAction Stop
    exit
}

@(
    'Group'
) | & {
    process {
        if ([string]::IsNullOrEmpty($config.$_)) {
            Write-Error "Mandatory property '/PrivateData/$_' is missing or null in the AzAutoFWProject.psd1 configuration file." -ErrorAction Stop
            exit
        }
    }
}
#endregion

#region Connect to Microsoft Graph
try {
    Push-Location
    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
    $connectParams = @{
        Tenant = $config.local.AutomationAccount.TenantId
        Scopes = @(
            'Group.Read.All'
        )
    }
    .\Common_0001__Connect-MgGraph.ps1 @connectParams
}
catch {
    Write-Error "Insufficent Microsoft Graph permissions: Scope 'Group.Read.All' is required to continue validation of groups. Further permissions may be required to perform changes."
    exit
}
finally {
    Pop-Location
}
#endregion

if ($null -eq $config.Group -or $config.Group.Count -eq 0) {
    Write-Verbose "No group definitions found in the project configuration. Exiting..."
    exit
}

$ConfirmedMgPermission = $false
$ConfirmedMgPermissionPrivileged = $false
$ConfirmedEntraPermission = $false
$ConfirmedEntraPermissionPrivileged = $false
$TenantSubscriptions = $null

$config.Group.GetEnumerator() | Sort-Object -Property { $_.Value.DisplayName }, { $_.Name } | & {
    process {
        $configValue = $_.Value

        $currentValue = $null
        if (-not [string]::IsNullOrEmpty($configValue.Id)) {
            if ($Group -and $Group -notcontains $configValue.Id) { return }
            Write-Verbose "Searching for group with ID '$($configValue.Id)'"
            $currentValue = Get-MgGroup -GroupId $configValue.Id -ErrorAction SilentlyContinue
        }
        elseif (-not [string]::IsNullOrEmpty($configValue.DisplayName)) {
            if ($Group -and $Group -notcontains $configValue.DisplayName) { return }
            Write-Verbose "Searching for group display name '$($configValue.DisplayName)'"
            $currentValue = Get-MgGroup -Filter "displayName eq '$($configValue.DisplayName)'" -ErrorAction SilentlyContinue
            if ($currentValue.Count -gt 1) {
                Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                Write-Host "$($configValue.DisplayName)"
                Write-Error "Multiple groups found with the same name '$($configValue.DisplayName)'. Please ensure that the group names are unique, or add Object ID to configuration." -ErrorAction Stop
                return
            }
        }
        else {
            Write-Error "Mandatory property 'Id' or 'DisplayName' is missing or null in the group definition '$($_.Key)'."
            return
        }

        if ($null -ne $configValue.MembershipRule) {
            Write-Verbose " Removing common leading whitespace from the membership rule."
            $minLeadingWhitespaces = $configValue.MembershipRule -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { ($_ -match '^(\s*)' | Out-Null); $matches[1].Length } | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
            $configValue.MembershipRule = [System.Text.RegularExpressions.Regex]::Replace($configValue.MembershipRule, "^[\s]{0,$minLeadingWhitespaces}", '', 'Multiline')
        }

        if ($null -ne $configValue.AdministrativeUnit -and $configValue.AdministrativeUnit -is [hashtable]) {
            if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName) -and [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {
                Write-Error "Administrative unit reference for group '$($configValue.DisplayName)' must have a 'DisplayName' or 'Id' property in configuration." -ErrorAction Stop
                return
            }
            try {
                $adminUnit = $null
                if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {
                    $adminUnit = Get-MgBetaAdministrativeUnit -Filter "displayName eq '$($configValue.AdministrativeUnit.DisplayName)'" -ErrorAction Stop
                }
                else {
                    $adminUnit = Get-MgBetaAdministrativeUnit -AdministrativeUnitId $configValue.AdministrativeUnit.Id -ErrorAction Stop
                }
                if ($adminUnit.Count -gt 1) {
                    Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                    Write-Host "$($configValue.DisplayName) (Id: n/a$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))"
                    Write-Error "Multiple administrative units found with the same name '$($configValue.AdministrativeUnit.DisplayName)'. Please ensure that the administrative unit names are unique, or add Object ID to configuration."
                    return
                }
                $configValue.AdministrativeUnit = $adminUnit
                Write-Verbose " Found Administrative Unit for group: $($configValue.AdministrativeUnit.DisplayName) ($($configValue.AdministrativeUnit.Id))"
            }
            catch {
                Write-Error "Administrative unit '$($configValue.AdministrativeUnit.DisplayName)' for group '$($configValue.DisplayName)' not found." -ErrorAction Stop
                return
            }
        }

        if ($null -eq $currentValue) {
            Write-Host "    (Missing) " -NoNewline -ForegroundColor White
            Write-Host "$($configValue.DisplayName)" -NoNewline
            Write-Host "$($configValue.DisplayName) (Id: n/a$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))" -NoNewline
            Write-Host $(if ([string]::IsNullOrEmpty($configValue.Description)) { '' } else { "`n              $($configValue.Description)" }) -ForegroundColor DarkGray

            if ($PSCmdlet.ShouldProcess(
                    "Create Group '$($configValue.DisplayName)' in $(if ($null -ne $configValue.AdministrativeUnit -and -not [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {"administrative unit '$($configValue.AdministrativeUnit.DisplayName)' of "})tenant $($config.local.AutomationAccount.TenantId) ?",
                    "Do you confirm to create Group '$($configValue.DisplayName)' in $(if ($null -ne $configValue.AdministrativeUnit -and -not [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {"administrative unit '$($configValue.AdministrativeUnit.DisplayName)' of "})tenant $($config.local.AutomationAccount.TenantId) ?",
                    "Create Groups in tenant $($config.local.AutomationAccount.TenantId)"
                )) {

                if ($null -ne $configValue.AdministrativeUnit -and -not [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {
                    #region Connect to Microsoft Graph
                    try {
                        Push-Location
                        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                        $connectParams = @{
                            Tenant = $config.local.AutomationAccount.TenantId
                            Scopes = @(
                                'Group.ReadWrite.All'
                            )
                        }
                        if ($configValue.AdministrativeUnit.IsMemberManagementRestricted) { $connectParams.Scopes += 'Directory.Write.Restricted' }
                        if (-not $ConfirmedMgPermissionPrivileged) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermissionPrivileged = $true }
                    }
                    catch {
                        Write-Error "Insufficent Microsoft Graph permissions: $(if ($connectParams.Scopes.Count -gt 1) { "Scopes $(($connectParams.Scopes | ForEach-Object {"'$_'"}) -join ', ') are" } else { "Scope '$($connectParams.Scopes[0])' is" }) required to continue setup of groups within administrative units in Microsoft Entra."
                        exit
                    }
                    finally {
                        Pop-Location
                    }
                    #endregion

                    #region Required Microsoft Entra Directory Permissions Validation --------------
                    try {
                        Push-Location
                        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                        $confirmParams = @{
                            AllowGlobalAdministratorInAzureAutomation         = $true
                            AllowPrivilegedRoleAdministratorInAzureAutomation = $true
                            AllowSuperseededRoleWithDirectoryScope            = if ($configValue.AdministrativeUnit.IsMemberManagementRestricted) { $false } else { $true }
                            Roles                                             = @(
                                @{
                                    DisplayName      = 'Groups Administrator'
                                    TemplateId       = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'
                                    DirectoryScopeId = "/administrativeUnits/$($configValue.AdministrativeUnit.Id)"
                                }
                            )
                        }
                        if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                        $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams
                    }
                    catch {
                        Write-Error "Insufficent Microsoft Entra permissions: $(if ($configValue.AdministrativeUnit.IsMemberManagementRestricted) {'Explicit'} else {'At lest'}) 'Groups Administrator' directory role with scope to administrative unit '$($configValue.AdministrativeUnit.DisplayName)' is required to setup groups in Microsoft Entra." -ErrorAction Stop
                        exit
                    }
                    finally {
                        Pop-Location
                    }

                    if ($configValue.IsAssignableToRole) {
                        try {
                            Push-Location
                            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                            $confirmParams = @{
                                AllowGlobalAdministratorInAzureAutomation         = $true
                                AllowPrivilegedRoleAdministratorInAzureAutomation = $true
                                Roles                                             = @(
                                    @{
                                        DisplayName = 'Privileged Role Administrator'
                                        TemplateId  = '18d7d88d-d35e-4f0c-8f3a-3f5f454d3e3e'
                                    }
                                )
                            }
                            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                            if (-not $ConfirmedEntraPermissionPrivileged) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermissionPrivileged = $true }
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Entra permissions: 'Privileged Role Administrator' directory role is required to setup role-assignable groups in Microsoft Entra." -ErrorAction Stop
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                    }
                    #endregion

                }
                else {
                    #region Connect to Microsoft Graph
                    try {
                        Push-Location
                        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                        $connectParams = @{
                            Tenant = $config.local.AutomationAccount.TenantId
                            Scopes = @(
                                'Group.ReadWrite.All'
                            )
                        }
                        if (-not $ConfirmedMgPermission) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermission = $true }
                    }
                    catch {
                        Write-Error "Insufficent Microsoft Graph permissions: Scope 'Group.ReadWrite.All' is required to continue setup of groups in Microsoft Entra."
                        exit
                    }
                    finally {
                        Pop-Location
                    }
                    #endregion

                    #region Required Microsoft Entra Directory Permissions Validation --------------
                    if ($configValue.IsAssignableToRole) {
                        try {
                            Push-Location
                            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                            $confirmParams = @{
                                AllowGlobalAdministratorInAzureAutomation         = $true
                                AllowPrivilegedRoleAdministratorInAzureAutomation = $true
                                Roles                                             = @(
                                    @{
                                        DisplayName = 'Privileged Role Administrator'
                                        TemplateId  = '18d7d88d-d35e-4f0c-8f3a-3f5f454d3e3e'
                                    }
                                )
                            }
                            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                            if (-not $ConfirmedEntraPermissionPrivileged) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermissionPrivileged = $true }
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Entra permissions: 'Privileged Role Administrator' directory role is required to setup role-assignable groups in Microsoft Entra." -ErrorAction Stop
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                    }
                    else {
                        try {
                            Push-Location
                            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                            $confirmParams = @{
                                AllowGlobalAdministratorInAzureAutomation         = $true
                                AllowPrivilegedRoleAdministratorInAzureAutomation = $true
                                AllowSuperseededRoleWithDirectoryScope            = $true
                                Roles                                             = @(
                                    @{
                                        DisplayName      = 'Groups Administrator'
                                        TemplateId       = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'
                                        DirectoryScopeId = '/'
                                    }
                                )
                            }
                            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                            if (-not $ConfirmedEntraPermission) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermission = $true }
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Entra permissions: At least 'Groups Administrator' directory role is required to setup groups in Microsoft Entra." -ErrorAction Stop
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                    }
                    #endregion
                }

                try {
                    $params = @{
                        OutputType = 'PSObject'
                        Method     = 'POST'
                        Uri        = $(
                            if ($null -ne $configValue.AdministrativeUnit -and -not [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {
                                "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($configValue.AdministrativeUnit.Id)/members"
                            }
                            else {
                                "https://graph.microsoft.com/v1.0/groups"
                            }
                        )
                        Body       = $configValue.Clone()
                    }
                    if ($null -ne $configValue.AdministrativeUnit -and -not [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {
                        $params.Body.'@odata.type' = '#Microsoft.Graph.Group'
                    }
                    if ([string]::IsNullOrEmpty($params.Body.MailNickname)) {
                        $params.Body.MailNickname = (New-Guid).Guid.Substring(0, 10)
                        Write-Verbose " Property 'MailNickname' has been auto-generated: '$($params.Body.MailNickname)'."
                    }
                    $params.Body.Remove('Id')
                    $params.Body.Remove('AdministrativeUnit')
                    $params.Body.Remove('InitialLicenseAssignment')
                    if ($commonBoundParameters) { $params += $commonBoundParameters }
                    $currentValue = Invoke-MgGraphRequest @params
                    Write-Host "    (Ok)      " -NoNewline -ForegroundColor Green
                    Write-Host "$($currentValue.DisplayName) (Id: $($currentValue.Id)$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))"
                }
                catch {
                    Write-Error "$_" -ErrorAction Stop
                    return
                }

                if ($null -eq $configValue.InitialLicenseAssignment -or $configValue.InitialLicenseAssignment.Count -eq 0) { return }

                Write-Host "                License Assignments:"

                #region Connect to Microsoft Graph
                try {
                    Push-Location
                    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                    $connectParams = @{
                        Tenant = $config.local.AutomationAccount.TenantId
                        Scopes = @(
                            'Organization.Read.All'
                        )
                    }
                    .\Common_0001__Connect-MgGraph.ps1 @connectParams
                }
                catch {
                    Write-Error "Insufficent Microsoft Graph permissions: Scope 'Organization.Read.All' is required to continue with license assignment."
                    exit
                }
                finally {
                    Pop-Location
                }
                #endregion

                if ($null -eq $TenantSubscriptions) { $TenantSubscriptions = Get-MgBetaSubscribedSku -All -ErrorAction Stop }

                $addLicenses = [System.Collections.ArrayList]::new()

                foreach ($license in $configValue.InitialLicenseAssignment | Sort-Object SkuPartNumber) {
                    $licenseSku = $null
                    if ([string]::IsNullOrEmpty($license.SkuId) -and [string]::IsNullOrEmpty($license.SkuPartNumber)) {
                        Write-Error "License SkuId or SkuPartNumber must be specified for group definition '$_.Key' to assign a license." -ErrorAction Stop
                        return
                    }
                    if ([string]::IsNullOrEmpty($license.SkuId)) {
                        $licenseSku = $TenantSubscriptions | Where-Object { $_.SkuPartNumber -eq $license.SkuPartNumber }
                    }
                    else {
                        $licenseSku = $TenantSubscriptions | Where-Object { $_.SkuId -eq $license.SkuId }
                    }
                    if ($null -eq $licenseSku) {
                        Write-Error "License SkuPartNumber or SkuId '$($license.SkuPartNumber)($($license.SkuId))' not found for group definition '$_.Key'."
                        return
                    }

                    Write-Host "                  - $($licenseSku.SkuPartNumber) (Id: $($licenseSku.SkuId))"

                    $sku = @{
                        SkuId = $licenseSku.SkuId
                    }

                    $DisabledPlans = [System.Collections.ArrayList]::new()
                    if ($null -ne $license.DisabledPlans -and $license.DisabledPlans -is [array] -and $license.DisabledPlans.Count -gt 0) {
                        $license.DisabledPlans | ForEach-Object {
                            $servicePlanString = $_
                            $licenseSku.ServicePlans | Where-Object {
                                $_.ServicePlanName -match $servicePlanString -or
                                $_.ServicePlanId -match $servicePlanString
                            } | ForEach-Object {
                                Write-Verbose "$($licenseSku.SkuPartNumber) (Id: $($licenseSku.SkuId)): Disabling service plan '$($_.ServicePlanName) ($($_.ServicePlanId))' for group '$($configValue.DisplayName)'."
                                [void] $DisabledPlans.Add($_.ServicePlanId)
                            }
                        }
                    }
                    if ($null -ne $license.EnabledPlans -and $license.EnabledPlans -is [array] -and $license.EnabledPlans.Count -gt 0) {
                        $licenseSku.ServicePlans | Where-Object {
                            $servicePlan = $_
                            $servicePlan.AppliesTo -eq 'User' -and
                            (
                                $license.EnabledPlans | Where-Object {
                                    $servicePlan.ServicePlanName -match $_ -or
                                    $servicePlan.ServicePlanId -match $_
                                }
                            ).Count -eq 0
                        } | ForEach-Object {
                            Write-Verbose "$($licenseSku.SkuPartNumber) (Id: $($licenseSku.SkuId)): Disabling service plan '$($_.ServicePlanName) ($($_.ServicePlanId))' for group '$($configValue.DisplayName)"
                            [void] $DisabledPlans.Add($_.ServicePlanId)
                        }
                    }

                    if ($DisabledPlans.Count -gt 0) {
                        $sku.DisabledPlans = ($DisabledPlans.ToArray() | Sort-Object -Unique)
                    }
                    [void] $addLicenses.Add($sku)
                }

                if ($addLicenses.Count -eq 0) { return }

                try {
                    $params = @{
                        groupId        = $currentValue.Id
                        addLicenses    = $addLicenses.ToArray()
                        removeLicenses = @()
                    }
                    if ($commonBoundParameters) { $params += $commonBoundParameters }
                    $params.ErrorAction = 'Stop'
                    # $null = Set-MgGroupLicense @params
                    Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                    Write-Host "License assignment successfull"
                }
                catch {
                    Write-Host "                (ERROR)   " -NoNewline -ForegroundColor Red
                    Write-Host "License assignment failed"
                    Write-Error "License assignment for group '$($configValue.DisplayName)' failed: $_" -ErrorAction Stop
                    return
                }
            }
        }
        else {
            if (
                $null -ne $configValue.IsAssignableToRole -and
                $currentValue.IsAssignableToRole -ne $configValue.IsAssignableToRole
            ) {
                Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                Write-Host "$($currentValue.DisplayName) (Id: $($currentValue.Id)$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))" -NoNewline
                Write-Host $(if ([string]::IsNullOrEmpty($currentValue.Description)) { '' } else { "`n              $($currentValue.Description)" }) -ForegroundColor DarkGray
                Write-Error "Group '$($currentValue.DisplayName)' must have property 'IsAssignableToRole' set to '$($configValue.IsAssignableToRole)'. This cannot be changed after the group is created." -ErrorAction Stop
                return
            }

            if (
                $null -ne $configValue.Visibility -and
                $currentValue.Visibility -ne $configValue.Visibility
            ) {
                Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                Write-Host "$($currentValue.DisplayName) (Id: $($currentValue.Id)$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))" -NoNewline
                Write-Host $(if ([string]::IsNullOrEmpty($currentValue.Description)) { '' } else { "`n              $($currentValue.Description)" }) -ForegroundColor DarkGray
                Write-Error "Group '$($currentValue.DisplayName)' must have property 'Visibility' set to '$($configValue.Visibility)'. This cannot be changed after the group is created." -ErrorAction Stop
                return
            }

            # Iterate over the keys in the hashtable to find differences
            $updateProperty = @{}
            $configValue.Keys | ForEach-Object {
                if (@('@odata.context', 'Id', 'DeletedDateTime', 'IsAssignableToRole', 'AdditionalProperties') -contains $_) { return }
                $key = $_

                # If the property exists in $currentValue
                if (@($currentValue.PSObject.Properties.Name) -contains $key) {
                    # If the value has changed, add it to $updateProperty
                    if ($currentValue.$key -ne $configValue.$key) {
                        Write-Verbose " Property '$key' has changed for the group '$($currentValue.DisplayName)'."
                        $updateProperty.$key = $configValue.$key
                    }
                    else {
                        Write-Verbose " Property '$key' has not changed for the group '$($currentValue.DisplayName)'."
                    }
                }
                # If the property does not exist in $currentValue but exists in the hashtable, output a warning
                elseif (
                    $null -ne $configValue.$key -and
                    @( 'AdministrativeUnit', 'InitialLicenseAssignment' ) -notcontains $key
                ) {
                    Write-Warning "Property '$key' seems to be an invalid property for the group '$($currentValue.DisplayName)'."
                }
            }

            if ($updateProperty.Count -gt 0) {
                Write-Host "    (Update)  " -NoNewline -ForegroundColor Yellow
                Write-Host "$($currentValue.DisplayName) (Id: $($currentValue.Id)$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))" -NoNewline
                Write-Host $(if ([string]::IsNullOrEmpty($currentValue.Description)) { '' } else { "`n              $($currentValue.Description)" }) -ForegroundColor DarkGray

                if ($PSCmdlet.ShouldProcess(
                        "Update Group '$($configValue.DisplayName)' $(if($updateProperty.Count -eq 1) {'property'} else {'properties'}; ($updateProperty.Keys | ForEach-Object { "'$_'" }) -join ', ' ) in $(if ($null -ne $configValue.AdministrativeUnit -and -not [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {"administrative unit '$($configValue.AdministrativeUnit.DisplayName)' of "})tenant $($config.local.AutomationAccount.TenantId) ?",
                        "Do you confirm to update Group '$($configValue.DisplayName)' $(if($updateProperty.Count -eq 1) {'property'} else {'properties'}; ($updateProperty.Keys | ForEach-Object { "'$_'" }) -join ', ' ) in $(if ($null -ne $configValue.AdministrativeUnit -and -not [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {"administrative unit '$($configValue.AdministrativeUnit.DisplayName)' of "})tenant $($config.local.AutomationAccount.TenantId) ?",
                        "Update Groups in tenant $($config.local.AutomationAccount.TenantId)"
                    )) {

                    #region Connect to Microsoft Graph
                    try {
                        Push-Location
                        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                        $connectParams = @{
                            Tenant = $config.local.AutomationAccount.TenantId
                            Scopes = @(
                                'Group.ReadWrite.All'
                            )
                        }
                        if (-not $ConfirmedMgPermission) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermission = $true }
                    }
                    catch {
                        Write-Error "Insufficent Microsoft Graph permissions: Scope 'Group.ReadWrite.All' is required to continue setup of groups in Microsoft Entra."
                        exit
                    }
                    finally {
                        Pop-Location
                    }
                    #endregion

                    #region Required Microsoft Entra Directory Permissions Validation --------------
                    if ($null -ne $configValue.AdministrativeUnit -and -not [string]::IsNullOrEmpty($configValue.AdministrativeUnit.Id)) {
                        try {
                            Push-Location
                            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                            $confirmParams = @{
                                AllowGlobalAdministratorInAzureAutomation         = $true
                                AllowPrivilegedRoleAdministratorInAzureAutomation = $true
                                AllowSuperseededRoleWithDirectoryScope            = if ($configValue.AdministrativeUnit.IsMemberManagementRestricted) { $false } else { $true }
                                Roles                                             = @(
                                    @{
                                        DisplayName      = 'Groups Administrator'
                                        TemplateId       = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'
                                        DirectoryScopeId = "/administrativeUnits/$($configValue.AdministrativeUnit.Id)"
                                    }
                                )
                            }
                            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                            $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Entra permissions: $(if ($configValue.AdministrativeUnit.IsMemberManagementRestricted) {'Explicit'} else {'At lest'}) 'Groups Administrator' directory role with scope to administrative unit '$($configValue.AdministrativeUnit.DisplayName)' is required to setup groups in Microsoft Entra." -ErrorAction Stop
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                    }
                    else {
                        try {
                            Push-Location
                            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                            $confirmParams = @{
                                AllowGlobalAdministratorInAzureAutomation         = $true
                                AllowPrivilegedRoleAdministratorInAzureAutomation = $true
                                Roles                                             = @(
                                    @{
                                        DisplayName      = 'Groups Administrator'
                                        TemplateId       = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'
                                        DirectoryScopeId = '/'
                                    }
                                )
                            }
                            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                            if (-not $ConfirmedEntraPermission) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermission = $true }
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Entra permissions: At least 'Groups Administrator' directory role is required to setup groups in Microsoft Entra." -ErrorAction Stop
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                    }
                    #endregion

                    try {
                        $params = @{
                            OutputType = 'PSObject'
                            Method     = 'PATCH'
                            Uri        = "https://graph.microsoft.com/v1.0/groups/$($currentValue.Id)"
                            Body       = $updateProperty
                        }
                        if ($commonBoundParameters) { $params += $commonBoundParameters }
                        $currentValue = Invoke-MgGraphRequest @params
                        Write-Host "    (Ok)      " -NoNewline -ForegroundColor Green
                        Write-Host "$($currentValue.DisplayName) (Id: $($currentValue.Id)$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))" -NoNewline
                    }
                    catch {
                        Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                        Write-Host "$($currentValue.DisplayName) (Id: $($currentValue.Id)$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))"
                        Write-Error "$_" -ErrorAction Stop
                        return
                    }
                }

                return
            }

            Write-Host "    (Ok)      " -NoNewline -ForegroundColor Green
            Write-Host "$($currentValue.DisplayName) (Id: $($currentValue.Id)$(if ([string]::IsNullOrEmpty($configValue.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($configValue.AdministrativeUnit.DisplayName)" }))" -NoNewline
            Write-Host $(if ([string]::IsNullOrEmpty($currentValue.Description)) { '' } else { "`n              $($currentValue.Description)" }) -ForegroundColor DarkGray
        }
    }
}
