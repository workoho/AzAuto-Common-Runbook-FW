BeforeAll {
    # The runbook calls Common_0002 by a relative path, so it runs from a folder with a stub of that runbook.
    Copy-Item -Path (Join-Path $PSScriptRoot '../Runbooks/Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1') -Destination $TestDrive
    Set-Content -Path (Join-Path $TestDrive 'Common_0002__Get-MgDirectoryRoleActiveAssignment.ps1') -Value '$global:FakeRoleAssignments'

    function New-RoleAssignment ($DisplayName, $TemplateId, $DirectoryScopeId) {
        [pscustomobject]@{
            DirectoryScopeId = $DirectoryScopeId
            RoleDefinition   = [pscustomobject]@{ DisplayName = $DisplayName; TemplateId = $TemplateId }
        }
    }

    $script:Roles = @(
        @{ DisplayName = 'Reports Reader'; TemplateId = '4a5d8f65-41da-4de4-8968-e035b65339cf' }
        @{ DisplayName = 'User Administrator'; TemplateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'; DirectoryScopeId = '/' }
        @{ DisplayName = 'User Administrator'; TemplateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'; DirectoryScopeId = '/administrativeUnits/au1' }
    )
}

Describe 'Common_0003__Confirm-MgDirectoryRoleActiveAssignment' {
    BeforeEach {
        Push-Location $TestDrive
    }

    AfterEach {
        Pop-Location
        Remove-Variable -Name FakeRoleAssignments -Scope Global -ErrorAction SilentlyContinue
    }

    It 'passes when every role is assigned' {
        $global:FakeRoleAssignments = @(
            New-RoleAssignment 'Reports Reader' '4a5d8f65-41da-4de4-8968-e035b65339cf' '/'
            New-RoleAssignment 'User Administrator' 'fe930be7-5e62-47db-91af-98c3a49a38b1' '/'
            New-RoleAssignment 'User Administrator' 'fe930be7-5e62-47db-91af-98c3a49a38b1' '/administrativeUnits/au1'
        )
        { ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 -Roles $script:Roles -AllowSuperseededRoleWithDirectoryScope $false } | Should -Not -Throw
    }

    # On Windows PowerShell 5.1, Group-Object does not group hashtables by key, which once kept only the first role.
    It 'stops when a role other than the first one is missing' {
        $global:FakeRoleAssignments = @(
            New-RoleAssignment 'Reports Reader' '4a5d8f65-41da-4de4-8968-e035b65339cf' '/'
            New-RoleAssignment 'User Administrator' 'fe930be7-5e62-47db-91af-98c3a49a38b1' '/'
        )
        { ./Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 -Roles $script:Roles -AllowSuperseededRoleWithDirectoryScope $false } | Should -Throw '*Missing mandatory directory role*au1*'
    }
}
