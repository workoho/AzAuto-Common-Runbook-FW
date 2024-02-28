<#PSScriptInfo
.VERSION 1.0.0
.GUID 02b64a08-c9c4-4fb2-a8f6-c7ffc3cf85c5
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
    Placeholder for the Set-AzAutomationManagedIdentity function.

.DESCRIPTION
    Placeholder for the Set-AzAutomationManagedIdentity function.
#>

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'High'
)]
Param ()

if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    Write-Error 'This script must be run interactively by a privileged administrator account.' -ErrorAction Stop
    exit
}
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

Write-Host "`n`nManaged Identity Roles & Permissions`n====================================`n" -ForegroundColor White

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
    'ManagedIdentity'
) | & {
    process {
        if ($null -eq $config.$_) {
            Write-Error "Mandatory property '/PrivateData/$_' is missing or null in the AzAutoFWProject.psd1 configuration file." -ErrorAction Stop
            exit
        }
    }
}

$SubscriptionScope = "/subscriptions/$($config.local.AutomationAccount.SubscriptionId)"
$RgScope = "$SubscriptionScope/resourcegroups/$($config.local.AutomationAccount.ResourceGroupName)"
$SelfScope = "$RgScope/providers/Microsoft.Automation/automationAccounts/$($config.local.AutomationAccount.Name)"

$SAMI = @($config.ManagedIdentity | Where-Object Type -eq 'SystemAssigned')
if ($config.Local.ManagedIdentity) { $SAMI += @($config.Local.ManagedIdentity | Where-Object Type -eq 'SystemAssigned') }
if (($SAMI | Measure-Object).Count -gt 1) {
    Write-Error "Multiple System-Assigned Managed Identities found in the project configuration. Only one System-Assigned Managed Identity is allowed." -ErrorAction Stop
    exit
}
#endregion

#region Connect to Azure
$automationAccount = $null
try {
    Push-Location
    Set-Location $PSScriptRoot
    if ($commonBoundParameters) {
        $automationAccount = .\Set-AzAutomationAccount.ps1 @commonBoundParameters
    }
    else {
        $automationAccount = .\Set-AzAutomationAccount.ps1
    }
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Stop
    exit
}
finally {
    Pop-Location
}
#endregion

if ($SAMI -and -Not $automationAccount.Identity) {
    if ($PSCmdlet.ShouldProcess(
            "Enable System-Assigned Managed Identity for $($automationAccount.AutomationAccountName)",
            "Do you confirm to enable a system-assigned Managed Identity for $($automationAccount.AutomationAccountName) ?",
            'Enable System-Assigned Managed Identity for Azure Automation Account'
        )) {

        #region Confirm Azure Role Assignments
        try {
            Push-Location
            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
            $confirmParams = @{
                Roles = @{
                    $SelfScope = 'Contributor'
                }
            }
            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
            $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams
        }
        catch {
            Write-Error "Insufficent Azure permissions: At least 'Contributor' role for the Automation Account is required for Managed Identity setup." -ErrorAction Stop
            $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
            exit
        }
        finally {
            Pop-Location
        }
        #endregion

        try {
            $params = @{
                ResourceGroupName    = $automationAccount.ResourceGroupName
                Name                 = $automationAccount.AutomationAccountName
                AssignSystemIdentity = $true
            }
            if ($commonBoundParameters) { $params += $commonBoundParameters }
            $automationAccount = Set-AzAutomationAccount @params
        }
        catch {
            Write-Error $_.Exception.Message -ErrorAction Stop
            exit
        }
    }
}

