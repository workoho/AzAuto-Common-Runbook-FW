<#PSScriptInfo
.VERSION 1.0.2
.GUID cf48a802-2939-4e1b-9d8a-42467edc4410
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
    Version 1.0.2 (2024-05-25)
    - Use Write-Host to avoid output to the pipeline, avoiding interpretation as shell commands
    - Improve automatic Git checkout
    - Improve error handling
    - Fix automatic update of project.template files
#>

<#
.SYNOPSIS
    This script shall not be run directly. It is called by the same naming script of the child project for further processing
    after the Azure Automation Common Runbook Framework was cloned successfully.

    This script then creates or updates symlinks for common runbooks.
    These are assumed to be required for the runbooks of the child project to run properly.

.DESCRIPTION
    This script will create symbolic links for all common runbooks in
    C:\Developer\AzAuto-Common-Runbook-FW\Runbooks to C:\Developer\AzAuto-Project.tmpl\Runbooks.

.EXAMPLE
    Update-AzAutoFWProject.ps1 -ChildConfig $config
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [hashtable]$ChildConfig,
    [switch]$VsCodeTask
)

if ((Get-PSCallStack).Count -le 1) { Write-Error 'This script must be called from your project''s sibling Update-AzAutoFWProject.ps1. Exiting ...' -ErrorAction Stop; exit 1 }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"

Get-ChildItem -Path $configDir -File -Filter '*.template.*' -Recurse | & {
    process {
        $targetPath = $_.FullName -replace '\.template\.(.+)$', '.$1'
        if (-not (Test-Path $targetPath)) {
            Write-Host "Copying template $_ to $targetPath"
            Copy-Item -Path $_.FullName -Destination $targetPath -Force
        }
    }
}

$config = & (Join-Path (Get-Item $PSScriptRoot).Parent.Parent.FullName 'scripts/AzAutoFWProject/Get-AzAutoFWConfig.ps1')

Write-Verbose "Framework directory: $($config.Project.Directory)"
Write-Verbose "Framework config directory: $($config.Config.Directory)"

