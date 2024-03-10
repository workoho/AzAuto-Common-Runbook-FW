<#PSScriptInfo
.VERSION 1.0.0
.GUID 6e743a97-b12c-4ed5-9e78-2bea73e4defb
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
    Sets up the Azure Automation runtime environment and installs packages.

.DESCRIPTION
    This script sets up the Azure Automation runtime environment and installs packages based on the project configuration.
    It reads the project configuration file, connects to Azure, retrieves the runtime environments, and checks for installed packages.
    If a package needs to be updated or installed, it triggers the installation process.

.PARAMETER RuntimeEnvironmentName
    Specifies the name of the runtime environment. If provided, only the specified runtime environment will be processed.

.PARAMETER RuntimeEnvironmentPackage
    Specifies the name of the package. If provided, only the specified package will be processed.

.EXAMPLE
    Set-AzAutomationRuntimeEnvironment -RuntimeEnvironmentName 'Dev' -RuntimeEnvironmentPackage 'Package1'
    This example sets up the 'Dev' runtime environment and installs 'Package1' in the Azure Automation account.
#>

#Requires -Module @{ ModuleName='Az.Accounts'; ModuleVersion='2.16.0' }
#Requires -Module @{ ModuleName='Az.Resources'; ModuleVersion='6.16.0' }
#Requires -Module @{ ModuleName='Az.Automation'; ModuleVersion='1.10.0' }

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'High'
)]
Param (
    [array]$RuntimeEnvironmentName,
    [array]$RuntimeEnvironmentPackage
)

if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    Write-Error 'This script must be run interactively by a privileged administrator account.' -ErrorAction Stop
    exit
}
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

Write-Host "`n`nRuntime Environment and Package Setup`n=====================================" -ForegroundColor White

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
    'AutomationRuntimeEnvironment'
) | & {
    process {
        if ($null -eq $config.$_) {
            Write-Error "Mandatory property '/PrivateData/$_' is missing or null in the AzAutoFWProject.psd1 configuration file." -ErrorAction Stop
            exit
        }
    }
}
$config.AutomationRuntimeEnvironment.GetEnumerator() | & {
    process {
        $name = $_.Name
        $properties = $_.Value
        @(
            'Runtime'
            'Packages'
        ) | & {
            process {
                if ($null -eq $properties.$_) {
                    Write-Error "Mandatory property '/PrivateData/AutomationRuntimeEnvironment/$name/$_' is missing or null in the AzAutoFWProject.psd1 configuration file." -ErrorAction Stop
                    exit
                }
                elseif ($_ -eq 'Runtime') {
                    @(
                        'Language'
                        'Version'
                    ) | & {
                        process {
                            if ($null -eq $properties.Runtime.$_) {
                                Write-Error "Mandatory property '/PrivateData/AutomationRuntimeEnvironment/$name/Runtime/$_' is missing or null in the AzAutoFWProject.psd1 configuration file." -ErrorAction Stop
                                exit
                            }
                        }
                    }
                }
            }
        }
    }
}

$SubscriptionScope = "/subscriptions/$($config.local.AutomationAccount.SubscriptionId)"
$RgScope = "$SubscriptionScope/resourcegroups/$($config.local.AutomationAccount.ResourceGroupName)"
$SelfScope = "$RgScope/providers/Microsoft.Automation/automationAccounts/$($config.local.AutomationAccount.Name)"
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

#region Confirm Azure Role Assignments
try {
    Push-Location
    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
    $confirmParams = @{
        Roles = @{
            $SelfScope = 'Reader'
        }
    }
    if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
    $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams
}
catch {
    Write-Error "Insufficent Azure permissions: At least 'Reader' role for the Automation Account is required to validate runtime environments. Further permissions may be required to perform changes." -ErrorAction Stop
    $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
    exit
}
finally {
    Pop-Location
}
#endregion

#region Get Runtime Environments
$AzApiVersion = '2023-05-15-preview'
try {
    Push-Location
    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
    $params = @{
        ResourceGroupName = $automationAccount.ResourceGroupName
        Provider          = 'Microsoft.Automation'
        ResourceType      = 'automationAccounts'
        ResourceName      = $automationAccount.AutomationAccountName
        SubResourceUri    = 'runtimeEnvironments'
        ApiVersion        = $AzApiVersion
        Method            = 'Get'
    }
    if ($commonBoundParameters) { $params += $commonBoundParameters }
    $runtimeEnvironments = (.\Common_0002__Invoke-AzRequest.ps1 @params).Value
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Stop
    exit
}
finally {
    Pop-Location
}
#endregion