if ($SAMI -and $automationAccount.Identity.PrincipalId) {
    Write-Host "`n    System-Assigned Managed Identity`n    --------------------------------`n" -ForegroundColor Blue

    if ($SAMI.AzureRoles.Count -gt 0) {
        Write-Host "        Azure Roles:`n"
        $AzureRoleDefinitions = Get-AzRoleDefinition
    }
    $ConfirmedAzPermission = $false
    $SAMI.AzureRoles.GetEnumerator() | & {
        process {
            if ($_.Value.Count -eq 0) {
                Write-Verbose "No Azure Roles defined for $Scope."
                continue
            }

            $Scope = if ($_.Key -eq 'self') { $SelfScope } else { $_.Key }
            if ($Scope -match '^\/subscriptions\/(?<subscriptionId>[^/]+)\/resourcegroups\/(?<resourceGroupName>[^/]+)(?:\/providers\/(?<resourceProviderNamespace>[^/]+)\/(?<resourceType>[^/]+)\/(?<resourceName>[^/]+))?.*') {
                $SubscriptionId = $Matches.subscriptionId
                $ResourceGroupName = $Matches.resourceGroupName
                $ResourceProviderNamespace = $Matches.resourceProviderNamespace
                $ResourceType = $Matches.resourceType
                $ResourceName = $Matches.resourceName
                Write-Host "            $ResourceName ($ResourceType) in $ResourceGroupName, $SubscriptionId"

                $AzureRoleAssignments = Get-AzRoleAssignment -ObjectId $automationAccount.Identity.PrincipalId -Scope $Scope

                foreach ($AzureRole in $_.Value) {
                    $AzureRoleDefinition = if (-not [string]::IsNullOrEmpty($AzureRole.RoleDefinitionId)) { $AzureRoleDefinitions | Where-Object Id -eq $AzureRole.RoleDefinitionId } elseif (-not [string]::IsNullOrEmpty($AzureRole.DisplayName)) { $AzureRoleDefinitions | Where-Object Name -eq $AzureRole.DisplayName } else {
                        Write-Error "Invalid Azure Role definition for scope '$Scope'."
                        continue
                    }
                    if ($null -eq $AzureRoleDefinition) {
                        Write-Host "                (ERROR)    " -NoNewline -ForegroundColor Red
                        Write-Host $(if (-not [string]::IsNullOrEmpty($AzureRole.RoleDefinitionId)) { $AzureRole.RoleDefinitionId } else { $AzureRole.DisplayName })
                        Write-Error "Invalid Azure Role definition for scope '$Scope':`n       No Azure Role found with $(if(-not [string]::IsNullOrEmpty($AzureRole.RoleDefinitionId)) { "role ID '$($AzureRole.RoleDefinitionId)'" } else { "name '$($AzureRole.DisplayName)'"})."
                        continue
                    }

                    # Only works for direct assignments, not indirect ones via group membership
                    if ($AzureRoleAssignments | Where-Object RoleDefinitionId -eq $AzureRoleDefinition.Id) {
                        Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                        Write-Host "$($AzureRoleDefinition.Name) (Id: $($AzureRoleDefinition.Id))" -NoNewline
                        Write-Host "`n                          $($AzureRoleDefinition.Description)" -ForegroundColor DarkGray
                    }
                    else {
                        Write-Host "                (Missing) " -NoNewline -ForegroundColor White
                        Write-Host "$($AzureRoleDefinition.Name) (Id: $($AzureRoleDefinition.Id))" -NoNewline
                        Write-Host "`n                          $($AzureRoleDefinition.Description)" -ForegroundColor DarkGray

                        if ($PSCmdlet.ShouldProcess(
                                "Assign Azure Role '$($AzureRoleDefinition.Name)' to System-Assigned Managed Identity of $($automationAccount.AutomationAccountName)",
                                "Do you confirm to assign Azure Role '$($AzureRoleDefinition.Name)' for $($automationAccount.AutomationAccountName) ?",
                                'Assign Azure Roles to System-Assigned Managed Identity'
                            )) {

                            #region Confirm Azure Role Assignments
                            try {
                                Push-Location
                                Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                                $confirmParams = @{
                                    Roles = @{
                                        $SelfScope = 'User Access Administrator'
                                    }
                                }
                                if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                                if (-not $ConfirmedAzPermission) { $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams; $ConfirmedAzPermission = $true }
                            }
                            catch {
                                Write-Error "Insufficent Azure permissions: At least 'User Access Administrator' role for the Automation Account is required for Managed Identity role assignment." -ErrorAction Stop
                                $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
                                exit
                            }
                            finally {
                                Pop-Location
                            }
                            #endregion

                            try {
                                $params = @{
                                    ObjectId         = $automationAccount.Identity.PrincipalId
                                    RoleDefinitionId = $AzureRoleDefinition.Id
                                    Scope            = $Scope
                                }
                                if ($commonBoundParameters) { $params += $commonBoundParameters }
                                $params.ErrorAction = 'Stop'
                                $null = New-AzRoleAssignment @params
                                Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                                Write-Host "$($AzureRoleDefinition.Name) (Id: $($AzureRoleDefinition.Id))"
                            }
                            catch {
                                Write-Host "                (ERROR)   " -NoNewline -ForegroundColor Red
                                Write-Host "$($AzureRoleDefinition.Name) (Id: $($AzureRoleDefinition.Id))"
                                Write-Error "$_" -ErrorAction Stop
                                exit
                            }
                        }
                    }
                }
            }
            else {
                Write-Error "Invalid Azure Role scope '$Scope'"
                continue
            }
        }
    }

    #region Connect to Microsoft Graph
    try {
        Push-Location
        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
        $connectParams = @{
            Tenant = $config.local.AutomationAccount.TenantId
            Scopes = @(
                'Application.Read.All'
                'Directory.Read.All'
            )
        }
        .\Common_0001__Connect-MgGraph.ps1 @connectParams
    }
    catch {
        Write-Error "Insufficent Microsoft Graph permissions: Scope 'Application.Read.All' is required to continue permission validation of the Automation Account. Further permissions may be required to perform changes."
        exit
    }
    finally {
        Pop-Location
    }
    #endregion

    if ($SAMI.AppPermissions.Count -gt 0) {
        Write-Host "`n        App Permissions:"
    }

    $highlyPrivilegedApplications = @(
        '00000003-0000-0000-c000-000000000000', # Microsoft Graph
        '00000002-0000-0000-c000-000000000000', # Azure Active Directory Graph (deprecated)
        '00000001-0000-0000-c000-000000000000'  # Microsoft Entra
    )
    $ConfirmedMgPermission = $false
    $ConfirmedEntraPermission = $false
    $ConfirmedEntraPermissionPrivileged = $false

    $SAMI.AppPermissions | & {
        process {
            try {
                $ServicePrincipal = $null
                if ($_.AppId -match '^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$') {
                    $ServicePrincipal = Get-MgServicePrincipal -All -ConsistencyLevel eventual -Filter "ServicePrincipalType eq 'Application' and appId eq '$($_.AppId)'"
                }
                else {
                    $ServicePrincipal = Get-MgServicePrincipal -All -ConsistencyLevel eventual -Filter "ServicePrincipalType eq 'Application' and DisplayName eq '$($_.DisplayName)'"
                }
                Write-Host "`n            $($ServicePrincipal.DisplayName) (AppId: $($ServicePrincipal.AppId))"
                $AppRoleAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $automationAccount.Identity.PrincipalId | Where-Object ResourceId -eq $ServicePrincipal.Id
                $PermissionGrants = Get-MgOauth2PermissionGrant -All -Filter "ClientId eq '$($automationAccount.Identity.PrincipalId)' and ResourceId eq '$($ServicePrincipal.Id)'"
            }
            catch {
                Write-Error "$_"
                return
            }

            if ($_.AppRoles.Count -gt 0) {
                Write-Host "            Application:"

                foreach ($Permission in ($_.AppRoles | Select-Object -Unique | Sort-Object)) {
                    $AppRole = $ServicePrincipal.AppRoles | Where-Object { $_.Value -eq $Permission }
                    if ($null -eq $AppRole) {
                        Write-Host "                (FAILED)  " -NoNewline -ForegroundColor Red
                        Write-Host $Permission
                        Write-Error "$($ServicePrincipal.DisplayName): No App Role found with name '$Permission' for $($ServicePrincipal.DisplayName). Choose one of:`n   $(($ServicePrincipal.AppRoles | Sort-Object Value | ForEach-Object { '{0}: {1}' -f $_.Value, $_.DisplayName }) -join "`n   ")"
                        continue
                    }

                    if ($AppRoleAssignments | Where-Object AppRoleId -eq $AppRole.Id) {
                        Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                        Write-Host "$($AppRole.Value)`n                          " -NoNewline
                        Write-Host $AppRole.DisplayName -ForegroundColor DarkGray
                        continue
                    }

                    Write-Host "                (Missing) " -NoNewline -ForegroundColor White
                    Write-Host "$($AppRole.Value)`n                          " -NoNewline
                    Write-Host $AppRole.DisplayName -ForegroundColor DarkGray

                    if ($PSCmdlet.ShouldProcess(
                            "Assign '$($AppRole.Value)' app role permission for '$($ServicePrincipal.DisplayName)' to System-Assigned Managed Identity of $($automationAccount.AutomationAccountName)",
                            "Do you confirm to assign '$($AppRole.Value)' app role permission for '$($ServicePrincipal.DisplayName)' to $($automationAccount.AutomationAccountName) ?",
                            "Assign '$($ServicePrincipal.DisplayName)' app role permissions to System-Assigned Managed Identity of Azure Automation Account"
                        )) {

                        #region Connect to Microsoft Graph
                        try {
                            Push-Location
                            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                            $connectParams = @{
                                Tenant = $config.local.AutomationAccount.TenantId
                                Scopes = @(
                                    'AppRoleAssignment.ReadWrite.All'
                                )
                            }
                            if (-not $ConfirmedMgPermission) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermission = $true }
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Graph permissions: Scope 'AppRoleAssignment.ReadWrite.All' is required to assign app role permissions to the Automation Account." -ErrorAction Stop
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
                                Roles                                             = @(
                                    @{
                                        DisplayName = 'Cloud Application Administrator'
                                        TemplateId  = '158c047a-c907-4556-b7ef-446551a6b5f7'
                                    }
                                )
                            }
                            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                            if (-not $ConfirmedEntraPermission) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermission = $true }
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Entra permissions: At least 'Cloud Application Administrator' directory role is required to assign app role permissions to the Automation Account." -ErrorAction Stop
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                        #endregion

                        if ($ServicePrincipal.AppId -in $highlyPrivilegedApplications) {
                            #region Required Microsoft Entra Directory Permissions Validation --------------
                            try {
                                Push-Location
                                Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                                $confirmParams = @{
                                    AllowGlobalAdministratorInAzureAutomation         = $true
                                    AllowPrivilegedRoleAdministratorInAzureAutomation = $true
                                    Roles                                             = @(
                                        @{
                                            DisplayName = 'Privileged Role Administrator'
                                            TemplateId  = 'e8611ab8-c189-46e8-94e1-60213ab1f814'
                                        }
                                    )
                                }
                                if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                                if (-not $ConfirmedEntraPermissionPrivileged) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermissionPrivileged = $true }
                            }
                            catch {
                                Write-Error "Insufficent Microsoft Entra permissions: 'Privileged Role Administrator' directory role is required in addition to 'Cloud Application Administrator' to assign app role permissions for highly-privileged applications to the Automation Account." -ErrorAction Stop
                                exit
                            }
                            finally {
                                Pop-Location
                            }
                            #endregion
                        }

                        try {
                            $params = @{
                                ServicePrincipalId = $automationAccount.Identity.PrincipalId
                                BodyParameter      = @{
                                    PrincipalId = $automationAccount.Identity.PrincipalId
                                    ResourceId  = $ServicePrincipal.Id
                                    AppRoleId   = $AppRole.Id
                                }
                            }
                            if ($commonBoundParameters) { $params += $commonBoundParameters }
                            $null = New-MgServicePrincipalAppRoleAssignment @params
                            Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                            Write-Host "$($AppRole.Value)"
                        }
                        catch {
                            Write-Host "                (FAILED)  " -NoNewline -ForegroundColor Red
                            Write-Host $Permission
                            Write-Error "$_" -ErrorAction Stop
                            exit
                        }
                    }
                }
            }

            $ConfirmedMgPermission = $false
            $ConfirmedEntraPermission = $false
            $SAMI.Oauth2PermissionScopes | & {
                process {
                    if ($_.Count -eq 0) {
                        Write-Verbose "No OAuth2PermissionScopes defined for '$($ServicePrincipal.DisplayName)'."
                        return
                    }

                    Write-Host "            Delegated:"

                    $_.GetEnumerator() | & {
                        process {
                            $ClientId = $automationAccount.Identity.PrincipalId
                            $ResourceId = $ServicePrincipal.Id
                            $PrincipalId = $_.Key
                            $ConsentType = if ($PrincipalId -eq 'Admin') { 'AllPrincipals' } else { 'Principal' }
                            Write-Host "         ${PrincipalId}:"

                            $scopes = @()
                            foreach ($Permission in ($_.Value | Select-Object -Unique | Sort-Object)) {
                                $OAuth2Permission = $ServicePrincipal.Oauth2PermissionScopes | Where-Object { $_.Value -eq $Permission }
                                if ($null -eq $OAuth2Permission) {
                                    Write-Error "$($ServicePrincipal.DisplayName): No OAuth Permission found with name '$Permission'. Choose one of:`n   $(($ServicePrincipal.Oauth2PermissionScopes | Sort-Object Value | ForEach-Object { '{0}: {1}' -f $_.Value, $_.DisplayName }) -join "`n   ")"
                                    continue
                                }
                                $scopes += $OAuth2Permission.Value
                            }

                            if ($scopes.Count -eq 0) { continue }

                            $PermissionGrant = $PermissionGrants | Where-Object ConsentType -eq $ConsentType
                            if ($ConsentType -eq 'Principal') {
                                $PermissionGrant = $PermissionGrant | Where-Object PrincipalId -eq $PrincipalId
                            }

                            if (-not [string]::IsNullOrEmpty($PermissionGrant.Scope)) {
                                $missingItems = Compare-Object -ReferenceObject $scopes -DifferenceObject ($PermissionGrant.Scope -split ' ') | Where-Object { $_.SideIndicator -eq '=>' }
                                if ($missingItems.Count -eq 0) {
                                    $scopes | & {
                                        process {
                                            Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                                            Write-Host $_
                                            Write-Host "                          $(if ($PrincipalId -eq 'Admin') { $OAuth2Permission | Where-Object Value -eq $_ | Select-Object -ExpandProperty AdminConsentDisplayName } else { $OAuth2Permission | Where-Object Value -eq $_ | Select-Object -ExpandProperty UserConsentDisplayName })" -ForegroundColor DarkGray
                                        }
                                    }
                                    return
                                }
                            }

                            Write-Host "                (Missing) " -NoNewline -ForegroundColor White
                            Write-Host $_
                            Write-Host "                          $(if ($PrincipalId -eq 'Admin') { $OAuth2Permission | Where-Object Value -eq $_ | Select-Object -ExpandProperty AdminConsentDisplayName } else { $OAuth2Permission | Where-Object Value -eq $_ | Select-Object -ExpandProperty UserConsentDisplayName })" -ForegroundColor DarkGray

                            if ($PSCmdlet.ShouldProcess(
                                    "Assign $($scopes.Count) OAuth2 permissions for '$($ServicePrincipal.DisplayName)' to System-Assigned Managed Identity of $($automationAccount.AutomationAccountName)",
                                    "Do you confirm to assign $($scopes.Count) OAuth2 permissions for '$($ServicePrincipal.DisplayName)' to $($automationAccount.AutomationAccountName) ?",
                                    "Assign OAuth2 permissions to System-Assigned Managed Identity of Azure Automation Account"
                                )) {

                                #region Connect to Microsoft Graph
                                try {
                                    Push-Location
                                    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                                    $connectParams = @{
                                        Tenant = $config.local.AutomationAccount.TenantId
                                        Scopes = @(
                                            'DelegatedPermissionGrant.ReadWrite.All'
                                        )
                                    }
                                    if (-not $ConfirmedMgPermission) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermission = $true }
                                }
                                catch {
                                    Write-Error "Insufficent Microsoft Graph permissions: Scope 'DelegatedPermissionGrant.ReadWrite.All' is required to assign OAuth2 permissions to the Automation Account." -ErrorAction Stop
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
                                        Roles                                             = @(
                                            @{
                                                DisplayName = 'Cloud Application Administrator'
                                                TemplateId  = '158c047a-c907-4556-b7ef-446551a6b5f7'
                                            }
                                        )
                                    }
                                    if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                                    if (-not $ConfirmedEntraPermission) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermission = $true }
                                }
                                catch {
                                    Write-Error "Insufficent Microsoft Entra permissions: At least 'Cloud Application Administrator' directory role is required to assign OAuth2 permissions to the Automation Account." -ErrorAction Stop
                                    exit
                                }
                                finally {
                                    Pop-Location
                                }
                                #endregion

                                if ($ServicePrincipal.AppId -in $highlyPrivilegedApplications) {
                                    #region Required Microsoft Entra Directory Permissions Validation --------------
                                    try {
                                        Push-Location
                                        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                                        $confirmParams = @{
                                            AllowGlobalAdministratorInAzureAutomation         = $true
                                            AllowPrivilegedRoleAdministratorInAzureAutomation = $true
                                            Roles                                             = @(
                                                @{
                                                    DisplayName = 'Privileged Role Administrator'
                                                    TemplateId  = 'e8611ab8-c189-46e8-94e1-60213ab1f814'
                                                }
                                            )
                                        }
                                        if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                                        if (-not $ConfirmedEntraPermissionPrivileged) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermissionPrivileged = $true }
                                    }
                                    catch {
                                        Write-Error "Insufficent Microsoft Entra permissions: 'Privileged Role Administrator' directory role is required in addition to 'Cloud Application Administrator' to assign OAuth2 permissions for highly-privileged applications to the Automation Account." -ErrorAction Stop
                                        exit
                                    }
                                    finally {
                                        Pop-Location
                                    }
                                    #endregion
                                }

                                try {
                                    if ($PermissionGrant) {
                                        $params = @{
                                            OAuth2PermissionGrantId = $PermissionGrant.Id
                                            BodyParameter           = @{
                                                Scope = $scopes -join ' '
                                            }
                                        }
                                        if ($commonParameters) { $params += $commonBoundParameters }
                                        $params.ErrorAction = 'Stop'
                                        Update-MgOauth2PermissionGrant @params
                                    }
                                    else {
                                        $params = @{
                                            BodyParameter = @{
                                                ClientId    = $ClientId
                                                ConsentType = $ConsentType
                                                ResourceId  = $ResourceId
                                                Scope       = $scopes -join ' '
                                            }
                                        }
                                        if ($PrincipalId -ne 'Admin') {
                                            $params.BodyParameter.PrincipalId = $PrincipalId
                                        }
                                        if ($commonParameters) { $params += $commonBoundParameters }
                                        $params.ErrorAction = 'Stop'
                                        $null = New-MgOauth2PermissionGrant -BodyParameter $params
                                    }

                                    Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                                    Write-Host $_
                                }
                                catch {
                                    Write-Host "                (ERROR)   " -NoNewline -ForegroundColor Red
                                    Write-Host $_
                                    Write-Error "$_" -ErrorAction Stop
                                    exit
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if ($SAMI.DirectoryRoles.Count -gt 0) {
        Write-Host "`n        Directory Roles:`n"

        $ConfirmedMgPermission = $false
        $ConfirmedEntraPermission = $false
        $DirectoryRoleDefinitions = Get-MgRoleManagementDirectoryRoleDefinition
        $DirectoryRoleAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All -Filter "PrincipalId eq '$($automationAccount.Identity.PrincipalId)'"

        foreach ($Role in ($SAMI.DirectoryRoles | Sort-Object DisplayName, RoleTemplateId)) {
            $RoleDefinition = $null
            if ($Role.RoleDefinitionId) {
                $RoleDefinition = $DirectoryRoleDefinitions | Where-Object { $_.RoleDefinitionId -eq $Role.RoleDefinitionId }
            }
            elseif ($Role.roleTemplateId) {
                $RoleDefinition = $DirectoryRoleDefinitions | Where-Object { $_.TemplateId -eq $Role.roleTemplateId }
            }
            elseif ($Role.DisplayName) {
                $RoleDefinition = $DirectoryRoleDefinitions | Where-Object { $_.DisplayName -eq $Role.DisplayName }
            }
            if ($null -eq $RoleDefinition) {
                Write-Error "No Entra ID Role found with name '$($Role.DisplayName)'. Choose one of:`n   $(($DirectoryRoleDefinitions | Sort-Object DisplayName | ForEach-Object { '{0} ({1})' -f $_.DisplayName, $_.TemplateId }) -join "`n   ")"
                continue
            }

            if ($null -ne $Role.AdministrativeUnit -and $Role.AdministrativeUnit -is [hashtable]) {
                if ([string]::IsNullOrEmpty($Role.AdministrativeUnit.DisplayName) -and [string]::IsNullOrEmpty($Role.AdministrativeUnit.Id)) {
                    Write-Error "Administrative unit reference for directory role '$($Role.DisplayName)' must have a 'DisplayName' or 'Id' property in configuration." -ErrorAction Stop
                    return
                }
                try {
                    $adminUnit = $null
                    if ([string]::IsNullOrEmpty($Role.AdministrativeUnit.Id)) {
                        $adminUnit = Get-MgBetaAdministrativeUnit -Filter "displayName eq '$($Role.AdministrativeUnit.DisplayName)'" -ErrorAction Stop
                    }
                    else {
                        $adminUnit = Get-MgBetaAdministrativeUnit -AdministrativeUnitId $Role.AdministrativeUnit.Id -ErrorAction Stop
                    }
                    if ($adminUnit.Count -gt 1) {
                        Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                        Write-Host "$($RoleDefinition.DisplayName) (Id: $($RoleDefinition.Id)$(if ([string]::IsNullOrEmpty($Role.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($Role.AdministrativeUnit.DisplayName)" }))`n                          " -NoNewline
                        Write-Error "Multiple administrative units found with the same name '$($Role.AdministrativeUnit.DisplayName)'. Please ensure that the administrative unit names are unique, or add Object ID to configuration." -ErrorAction Stop
                        return
                    }
                    $Role.AdministrativeUnit = $adminUnit
                    Write-Verbose " Found Administrative Unit for group: $($Role.AdministrativeUnit.DisplayName) ($($Role.AdministrativeUnit.Id))"
                }
                catch {
                    Write-Error "Administrative unit '$($Role.AdministrativeUnit.DisplayName)' for directory role scope '$($Role.DisplayName)' not found." -ErrorAction Stop
                    return
                }
            }

            if ($null -eq $Role.DirectoryScopeId) {
                if ($null -ne $Role.AdministrativeUnit.Id) {
                    $Role.DirectoryScopeId = "/administrativeUnits/$($Role.AdministrativeUnit.Id)"
                    Write-Verbose "Setting DirectoryScopeId to $($Role.DirectoryScopeId)."
                }
                else {
                    $Role.DirectoryScopeId = '/'
                }
            }

            if ($DirectoryRoleAssignments | Where-Object { $_.RoleDefinitionId -eq $RoleDefinition.Id -and $_.DirectoryScopeId -eq $Role.DirectoryScopeId }) {
                Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                Write-Host "$($RoleDefinition.DisplayName) (Id: $($RoleDefinition.Id)$(if ([string]::IsNullOrEmpty($Role.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($Role.AdministrativeUnit.DisplayName)" }))`n                          " -NoNewline
                Write-Host $RoleDefinition.Description -ForegroundColor DarkGray
                continue
            }

            Write-Host "                (Missing) " -NoNewline -ForegroundColor White
            Write-Host "$($RoleDefinition.DisplayName) (Id: $($RoleDefinition.Id)$(if ([string]::IsNullOrEmpty($Role.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($Role.AdministrativeUnit.DisplayName)" }))`n                          " -NoNewline
            Write-Host $RoleDefinition.Description -ForegroundColor DarkGray

            if ($PSCmdlet.ShouldProcess(
                    "Assign Entra directory role '$($RoleDefinition.DisplayName)' to System-Assigned Managed Identity of $($automationAccount.AutomationAccountName)",
                    "Do you confirm to assign Entra directory role '$($RoleDefinition.DisplayName)' to $($automationAccount.AutomationAccountName) ?",
                    "Assign Entra directory roles to System-Assigned Managed Identity of Azure Automation Account"
                )) {

                #region Connect to Microsoft Graph
                try {
                    Push-Location
                    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                    $connectParams = @{
                        Tenant = $config.local.AutomationAccount.TenantId
                        Scopes = @(
                            'RoleManagement.ReadWrite.Directory'
                        )
                    }
                    if (-not $ConfirmedMgPermission) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermission = $true }
                }
                catch {
                    Write-Error "Insufficent Microsoft Graph permissions: Scope 'RoleManagement.ReadWrite.Directory' is required to assign directory roles to the Automation Account." -ErrorAction Stop
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
                        Roles                                             = @(
                            @{
                                DisplayName = 'Privileged Role Administrator'
                                TemplateId  = 'e8611ab8-c189-46e8-94e1-60213ab1f814'
                            }
                        )
                    }
                    if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                    if (-not $ConfirmedEntraPermissionPrivileged) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermissionPrivileged = $true }
                }
                catch {
                    Write-Error "Insufficent Microsoft Entra permissions: At least 'Privileged Role Administrator' directory role is required to assign directory roles to the Automation Account." -ErrorAction Stop
                    exit
                }
                finally {
                    Pop-Location
                }
                #endregion

                try {
                    $params = @{
                        BodyParameter = @{
                            PrincipalId      = $automationAccount.Identity.PrincipalId
                            RoleDefinitionId = $RoleDefinition.Id
                            DirectoryScopeId = $Role.DirectoryScopeId
                        }
                    }
                    if ($commonBoundParameters) { $params += $commonBoundParameters }
                    $params.ErrorAction = 'Stop'
                    $null = New-MgRoleManagementDirectoryRoleAssignment @params
                }
                catch {
                    Write-Host "                (ERROR)   " -NoNewline -ForegroundColor Red
                    Write-Host "$($RoleDefinition.DisplayName) (Id: $($RoleDefinition.Id)$(if ([string]::IsNullOrEmpty($Role.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($Role.AdministrativeUnit.DisplayName)" }))"
                    Write-Error "$_" -ErrorAction Stop
                    exit
                }

                Write-Host "                (Ok)      " -NoNewline -ForegroundColor Green
                Write-Host "$($RoleDefinition.DisplayName) (Id: $($RoleDefinition.Id)$(if ([string]::IsNullOrEmpty($Role.AdministrativeUnit.DisplayName)) { '' } else { ", Administrative Unit: $($Role.AdministrativeUnit.DisplayName)" }))"
            }
        }
    }
}