#region Checkout desired version of the framework
try {
    Push-Location
    Set-Location $config.Project.Directory -ErrorAction Stop

    # Check if this is a git repository
    if (
        -not (Test-Path .git) -or
        (git rev-parse --is-inside-work-tree 2>&1) -ne $true
    ) {
        Write-Error "$($config.Project.Directory) is not a Git repository." -ErrorAction Stop
        exit 1
    }

    Write-Verbose 'Found Git repository.'

    $changes = git status --porcelain
    if ($changes) {
        Write-Warning "Automatic checkout of the desired version in the $(Split-Path $config.Project.Directory -Leaf) repository is disabled as long as there are uncommited changes.`n         Please commit or stash them if you would like to automatically switch versions based on your settings in AzAutoFWProject.psd1."
    }
    else {
        $remoteExists = git remote | Where-Object { $_ -eq 'origin' }
        if ($remoteExists) {
            Write-Verbose 'Fetching the latest tags from the remote repository'
            $retryCount = 0
            do {
                $fetchOutput = git fetch --tags --force 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $retryCount++
                    if ($retryCount -le 3) {
                        Write-Warning "Fetch failed, retrying in 5 seconds... ($retryCount/3)"
                        Start-Sleep -Seconds 5
                    }
                    else {
                        Write-Error $fetchOutput -ErrorAction Stop
                    }
                }
            } while ($LASTEXITCODE -ne 0)
        }
        else {
            Write-Verbose 'No remote repository named origin found. Skipping fetch operation.'
        }

        $currentBranch = git rev-parse --abbrev-ref HEAD
        $currentTag = git describe --tags --always
        $currentCommit = git rev-parse HEAD

        Write-Verbose "Current branch: $currentBranch"
        Write-Verbose "Current tag: $currentTag"

        $tags = git tag | Where-Object { $_ -match '^v\d+(\.\d+(\.\d+)?(-[a-zA-Z0-9\.]+)?)?$' }
        $LatestReleaseTag = if ($tags) {
            $tags |
            Where-Object { $_ -notmatch '-' } |
            Sort-Object { [Version]($_ -replace '^v') } |
            Select-Object -Last 1
        }

        Write-Verbose "Latest release tag: $LatestReleaseTag"

        if (
            $ChildConfig.GitReference -notin ('ModuleVersion', 'LatestRelease', 'latest')
        ) {
            $targetCommit = git rev-parse $($ChildConfig.GitReference)
            if ($currentCommit -ne $targetCommit) {
                Write-Host "Checking out Git branch or commit hash '$($ChildConfig.GitReference)'"
                $checkoutOutput = git checkout $($ChildConfig.GitReference) 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Error $checkoutOutput -ErrorAction Stop
                }

                $resetOutput = git reset --hard $($ChildConfig.GitReference) 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Error $resetOutput -ErrorAction Stop
                }
            }
            else {
                Write-Verbose "Git branch or commit hash '$($ChildConfig.GitReference)' is already checked out."
            }
        }
        elseif (
            $ChildConfig.GitReference -eq 'ModuleVersion' -and
            $tags -and
            $tags -contains $("v$($ChildConfig.ModuleVersion)")
        ) {
            $headRef = git symbolic-ref -q HEAD
            $headRef = $headRef -replace 'refs/heads/', '' -replace 'refs/tags/', ''

            if ($headRef -ne $("v$($ChildConfig.ModuleVersion)")) {
                Write-Host "Checking out Git reference ModuleVersion, Git tag v$($ChildConfig.ModuleVersion)"
                $checkoutOutput = git checkout $("v$($ChildConfig.ModuleVersion)") 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Error $checkoutOutput -ErrorAction Stop
                }

                $resetOutput = git reset --hard $("v$($ChildConfig.ModuleVersion)") 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Error $resetOutput -ErrorAction Stop
                }
            }
            else {
                Write-Verbose "Git reference ModuleVersion, Git tag v$($ChildConfig.ModuleVersion) is already checked out."
            }
        }
        elseif (
            $ChildConfig.GitReference -eq 'LatestRelease' -and
            $LatestReleaseTag
        ) {
            $headRef = git symbolic-ref -q HEAD
            $headRef = $headRef -replace 'refs/heads/', '' -replace 'refs/tags/', ''

            if ($headRef -ne $LatestReleaseTag) {
                Write-Host "Checking out Git reference LatestRelease, Git tag $LatestReleaseTag"
                $checkoutOutput = git checkout $LatestReleaseTag 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Error $checkoutOutput -ErrorAction Stop
                }

                $resetOutput = git reset --hard $LatestReleaseTag 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Error $resetOutput -ErrorAction Stop
                }
            }
            else {
                Write-Verbose "Git reference LatestRelease, Git tag $LatestReleaseTag is already checked out."
            }
        }
        elseif ($currentCommit -ne (& git rev-parse $currentBranch)) {
            Write-Host "Merging the latest changes from the current branch $currentBranch"
            $checkoutOutput = git merge origin/$currentBranch 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error $checkoutOutput -ErrorAction Stop
            }

            $resetOutput = git reset --hard 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error $resetOutput -ErrorAction Stop
            }
        }
        else {
            Write-Verbose "The current branch $currentBranch is up-to-date."
        }
    }
}
catch {
    Write-Error $_ -ErrorAction Stop
    exit 1
}
finally {
    Pop-Location
}
#endregion

#region Validate Symlink Compatibility on Windows
$canCreateSymlink = $true
$createOrUpdateSymlink = $true