$ConfirmedAzPermission = $false
$config.AutomationRuntimeEnvironment.GetEnumerator() | Sort-Object { if ($_.Key -match '^PowerShell-|^Python-') { 0 } else { 1 }, $_.Key } | & {
    process {
        if ($RuntimeEnvironmentName -and ($RuntimeEnvironmentName -notcontains $_.Key)) { return }
        $runtimeEnvironment = $runtimeEnvironments | Where-Object Name -eq $_.Key
        if ($runtimeEnvironment) {
            Write-Verbose "Found runtimeEnvironment.language: $($_.Value.Runtime.Language)"
            Write-Verbose "Found runtimeEnvironment.version : $($_.Value.Runtime.Version)"
        }

        if ($_.Value.runtime.language -eq 'PowerShell') {
            Write-Host "`n    $($_.Key)`n" -ForegroundColor White

            # Assuming system-generated environments will always follow the naming convention '<Language>-<Version>'
            if ($_.Key -eq ($_.Value.runtime.language, $_.Value.runtime.version -join '-')) {
                Write-Verbose "Runtime environment '$($_.Key)' is system-generated and read-only."

                Write-Verbose "Getting installed packages for runtime environment '$($runtimeEnvironment.Name)' ..."
                $installedPackages = Get-AzAutomationModule `
                    -ResourceGroupName $automationAccount.ResourceGroupName `
                    -AutomationAccountName $automationAccount.AutomationAccountName

                $_.Value.Packages.GetEnumerator() | & {
                    process {
                        if ($RuntimeEnvironmentPackage -and ($RuntimeEnvironmentPackage -notcontains $_.Name)) { return }
                        if ($null -ne $_.IsDefault -and $_.IsDefault -eq $true) { return }
                        $packageName = $_.Name
                        $package = $installedPackages | Where-Object { $_.Name -eq $packageName -and $_.IsGlobal -ne $true }
                        $installedVersion = $package.Version

                        if (
                            (-Not $package) -or
                            ($package.provisioningState -eq 'Failed') -or
                            (-not $package.Version) -or
                            (
                                ([System.Version]$package.Version -ne [System.Version]$_.Version) -and
                                $package.provisioningState -ne 'Succeeded'
                            )
                        ) {

                            #region Confirm Azure Role Assignments
                            try {
                                Push-Location
                                Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                                $confirmParams = @{
                                    Roles = @{
                                        $SelfScope = 'Automation Contributor'
                                    }
                                }
                                if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                                if (-not $ConfirmedAzPermission) { $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams; $ConfirmedAzPermission = $true }
                            }
                            catch {
                                Write-Error "Insufficent Azure permissions: At least 'Automation Contributor' role for the Automation Account is required to setup automation runtime environments." -ErrorAction Stop
                                $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
                                exit
                            }
                            finally {
                                Pop-Location
                            }
                            #endregion

                            # Trigger installation of the package if it is not already in progress
                            if (
                                (-Not $package) -or
                                ($package.provisioningState -ne 'Creating')
                            ) {
                                Write-Verbose "Package '$($_.Name)' version $($_.Version) needs to be $(if($package.Version) {'updated'} else {'installed'})."
                                $params = @{
                                    ResourceGroupName     = $automationAccount.ResourceGroupName
                                    AutomationAccountName = $automationAccount.AutomationAccountName
                                    RuntimeVersion        = $runtimeEnvironment.properties.runtime.version
                                    Name                  = $_.Name
                                    ContentLinkUri        = "https://www.powershellgallery.com/api/v2/package/$($_.Name)/$($_.Version)"
                                }
                                if ($commonBoundParameters) { $params += $commonBoundParameters }

                                Write-Host "    (Missing)                 " -NoNewline -ForegroundColor White
                                Write-Host "$($_.Name) (Version: $($_.Version))"
                                if ($PSCmdlet.ShouldProcess(
                                        "$(if ($package.Version) {'Update'} else {'Install'}) package '$($_.Name)' v$($_.Version) in runtime environment '$($runtimeEnvironment.Name)' of '$($automationAccount.AutomationAccountName)'",
                                        "Do you confirm to $(if ($package.Version) {'update'} else {'install'}) package '$($_.Name)' v$($_.Version) in runtime environment '$($runtimeEnvironment.Name)' of '$($automationAccount.AutomationAccountName)' ?",
                                        "$(if ($package.Version) {'Update'} else {'Install'}) package in Runtime Environment"
                                    )) {
                                    Write-Host "    $(if ($package.Version) {'(Importing newer version)'} else {'(Importing)              '}) " -NoNewline -ForegroundColor Yellow
                                    Write-Host "$($_.Name) (Version: $($_.Version))"
                                    $null = New-AzAutomationModule @params
                                }
                                else {
                                    return
                                }
                            }
                            else {
                                Write-Host "    $(if ($package.Version) {'(Importing newer version)'} else {'(Importing)              '}) " -NoNewline -ForegroundColor Yellow
                                Write-Host "$($_.Name) (Version: $($_.Version))"
                            }

                            # Wait for package installation
                            $DoLoop = $true
                            $RetryCount = 1
                            $WaitSec = 3

                            do {
                                $params = @{
                                    ResourceGroupName     = $automationAccount.ResourceGroupName
                                    AutomationAccountName = $automationAccount.AutomationAccountName
                                    RuntimeVersion        = $runtimeEnvironment.properties.runtime.version
                                    Name                  = $_.Name
                                }
                                if ($commonBoundParameters) { $params += $commonBoundParameters }

                                $package = Get-AzAutomationModule @params
                                Write-Verbose "Waiting for package '$($_.Name)' version $($_.Version): '$($package.provisioningState)'"

                                if ($package.provisioningState -eq 'Succeeded') {
                                    Write-Host "    (Available)               " -NoNewline -ForegroundColor Green
                                    Write-Host "$($_.Name) (Version: $($_.Version))"
                                    $DoLoop = $false
                                }
                                if ($package.provisioningState -eq 'Failed') {
                                    Write-Host "    (FAILED)                  " -NoNewline -ForegroundColor Red
                                    Write-Host "$($_.Name) (Version: $($_.Version))"
                                    $DoLoop = $false
                                }
                                else {
                                    $RetryCount += 1
                                    Start-Sleep -Seconds $WaitSec
                                }
                            } While ($DoLoop)
                        }
                        else {
                            Write-Host "    (Available)               " -NoNewline -ForegroundColor Green
                            Write-Host "$($_.Name) (Version: $($_.Version))"
                        }
                    }
                }
            }
            else {
                Write-Verbose "Runtime environment '$($_.Key)' is user generated and writeable."

                try {
                    Push-Location
                    Set-Location (Join-Path $config.Project.Directory 'Runbooks')

                    $packages = @{}
                    $_.Value.Packages.GetEnumerator() | & {
                        process {
                            if ($RuntimeEnvironmentPackage -and ($RuntimeEnvironmentPackage -notcontains $_.Name)) { return }
                            if ($null -eq $_.IsDefault -or $_.IsDefault -eq $false) { return }
                            $installedVersion = $runtimeEnvironment.properties.defaultPackages.$($_.Name)
                            if (
                                -not $installedVersion -or
                            ([System.Version]$installedVersion -ne [System.Version]$_.Version)
                            ) {
                                Write-Verbose "Default package '$($_.Name)' version $($_.Version) needs to be set."
                                $packages[$_.Name] = $_.Version
                            }
                            else {
                                Write-Verbose "Default package '$($_.Name)' version $($_.Version) is already set."
                            }
                        }
                    }

                    if ($packages.Count -gt 0) {

                        #region Confirm Azure Role Assignments
                        try {
                            Push-Location
                            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                            $confirmParams = @{
                                Roles = @{
                                    $SelfScope = 'Automation Contributor'
                                }
                            }
                            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                            if (-not $ConfirmedAzPermission) { $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams; $ConfirmedAzPermission = $true }
                        }
                        catch {
                            Write-Error "Insufficent Azure permissions: At least 'Automation Contributor' role for the Automation Account is required to setup automation runtime environments." -ErrorAction Stop
                            $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                        #endregion

                        $params = @{
                            ResourceGroupName = $automationAccount.ResourceGroupName
                            Provider          = 'Microsoft.Automation'
                            ResourceType      = 'automationAccounts'
                            ResourceName      = $automationAccount.AutomationAccountName
                            SubResourceUri    = "runtimeEnvironments/$($_.Key)"
                            ApiVersion        = $AzApiVersion
                            Method            = if (-not $runtimeEnvironment) { 'Put' } else { 'Patch' }
                            Body              = @{
                                properties = @{
                                    runtime         = @{
                                        language = $_.Value.Runtime.Language
                                        version  = $_.Value.Runtime.Version
                                    }
                                    defaultPackages = $packages
                                }
                                name       = $_.Key
                            }
                        }
                        if (-not [string]::IsNullOrEmpty($_.Value.Description)) { $params.Body.properties.description = $_.Value.Description }
                        if ($commonBoundParameters) { $params += $commonBoundParameters }

                        if ($PSCmdlet.ShouldProcess(
                                "$(if ($runtimeEnvironment) {'Update'} else {'Create'}) Runtime Environment '$($_.Name)' in '$($automationAccount.AutomationAccountName)'",
                                "Do you confirm to $(if ($runtimeEnvironment) {'update'} else {'create'}) Runtime Environment '$($_.Name)' in '$($automationAccount.AutomationAccountName)' ?",
                                "$(if ($runtimeEnvironment) {'Update'} else {'Create'}) Runtime Environment in Azure Automation Account"
                            )) {

                            try {
                                $null = .\Common_0002__Invoke-AzRequest.ps1 @params
                                Write-Host "   $(if ($runtimeEnvironment) {'Updated'} else {'Created'}) " -NoNewline -ForegroundColor White
                                Write-Host "Runtime Environment : $($_.Key)"
                                $runtimeEnvironment = $params.Body
                            }
                            catch {
                                Write-Host "   FAILED to $(if ($runtimeEnvironment) {'update'} else {'create'}) " -NoNewline -ForegroundColor White
                                Write-Host "Runtime Environment : $($_.Key)"
                                Write-Error "$_"
                                if (-not $runtimeEnvironment) { return }
                            }
                        }
                        elseif (-not $runtimeEnvironment) { return }
                    }

                    $installedPackages = $null
                    if ($runtimeEnvironment) {
                        Write-Verbose "Getting installed packages for runtime environment '$($runtimeEnvironment.Name)' ..."
                        $params = @{
                            ResourceGroupName = $automationAccount.ResourceGroupName
                            Provider          = 'Microsoft.Automation'
                            ResourceType      = 'automationAccounts'
                            ResourceName      = $automationAccount.AutomationAccountName
                            SubResourceUri    = "runtimeEnvironments/$($runtimeEnvironment.Name)/packages"
                            ApiVersion        = $AzApiVersion
                            Method            = 'Get'
                        }
                        if ($commonBoundParameters) { $params += $commonBoundParameters }
                        $installedPackages = (.\Common_0002__Invoke-AzRequest.ps1 @params).Value
                    }

                    $_.Value.Packages.GetEnumerator() | & {
                        process {
                            if ($RuntimeEnvironmentPackage -and ($RuntimeEnvironmentPackage -notcontains $_.Name)) { return }
                            if ($null -ne $_.IsDefault -and $_.IsDefault -eq $true) { return }
                            $package = ($installedPackages | Where-Object Name -eq $_.Name).properties
                            $installedVersion = $package.Version

                            if (
                                (-Not $package) -or
                                ($package.provisioningState -eq 'Failed') -or
                                (-not $package.Version) -or
                                (
                                    ([System.Version]$package.Version -ne [System.Version]$_.Version) -and
                                    $package.provisioningState -ne 'Succeeded'
                                )
                            ) {

                                #region Confirm Azure Role Assignments
                                try {
                                    Push-Location
                                    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                                    $confirmParams = @{
                                        Roles = @{
                                            $SelfScope = 'Automation Contributor'
                                        }
                                    }
                                    if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                                    if (-not $ConfirmedAzPermission) { $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams; $ConfirmedAzPermission = $true }
                                }
                                catch {
                                    Write-Error "Insufficent Azure permissions: At least 'Automation Contributor' role for the Automation Account is required to setup automation runtime environments." -ErrorAction Stop
                                    $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
                                    exit
                                }
                                finally {
                                    Pop-Location
                                }
                                #endregion

                                # Trigger installation of the package if it is not already in progress
                                if (
                                    (-Not $package) -or
                                    ($package.provisioningState -ne 'Creating')
                                ) {
                                    Write-Verbose "Package '$($_.Name)' version $($_.Version) needs to be $(if($package.Version) {'updated'} else {'installed'})."
                                    $params = @{
                                        ResourceGroupName = $automationAccount.ResourceGroupName
                                        Provider          = 'Microsoft.Automation'
                                        ResourceType      = 'automationAccounts'
                                        ResourceName      = $automationAccount.AutomationAccountName
                                        SubResourceUri    = "runtimeEnvironments/$($runtimeEnvironment.Name)/packages/$($_.Name)"
                                        ApiVersion        = $AzApiVersion
                                        Method            = 'Put'
                                        Body              = @{
                                            properties = @{
                                                contentLink = @{
                                                    uri     = "https://www.powershellgallery.com/api/v2/package/$($_.Name)/$($_.Version)"
                                                    version = $_.Version
                                                }
                                            }
                                        }
                                    }
                                    if ($commonBoundParameters) { $params += $commonBoundParameters }

                                    Write-Host "    (Missing)                 " -NoNewline -ForegroundColor White
                                    Write-Host "$($_.Name) (Version: $($_.Version))"
                                    if ($PSCmdlet.ShouldProcess(
                                            "$(if ($package.Version) {'Update'} else {'Install'}) package '$($_.Name)' v$($_.Version) in runtime environment '$($runtimeEnvironment.Name)' of '$($automationAccount.AutomationAccountName)'",
                                            "Do you confirm to $(if ($package.Version) {'update'} else {'install'}) package '$($_.Name)' v$($_.Version) in runtime environment '$($runtimeEnvironment.Name)' of '$($automationAccount.AutomationAccountName)' ?",
                                            "$(if ($package.Version) {'Update'} else {'Install'}) package in Runtime Environment"
                                        )) {
                                        Write-Host "    $(if ($package.Version) {'(Importing newer version)'} else {'(Importing)              '}) " -NoNewline -ForegroundColor Yellow
                                        Write-Host "$($_.Name) (Version: $($_.Version))"
                                        $null = .\Common_0002__Invoke-AzRequest.ps1 @params
                                    }
                                    else {
                                        return
                                    }
                                }
                                else {
                                    Write-Host "    $(if ($package.Version) {'(Importing newer version)'} else {'(Importing)              '}) " -NoNewline -ForegroundColor Yellow
                                    Write-Host "$($_.Name) (Version: $($_.Version))"
                                }

                                # Wait for package installation
                                $DoLoop = $true
                                $RetryCount = 1
                                $WaitSec = 3

                                do {
                                    $params = @{
                                        ResourceGroupName = $automationAccount.ResourceGroupName
                                        Provider          = 'Microsoft.Automation'
                                        ResourceType      = 'automationAccounts'
                                        ResourceName      = $automationAccount.AutomationAccountName
                                        SubResourceUri    = "runtimeEnvironments/$($runtimeEnvironment.Name)/packages/$($_.Name)"
                                        ApiVersion        = $AzApiVersion
                                        Method            = 'Get'
                                    }
                                    if ($commonBoundParameters) { $params += $commonBoundParameters }

                                    $package = (.\Common_0002__Invoke-AzRequest.ps1 @params).properties
                                    Write-Verbose "Waiting for package '$($_.Name)' version $($_.Version): '$($package.provisioningState)'"

                                    if ($package.provisioningState -eq 'Succeeded') {
                                        $DoLoop = $false
                                    }
                                    if ($package.provisioningState -eq 'Failed') {
                                        Write-Host "    (FAILED)                  " -NoNewline -ForegroundColor Red
                                        Write-Host "$($_.Name)"
                                        $DoLoop = $false
                                    }
                                    else {
                                        $RetryCount += 1
                                        Start-Sleep -Seconds $WaitSec
                                    }
                                } While ($DoLoop)
                            }
                            else {
                                Write-Host "    (Available)               " -NoNewline -ForegroundColor Green
                                Write-Host "$($_.Name) (Version: $($_.Version))"
                            }
                        }
                    }
                }
                catch {
                    Write-Error $_.Exception.Message
                }
                finally {
                    Pop-Location
                }
            }
        }
        else {
            Write-Warning "Runtime environment '$($_.Key)' is not PowerShell based and currently not supported by this script."
        }
    }
}
