<#PSScriptInfo
.VERSION 1.0.0
.GUID b05865ff-cdeb-488a-ae6d-e3d222374e06
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
    This script sets up administrative units in the Microsoft Entra tenant of the Azure Automation Account.

.DESCRIPTION
    This script is used to create administrative units in the Microsoft Entra tenant of the Azure Automation Account.
    It uses the Microsoft Graph Beta API directly to perform the necessary operations.

.PARAMETER AdministrativeUnit
    The name or ID of the administrative unit to be created or updated.
#>

#Requires -Module @{ ModuleName='Microsoft.Graph.Authentication'; ModuleVersion='2.15.0' }
#Requires -Module @{ ModuleName='Microsoft.Graph.Users'; ModuleVersion='2.15.0' }
#Requires -Module @{ ModuleName='Microsoft.Graph.Identity.Governance'; ModuleVersion='2.15.0' }

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'High'
)]
Param(
    [array]$AdministrativeUnit
)

if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    Write-Error 'This script must be run interactively by a privileged administrator account.' -ErrorAction Stop
    exit
}
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

Write-Host "`n`nAdministrative Unit Setup`n=========================`n" -ForegroundColor White

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
    'AdministrativeUnit'
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
            'AdministrativeUnit.Read.All'
        )
    }
    .\Common_0001__Connect-MgGraph.ps1 @connectParams
}
catch {
    Write-Error "Insufficent Microsoft Graph permissions: Scope 'AdministrativeUnit.Read.All' is required to continue validation of administrative units. Further permissions may be required to perform changes."
    exit
}
finally {
    Pop-Location
}
#endregion

if ($null -eq $config.AdministrativeUnit -or $config.AdministrativeUnit.Count -eq 0) {
    Write-Verbose "No administrative unit definitions found in the project configuration. Exiting..."
    exit
}

$DirectoryRoleDefinitions = $null
$TenantIsPIMEnabled = $null
$ConfirmedMgPermission = $false
$ConfirmedMgPermissionPrivileged = $false
$ConfirmedEntraPermission = $false