if ([System.Environment]::OSVersion.Platform -eq "Win32NT") {
    function Test-SeCreateSymbolicLinkPrivilege {
        $privilege = 'SeCreateSymbolicLinkPrivilege'
        $whoamiOutput = whoami /priv

        # Check if the privilege is in the output and if it's enabled
        if ($whoamiOutput -match $privilege) {
            $privilegeStatus = ($whoamiOutput -split "`n" | Where-Object { $_ -match $privilege }).Split(',')[1].Trim()
            return $privilegeStatus -eq 'Enabled'
        }

        return $false
    }
    $hasSeCreateSymbolicLinkPrivilege = Test-SeCreateSymbolicLinkPrivilege
    $IsElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($IsElevated) {
        Write-Verbose 'Running in an elevated PowerShell session.'
        $canCreateSymlink = $true
    }
    elseif ($hasSeCreateSymbolicLinkPrivilege) {
        Write-Verbose 'The current user has the required permissions to create symbolic links.'
        $canCreateSymlink = $true
    }
    else {
        Write-Verbose 'The current user does not have the required permissions to create symbolic links.'
        $canCreateSymlink = $false
        $createOrUpdateSymlink = $false
    }

    if (
        -not $VsCodeTask -and
        -not $canCreateSymlink -and
        $ChildConfig.EnforceSymlink
    ) {
        # Display a message to the user
        Write-Host "Starting an elevated PowerShell session to create symbolic links. You may be prompted for your administrator password."

        # Re-run the script in an elevated PowerShell session
        $powershellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $process = Start-Process -FilePath $powershellPath -ArgumentList "-ExecutionPolicy Bypass -NoLogo -NoProfile -NonInteractive -File `"$($MyInvocation.PSCommandPath)`"" -Verb RunAs -PassThru

        # Wait for the process to exit
        $process.WaitForExit()

        # Check if the process was successful
        if ($process.ExitCode -ne 0) {
            Write-Warning "The script run was not successful. Exit code: $($process.ExitCode)"
            exit $($process.ExitCode)
        }
        else {
            Write-Verbose 'Script successfully ran in elevated mode. Exiting ...'
        }

        exit
    }
}
#endregion

#region Update framework *.ps1 scripts and *.psd1 configs in child project
function Get-FileMD5Hash($filePath) {
    return (Get-FileHash -Path $filePath -Algorithm MD5).Hash
}
function Compare-Configs {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,
        [Parameter(Mandatory = $true)]
        [object]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$SourceFile,
        [Parameter(Mandatory = $true)]
        [string]$DestinationFile,
        [Parameter(Mandatory = $false)]
        [string]$KeyPath = '',
        [Parameter(Mandatory = $false)]
        [int]$Depth = 0,
        [Parameter(Mandatory = $false)]
        [int]$MaxDepthDefault = 1,
        [Parameter(Mandatory = $false)]
        [Hashtable]$MaxDepths = @{}
    )

    $MaxDepth = $MaxDepthDefault

    if ($KeyPath -ne '' -and $MaxDepths.ContainsKey($KeyPath)) {
        $MaxDepth = $MaxDepths[$KeyPath]
    }

    if ($Depth -gt $MaxDepth) {
        Write-Verbose "Maximum recursion depth reached at '$KeyPath'."
        return
    }

    if ($Source -is [Hashtable] -and $Destination -is [Hashtable]) {
        foreach ($key in $Source.Keys) {
            if (-not $Destination.ContainsKey($key)) {
                Write-Warning "New key '$KeyPath/$key' found in framework configuration template '$SourceFile'.`n         Please add it to the project configuration in '$DestinationFile'."
            }
            else {
                Compare-Configs -Source $Source[$key] -Destination $Destination[$key] -SourceFile $SourceFile -DestinationFile $DestinationFile -KeyPath "$KeyPath/$key" -Depth ($Depth + 1) -MaxDepthDefault $MaxDepthDefault -MaxDepths $MaxDepths
            }
        }

        foreach ($key in $Destination.Keys) {
            if (-not $Source.ContainsKey($key)) {
                Write-Warning "Key '$KeyPath/$key' in project configuration '$DestinationFile' is obsolete. Please remove it."
            }
        }
    }
    elseif ($Source -is [Array] -and $Destination -is [Array]) {
        for ($i = 0; $i -lt $Source.Length; $i++) {
            Compare-Configs -Source $Source[$i] -Destination $Destination[$i] -SourceFile $SourceFile -DestinationFile $DestinationFile -KeyPath "$KeyPath/[$i]" -Depth ($Depth + 1) -MaxDepthDefault $MaxDepthDefault -MaxDepths $MaxDepths
        }
    }
}

$destFileList = [System.Collections.ArrayList]::new()

$list = @(
    # Files that live in the user's project repository
    @{
        source      = Join-Path $config.Project.Directory (Join-Path 'project.template' 'config')
        destination = Join-Path $ChildConfig.Project.Directory 'config'
        filter      = @('*.psd1', '*.json')
        action      = 'copy'
        overwrite   = $true
    }
    @{
        source      = Join-Path $config.Project.Directory (Join-Path 'project.template' 'scripts')
        destination = Join-Path $ChildConfig.Project.Directory 'scripts'
        filter      = @('*.ps1', '*.py')
        action      = 'copy'
        overwrite   = $true
    }
    @{
        source      = Join-Path $config.Project.Directory (Join-Path 'project.template' 'setup')
        destination = Join-Path $ChildConfig.Project.Directory 'setup'
        filter      = @('*.ps1', '*.py')
        action      = 'copy'
        overwrite   = $true
    }

    # Files that live in the framework repository
    @{
        source      = Join-Path $config.Project.Directory (Join-Path 'scripts' 'AzAutoFWProject')
        destination = Join-Path $ChildConfig.Project.Directory (Join-Path 'scripts' 'AzAutoFWProject')
        filter      = @('*.ps1', '*.py')
        action      = if ($ChildConfig.EnforceSymlink -or $canCreateSymlink) { 'symlink' } else { 'copy' }
        overwrite   = $true

        # This file has a sibling in the user's project repository and the framework's file is called by it to resolve the chicken/egg problem
        exclude     = @(Join-Path $config.Project.Directory (Join-Path 'scripts' (Join-Path 'AzAutoFWProject' 'Update-AzAutoFWProject.ps1')))
    }
    @{
        source      = Join-Path $config.Project.Directory (Join-Path 'setup' 'AzAutoFWProject')
        destination = Join-Path $ChildConfig.Project.Directory (Join-Path 'setup' 'AzAutoFWProject')
        filter      = @('*.ps1', '*.py')
        action      = if ($ChildConfig.EnforceSymlink -or $canCreateSymlink) { 'symlink' } else { 'copy' }
        overwrite   = $true
    }
    @{
        source      = Join-Path $config.Project.Directory 'Runbooks'
        destination = Join-Path $ChildConfig.Project.Directory 'Runbooks'
        filter      = @('Common_*.ps1', 'Common_*.py')
        action      = if ($ChildConfig.CopyRunbooks -ne $true -and $ChildConfig.EnforceSymlink -or $canCreateSymlink) { 'symlink' } else { 'copy' }
        overwrite   = if ($ChildConfig.UpdateRunbooksManually -eq $true) { $false } else { $true }
    }
)