$config.AdministrativeUnit.GetEnumerator() | Sort-Object -Property { $_.Value.DisplayName }, { $_.Name } | & {
    process {
        $configValue = $_.Value

        $currentValue = $null
        if (-not [string]::IsNullOrEmpty($configValue.Id)) {
            if ($AdministrativeUnit -and $AdministrativeUnit -notcontains $configValue.Id) { return }
            Write-Verbose "Searching for administrative unit with ID '$($configValue.Id)'"
            $params = @{
                OutputType  = 'PSObject'
                Method      = 'GET'
                Uri         = "https://graph.microsoft.com/beta/administrativeUnits/$($configValue.Id)"
                ErrorAction = 'SilentlyContinue'
            }
            $params.Verbose = $false
            $currentValue = Invoke-MgGraphRequest @params
        }
        elseif (-not [string]::IsNullOrEmpty($configValue.DisplayName)) {
            if ($AdministrativeUnit -and $AdministrativeUnit -notcontains $configValue.DisplayName) { return }
            Write-Verbose "Searching for administrative unit with display name '$($configValue.DisplayName)'"
            $params = @{
                OutputType  = 'PSObject'
                Method      = 'GET'
                Uri         = "https://graph.microsoft.com/beta/administrativeUnits/?`$filter=displayName eq '$($configValue.DisplayName)'"
                ErrorAction = 'SilentlyContinue'
            }
            $params.Verbose = $false
            $currentValue = (Invoke-MgGraphRequest @params).Value
            if ($currentValue.Count -gt 1) {
                Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                Write-Host "$($configValue.DisplayName)"
                Write-Error "Multiple administrative units found with the same name '$($configValue.DisplayName)'. Please ensure that the administrative unit names are unique, or add Object ID to configuration."
                return
            }
            $currentValue = $currentValue[0]
        }
        else {
            Write-Error "Mandatory property 'Id' or 'DisplayName' is missing or null in the administrative unit definition '$($_.Key)'."
            return
        }

        if ($null -ne $configValue.MembershipRule) {
            Write-Verbose " Removing common leading whitespace from the membership rule."
            $minLeadingWhitespaces = $configValue.MembershipRule -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { ($_ -match '^(\s*)' | Out-Null); $matches[1].Length } | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
            Write-Verbose "  Minimum leading whitespaces: $minLeadingWhitespaces"
            $configValue.MembershipRule = [System.Text.RegularExpressions.Regex]::Replace($configValue.MembershipRule, "^[\s]{0,$minLeadingWhitespaces}", '', 'Multiline')
        }

        if ($null -eq $currentValue) {
            Write-Host "    (Missing) " -NoNewline -ForegroundColor White
            Write-Host "$($configValue.DisplayName)" -NoNewline
            Write-Host $(if ([string]::IsNullOrEmpty($configValue.Description)) { '' } else { "`n              $($configValue.Description)" }) -ForegroundColor DarkGray

            if ($PSCmdlet.ShouldProcess(
                    "Create Administrative Unit '$($configValue.DisplayName)' in tenant $($config.local.AutomationAccount.TenantId)",
                    "Do you confirm to create Administrative Unit '$($configValue.DisplayName)' in tenant $($config.local.AutomationAccount.TenantId) ?",
                    "Create Administrative Units in tenant $($config.local.AutomationAccount.TenantId)"
                )) {

                #region Connect to Microsoft Graph
                try {
                    Push-Location
                    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                    $connectParams = @{
                        Tenant = $config.local.AutomationAccount.TenantId
                        Scopes = @(
                            'AdministrativeUnit.ReadWrite.All'
                        )
                    }
                    if (-not $ConfirmedMgPermission) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermission = $true }
                }
                catch {
                    Write-Error "Insufficent Microsoft Graph permissions: Scope 'AdministrativeUnit.ReadWrite.All' is required to continue setup of administrative units."
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
                    if (-not $ConfirmedEntraPermission) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermission = $true }
                }
                catch {
                    Write-Error "Insufficent Microsoft Entra permissions: At least 'Privileged Role Administrator' directory role is required to setup Administrative Units in Microsoft Entra." -ErrorAction Stop
                    exit
                }
                finally {
                    Pop-Location
                }
                #endregion

                try {
                    $params = @{
                        OutputType = 'PSObject'
                        Method     = 'POST'
                        Uri        = "https://graph.microsoft.com/beta/administrativeUnits"
                        Body       = $configValue.Clone()
                    }
                    $params.Body.Remove('Id')
                    $params.Body.Remove('InitialRoleAssignment')
                    if ($commonBoundParameters) { $params += $commonBoundParameters }
                    $currentValue = Invoke-MgGraphRequest @params
                    Write-Host "    (Ok)      " -NoNewline -ForegroundColor Green
                    Write-Host "$($currentValue.DisplayName) ($($currentValue.Id))"
                }
                catch {
                    Write-Error "$_" -ErrorAction Stop
                    return
                }

                if ($null -eq $configValue.InitialRoleAssignment -or $configValue.InitialRoleAssignment.Count -eq 0) { return }

                Write-Host "`n                Directory Roles:"

                if ($null -eq $DirectoryRoleDefinitions) { $DirectoryRoleDefinitions = Get-MgRoleManagementDirectoryRoleDefinition }
                if ($null -eq $TenantIsPIMEnabled) {
                    $TenantHasPremiumP2 = ((Invoke-MgGraphRequest -Method 'GET' -Uri "https://graph.microsoft.com/v1.0/organization" -OutputType 'PSObject' -ErrorAction 'Stop').Value.AssignedPlans | Where-Object ServicePlanId -eq '41781fb2-bc02-4b7c-bd55-b576c07bb09d' | Sort-Object AssignedDateTime | Select-Object -Last 1).CapabilityStatus -eq 'Enabled'
                    Write-Verbose "Microsoft Entra ID P2 licensing for Privileged Identity Management is: $(if ($TenantHasPremiumP2) { 'available' } else { 'NOT available' })"
                }

                foreach ($Role in ($configValue.InitialRoleAssignment | Sort-Object DisplayName, RoleTemplateId)) {
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

                    $currentUser = Get-MgUser -UserId (Get-MgContext).Account -ErrorAction Stop

                    if ($TenantHasPremiumP2 -and $configValue.IsMemberManagementRestricted -and $Role.AssignmentType -eq 'Eligible') {
                        Write-Verbose "  Role assignment type is 'Eligible'. Implicitly adding scheduled active assignment to allow continuation of the setup with management restricted admin unit."

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
                            if (-not $ConfirmedMgPermissionPrivileged) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermissionPrivileged = $true }
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Graph permissions: Scope 'RoleManagement.ReadWrite.Directory' is required to assign directory roles in administrative units." -ErrorAction Stop
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                        #endregion

                        $maxRetries = 10
                        $retryCount = 0
                        $wait = 4
                        while ($true) {
                            try {
                                $params = @{
                                    BodyParameter = @{
                                        PrincipalId      = $currentUser.Id
                                        RoleDefinitionId = $RoleDefinition.Id
                                        Justification    = "Initial scripted setup of Management Restricted Administrative Unit $($currentValue.DisplayName) ($($currentValue.Id))"
                                        DirectoryScopeId = "/administrativeUnits/$($currentValue.Id)"
                                        Action           = 'AdminAssign'
                                        ScheduleInfo     = @{
                                            StartDateTime = Get-Date
                                            Expiration    = @{
                                                Type     = 'AfterDuration'
                                                Duration = 'PT2H'
                                            }
                                        }
                                    }
                                }
                                if ($commonBoundParameters) { $params += $commonBoundParameters }
                                $params.ErrorAction = 'Stop'
                                $roleAssignment = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest @params
                                Write-Verbose "Temporal active role assignment added for role '$($RoleDefinition.DisplayName)' in management restirected administrative unit '$($currentValue.DisplayName)' for current user $($currentUser.UserPrincipalName). Expires in: 2 hours"
                                break
                            }
                            catch {
                                if (($_.Exception.Message -like '*resource is not found*' -or $_.Exception.Message -like '*An error has occurred*') -and $retryCount -lt $maxRetries) {
                                    Write-Verbose "Resource $($params.BodyParameter.DirectoryScopeId) not found or server error occurred, waiting for it to be available ..."
                                    Start-Sleep -Seconds $wait
                                    $retryCount++
                                }
                                else {
                                    Write-Error "$_" -ErrorAction Stop
                                }
                            }
                        }
                    }

                    Write-Host "                    (Missing) " -NoNewline -ForegroundColor White
                    Write-Host "$($RoleDefinition.DisplayName) (Id: $($RoleDefinition.Id), Administrative Unit: $($currentValue.DisplayName))`n                              " -NoNewline
                    Write-Host $RoleDefinition.Description -ForegroundColor DarkGray

                    if ($PSCmdlet.ShouldContinue(
                            "Add Entra directory role '$($Role.DisplayName)' in Administrative Unit '$($currentValue.DisplayName)' for current user $($currentUser.UserPrincipalName)",
                            "Do you confirm to add Entra directory role '$($Role.DisplayName)' in Administrative Unit '$($currentValue.DisplayName)' for current user $($currentUser.UserPrincipalName) ?"
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
                            if (-not $ConfirmedMgPermissionPrivileged) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermissionPrivileged = $true }
                        }
                        catch {
                            Write-Error "Insufficent Microsoft Graph permissions: Scope 'RoleManagement.ReadWrite.Directory' is required to assign directory roles in administrative units." -ErrorAction Stop
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                        #endregion

                        if ($TenantHasPremiumP2) {
                            $maxRetries = 10
                            $retryCount = 0
                            $wait = 4
                            while ($true) {
                                try {
                                    $params = @{
                                        BodyParameter = @{
                                            PrincipalId      = $currentUser.Id
                                            RoleDefinitionId = $RoleDefinition.Id
                                            Justification    = if ($configValue.InitialRoleAssignment.Justification) { $configValue.InitialRoleAssignment.Justification } else { "Initial scripted setup of Administrative Unit $($currentValue.DisplayName) ($($currentValue.Id))" }
                                            DirectoryScopeId = "/administrativeUnits/$($currentValue.Id)"
                                            Action           = 'AdminAssign'
                                            ScheduleInfo     = @{
                                                StartDateTime = Get-Date
                                            }
                                        }
                                    }
                                    if ($configValue.InitialRoleAssignment.Duration) { $params.BodyParameter.ScheduleInfo.Expiration = @{ Type = 'AfterDuration'; Duration = $configValue.InitialRoleAssignment.Duration } }
                                    if ($commonBoundParameters) { $params += $commonBoundParameters }
                                    $params.ErrorAction = 'Stop'
                                    $roleAssignment = $null
                                    if ($null -eq $configValue.AssignmentType -or $configValue.AssignmentType -eq 'Eligible') {
                                        $roleAssignment = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest @params
                                    }
                                    elseif ($configValue.AssignmentType -eq 'Active') {
                                        $roleAssignment = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest @params
                                    }
                                    else {
                                        Write-Error "Invalid value '$($configValue.AssignmentType)' for property 'AssignmentType' in the administrative unit definition '$($_.Key)'. Valid values are 'Eligible' or 'Active'." -ErrorAction Stop
                                        exit
                                    }
                                    break
                                }
                                catch {
                                    if (($_.Exception.Message -like '*resource is not found*' -or $_.Exception.Message -like '*An error has occurred*') -and $retryCount -lt $maxRetries) {
                                        Write-Verbose "Resource $($params.BodyParameter.DirectoryScopeId) not found or server error occurred, waiting for it to be available ..."
                                        Start-Sleep -Seconds $wait
                                        $retryCount++
                                    }
                                    else {
                                        Write-Error "$_" -ErrorAction Stop
                                    }
                                }
                            }
                        }
                        else {
                            Write-Verbose " Tenant does not have Microsoft Entra ID P2 licensing for Privileged Identity Management. Using classic role assignment."

                            if ($Role.AssignmentType -eq 'Eligible') {
                                Write-Warning "Tenant does not have Microsoft Entra ID P2 licensing for Privileged Identity Management. Role assignment type 'Eligible' is not supported. Falling back to classic role assignment."
                            }

                            $maxRetries = 10
                            $retryCount = 0
                            $wait = 4
                            while ($true) {
                                try {
                                    $params = @{
                                        BodyParameter = @{
                                            PrincipalId      = $currentUser.Id
                                            RoleDefinitionId = $RoleDefinition.Id
                                            DirectoryScopeId = "/administrativeUnits/$($currentValue.Id)"
                                        }
                                    }
                                    if ($commonBoundParameters) { $params += $commonBoundParameters }
                                    $params.ErrorAction = 'Stop'
                                    $null = New-MgRoleManagementDirectoryRoleAssignment @params
                                }
                                catch {
                                    if (($_.Exception.Message -like '*resource is not found*' -or $_.Exception.Message -like '*An error has occurred*') -and $retryCount -lt $maxRetries) {
                                        Write-Verbose "Resource $($params.BodyParameter.DirectoryScopeId) not found or server error occurred, waiting for it to be available ..."
                                        Start-Sleep -Seconds $wait
                                        $retryCount++
                                    }
                                    else {
                                        Write-Host "                    (ERROR)   " -NoNewline -ForegroundColor Red
                                        Write-Host "$($RoleDefinition.DisplayName) (Id: $($RoleDefinition.Id), Administrative Unit: $($currentValue.DisplayName))`n                              "
                                        Write-Error "$_" -ErrorAction Stop
                                        exit
                                    }
                                }
                            }
                        }

                        Write-Host "                    (Ok)      " -NoNewline -ForegroundColor Green
                        Write-Host "$($RoleDefinition.DisplayName) (Id: $($RoleDefinition.Id), Administrative Unit: $($currentValue.DisplayName))`n                              "
                    }
                }
            }
        }
        else {
            if (
                $null -ne $configValue.IsMemberManagementRestricted -and
                $currentValue.IsMemberManagementRestricted -ne $configValue.IsMemberManagementRestricted
            ) {
                Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                Write-Host "$($currentValue.DisplayName) ($($currentValue.Id))" -NoNewline
                Write-Host $(if ([string]::IsNullOrEmpty($currentValue.Description)) { '' } else { "`n              $($currentValue.Description)" }) -ForegroundColor DarkGray
                Write-Error "Administrative unit '$($currentValue.DisplayName)' must have property 'IsMemberManagementRestricted' set to '$($configValue.IsMemberManagementRestricted)'. This cannot be changed after the administrative unit is created." -ErrorAction Stop
                return
            }

            if (
                $null -ne $configValue.Visibility -and
                $currentValue.Visibility -ne $configValue.Visibility
            ) {
                Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                Write-Host "$($currentValue.DisplayName) ($($currentValue.Id))" -NoNewline
                Write-Host $(if ([string]::IsNullOrEmpty($currentValue.Description)) { '' } else { "`n              $($currentValue.Description)" }) -ForegroundColor DarkGray
                Write-Error "Administrative unit '$($currentValue.DisplayName)' must have property 'Visibility' set to '$($configValue.Visibility)'. This cannot be changed after the administrative unit is created." -ErrorAction Stop
                return
            }

            $updateProperty = @{}

            # Iterate over the keys in the hashtable
            $configValue.Keys | ForEach-Object {
                if (@('@odata.context', 'Id', 'DeletedDateTime', 'IsMemberManagementRestricted', 'Visibility', 'AdditionalProperties', 'InitialRoleAssignment') -contains $_) { return }
                $key = $_

                # If the property exists in $currentValue
                if (@($currentValue.PSObject.Properties.Name) -contains $key) {
                    # If the value has changed, add it to $updateProperty
                    if ($currentValue.$key -ne $configValue.$key) {
                        Write-Verbose " Property '$key' has changed for the administrative unit '$($currentValue.DisplayName)'."
                        $updateProperty.$key = $configValue.$key
                    }
                    else {
                        Write-Verbose " Property '$key' has not changed for the administrative unit '$($currentValue.DisplayName)'."
                    }
                }
                # If the property does not exist in $currentValue but exists in the hashtable, output a warning
                elseif ($null -ne $configValue.$key) {
                    Write-Warning "Property '$key' seems to be an invalid property for the administrative unit '$($currentValue.DisplayName)'."
                }
            }

            # Iterate over the properties in $currentValue
            $currentValue.PSObject.Properties.Name | ForEach-Object {
                if (@('@odata.context', 'Id', 'DeletedDateTime', 'IsMemberManagementRestricted', 'Visibility', 'AdditionalProperties') -contains $_) { return }
                $property = $_

                # If the property does not exist in the hashtable but exists in $currentValue, set it to null in $updateProperty to clear it
                if ($null -eq $configValue.$property -and $null -ne $currentValue.$property) {
                    Write-Verbose " Property '$property' has been removed for the administrative unit '$($currentValue.DisplayName)'."
                    $updateProperty.$property = $null
                }
            }

            if ($updateProperty.Count -gt 0) {
                Write-Host "    (Update)  " -NoNewline -ForegroundColor Yellow
                Write-Host "$($currentValue.DisplayName) ($($currentValue.Id))" -NoNewline
                Write-Host $(if ([string]::IsNullOrEmpty($currentValue.Description)) { '' } else { "`n              $($currentValue.Description)" }) -ForegroundColor DarkGray

                if ($PSCmdlet.ShouldProcess(
                        "Update Administrative Unit '$($configValue.DisplayName)' $(if($updateProperty.Count -eq 1) {'property'} else {'properties'}; ($updateProperty.Keys | ForEach-Object { "'$_'" }) -join ', ' ) in tenant $($config.local.AutomationAccount.TenantId)",
                        "Do you confirm to update Administrative Unit '$($configValue.DisplayName)' $(if($updateProperty.Count -eq 1) {'property'} else {'properties'}; ($updateProperty.Keys | ForEach-Object { "'$_'" }) -join ', ' ) in tenant $($config.local.AutomationAccount.TenantId) ?",
                        "Update Administrative Units in tenant $($config.local.AutomationAccount.TenantId)"
                    )) {

                    #region Connect to Microsoft Graph
                    try {
                        Push-Location
                        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                        $connectParams = @{
                            Tenant = $config.local.AutomationAccount.TenantId
                            Scopes = @(
                                'AdministrativeUnit.ReadWrite.All'
                            )
                        }
                        if (-not $ConfirmedMgPermission) { .\Common_0001__Connect-MgGraph.ps1 @connectParams; $ConfirmedMgPermission = $true }
                    }
                    catch {
                        Write-Error "Insufficent Microsoft Graph permissions: Scope 'AdministrativeUnit.ReadWrite.All' is required to continue setup of administrative units."
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
                        if (-not $ConfirmedEntraPermission) { $null = ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 @confirmParams; $ConfirmedEntraPermission = $true }
                    }
                    catch {
                        Write-Error "Insufficent Microsoft Entra permissions: At least 'Privileged Role Administrator' directory role is required to setup Administrative Units in Microsoft Entra." -ErrorAction Stop
                        exit
                    }
                    finally {
                        Pop-Location
                    }
                    #endregion

                    try {
                        $params = @{
                            OutputType = 'PSObject'
                            Method     = 'PATCH'
                            Uri        = "https://graph.microsoft.com/beta/administrativeUnits/$($currentValue.Id)"
                            Body       = $updateProperty
                        }
                        if ($commonBoundParameters) { $params += $commonBoundParameters }
                        $null = Invoke-MgGraphRequest @params
                        Write-Host "    (Ok)      " -NoNewline -ForegroundColor Green
                        Write-Host "$($currentValue.DisplayName) ($($currentValue.Id))"
                    }
                    catch {
                        Write-Host "    (ERROR)   " -NoNewline -ForegroundColor Red
                        Write-Host "$($currentValue.DisplayName) ($($currentValue.Id))"
                        Write-Error "$_" -ErrorAction Stop
                        return
                    }
                }

                return
            }

            Write-Host "    (Ok)      " -NoNewline -ForegroundColor Green
            Write-Host "$($currentValue.DisplayName) ($($currentValue.Id))" -NoNewline
            Write-Host $(if ([string]::IsNullOrEmpty($currentValue.Description)) { '' } else { "`n              $($currentValue.Description)" }) -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n`nThe administrative unit setup has been completed." -ForegroundColor White

Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