# Update files from framework
$list | & {
    process {
        $srcDir = $_.source
        $destDir = $_.destination
        $action = $_.action
        $overwrite = $_.overwrite
        $exclude = $_.exclude
        $filter = $_.filter

        $filter | & {
            process {
                Write-Verbose "Checking to $action $_ files from '$srcDir'"
                Get-ChildItem -LiteralPath $srcDir -File -Filter $_ -Recurse | & {
                    process {
                        if ($_.FullName -in $exclude) {
                            Write-Verbose "Skipping excluded file '$($_.FullName)'"
                            return
                        }
                        $destFile = $_.FullName.Replace($srcDir, $destDir)
                        $null = $destFileList.Add($destFile)

                        # Config files are always copied
                        if ($_.Extension -in @('.psd1', '.json')) {
                            # Notifies the user if a new key was added to the framework config template
                            if (Test-Path -LiteralPath $destFile) {
                                Write-Verbose "Comparing config in '$destFile' with project template"
                                $sourceConfig = $null
                                $destinationConfig = $null
                                try {
                                    if ($_.Extension -eq '.psd1') {
                                        $sourceConfig = Import-PowerShellDataFile -LiteralPath $_.FullName -ErrorAction Stop
                                        $destinationConfig = Import-PowerShellDataFile -LiteralPath $destFile -ErrorAction Stop
                                    }
                                    else {
                                        $sourceConfig = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                                        $destinationConfig = Get-Content -LiteralPath $destFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                                    }
                                    $params = @{
                                        Source          = $sourceConfig
                                        Destination     = $destinationConfig
                                        SourceFile      = $_.FullName
                                        DestinationFile = $destFile
                                        ErrorAction     = 'Stop'
                                    }
                                    Compare-Configs @params
                                }
                                catch {
                                    Write-Warning "Could not compare config in '$destFile' with project template: $_"
                                }
                            }
                            else {
                                Write-Host "Cloning config '$destFile' from project template folder"
                                Copy-Item -LiteralPath $_.FullName -Destination $destFile -Force
                            }
                        }

                        # Script files are copied or symlinked depending on the user's preference
                        else {
                            if (Test-Path -LiteralPath $destFile) {
                                $destFile = Get-Item -LiteralPath $destFile

                                # Clean up broken or obsolete symlinks
                                if ([bool]($destFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                                    $currTarget = Get-ItemProperty -Path $destFile.FullName -Name Target | Select-Object -ExpandProperty Target

                                    # On Unix, make absolute path out of relative path
                                    if (
                                        [System.Environment]::OSVersion.Platform -eq "Unix" -and
                                        $null -ne $currTarget
                                    ) {
                                        $currTarget = (Resolve-Path -LiteralPath (Join-Path (Split-Path $destFile.FullName) $currTarget -ErrorAction SilentlyContinue)).Path
                                    }

                                    if (
                                        $null -eq $currTarget -or
                                        -Not (Test-Path -PathType Leaf -LiteralPath $currTarget) -or
                                        ($action -ne 'symlink' -and -not $ChildConfig.EnforceSymlink)
                                    ) {
                                        Write-Verbose "Removing obsolete symlink at $($destFile.FullName)"
                                        Remove-Item -LiteralPath $destFile.FullName -Force 1>$null
                                    }
                                }
                                elseif ($action -eq 'symlink') {
                                    Write-Verbose "Removing obsolete script file '$($destFile.FullName)'"
                                    Remove-Item -LiteralPath $destFile.FullName -Force 1>$null
                                }

                                if ($action -eq 'copy') {
                                    if (
                                        -not (Test-Path -LiteralPath $destFile.FullName) -or
                                        (Get-FileMD5Hash $_.FullName) -ne (Get-FileMD5Hash $destFile.FullName)
                                    ) {
                                        if ($overwrite -eq $true) {
                                            Write-Host "Updating script '$destFile' from project template folder"
                                            Copy-Item -LiteralPath $_.FullName -Destination $destFile.FullName -Force
                                        }
                                        else {
                                            Write-Verbose "Skipping update of script '$($destFile.FullName)' from project template folder"
                                        }
                                    }
                                }
                                elseif ($action -eq 'symlink' -and $createOrUpdateSymlink -ne $true) {
                                    Write-Verbose "Skipping update of script symlink '$destFile' to project template folder because Linked Connections are not enabled."
                                }
                                elseif ($action -eq 'symlink') {
                                    $BaseUri = New-Object System.Uri $destFile
                                    $FullUri = New-Object System.Uri $_.FullName

                                    if ([System.Environment]::OSVersion.Platform -eq "Unix") {
                                        Write-Verbose "Using relative target path on Unix"
                                        $BaseUri = New-Object System.Uri $destFile
                                        $FullUri = New-Object System.Uri $_.FullName
                                        $TargetPath = $BaseUri.MakeRelativeUri($FullUri).ToString()
                                    }
                                    else {
                                        Write-Verbose "Using absolute target path on Windows"
                                        $TargetPath = $_.FullName
                                    }
                                    $currTarget = Get-ItemProperty -Path $destFile.FullName -Name Target | Select-Object -ExpandProperty Target
                                    if (
                                        -not (Test-Path -LiteralPath $destFile.FullName) -or
                                        $currTarget -ne $TargetPath
                                    ) {
                                        Write-Host "Updating script symlink '$($destFile.FullName)' to project template folder"
                                        $params = @{
                                            ItemType    = 'SymbolicLink'
                                            Path        = $destFile.FullName
                                            Target      = $TargetPath
                                            Force       = $true
                                            ErrorAction = 'SilentlyContinue'
                                        }
                                        New-Item @params 1> $null
                                    }
                                }
                                else {
                                    Write-Verbose "Script '$($destFile.FullName)' is up to date"
                                }
                            }
                            elseif ($action -eq 'copy') {
                                Write-Host "Cloning script '$destFile' from project template folder"
                                Copy-Item -LiteralPath $_.FullName -Destination $destFile -Force
                            }
                            elseif ($createOrUpdateSymlink -ne $true) {
                                Write-Verbose "Skipping creation of script symlink '$destFile' to project template folder because Developer Mode is not enabled."
                            }
                            elseif ($action -eq 'symlink') {
                                Write-Host "Creating script symlink '$destFile' to project template folder"
                                if ([System.Environment]::OSVersion.Platform -eq "Unix") {
                                    Write-Verbose "Using relative target path on Unix"
                                    $BaseUri = New-Object System.Uri $destFile
                                    $FullUri = New-Object System.Uri $_.FullName
                                    $TargetPath = $BaseUri.MakeRelativeUri($FullUri).ToString()
                                }
                                else {
                                    Write-Verbose "Using absolute target path on Windows"
                                    $TargetPath = $_.FullName
                                }
                                $params = @{
                                    ItemType    = 'SymbolicLink'
                                    Path        = $destFile
                                    Target      = $TargetPath
                                    Force       = $true
                                    ErrorAction = 'SilentlyContinue'
                                }
                                New-Item @params 1> $null
                            }
                            else {
                                Write-Error "Unknown action '$action' for file '$destFile'."
                            }
                        }
                    }
                }
            }
        }
    }
}

# Cleanup project files that are no longer part of the framework
$list | & {
    process {
        $srcDir = $_.source
        $destDir = $_.destination
        $action = $_.action
        $overwrite = $_.overwrite
        $exclude = $_.exclude
        $filter = $_.filter

        # Get-ChildItem -Path $srcDir -Directory -Recurse | & {
        #     process {
        #         $destDirPath = $_.FullName.Replace($srcDir, $destDir)
        if (Test-Path -Path $destDir) {
            $filter | & {
                process {
                    Write-Verbose "Checking for obsolete $_ files in '$destDir'"
                    Get-ChildItem -Path $destDir -File -Filter $_ | & {
                        process {
                            if ($_.FullName -notin $destFileList) {
                                Write-Warning "File '$($_.FullName)' has become obsolete and is no longer needed. It may be deleted."
                            }
                            else {
                                Write-Verbose "File '$($_.FullName)' is part of the framework and should not be deleted."
                            }
                        }
                    }
                }
            }
        }
        #     }
        # }
    }
}
#endregion

Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
