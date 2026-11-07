BeforeAll {
    # The runbook calls Common_0002 by a relative path, so it runs from a folder with a stub of that runbook.
    Copy-Item -Path (Join-Path $PSScriptRoot '../Runbooks/Common_0003__Confirm-MgAppPermission.ps1') -Destination $TestDrive
    Set-Content -Path (Join-Path $TestDrive 'Common_0002__Get-MgAppPermission.ps1') -Value 'param($App) $global:FakeAppPermissions'

    # Stands in for the Microsoft Graph cmdlet that tells an app sign-in from a delegated one.
    function Get-MgContext { [pscustomobject]@{ AuthType = $global:FakeAuthType } }

    $script:Exchange = @{
        DisplayName = 'Office 365 Exchange Online'
        AppId       = '00000002-0000-0ff1-ce00-000000000000'
        AppRoles    = @('Exchange.ManageAsApp')
    }
}

Describe 'Common_0003__Confirm-MgAppPermission' {
    BeforeEach {
        Push-Location $TestDrive
        $global:FakeAuthType = 'AppOnly'
    }

    AfterEach {
        Pop-Location
        Set-Content -Path (Join-Path $TestDrive 'Common_0002__Get-MgAppPermission.ps1') -Value 'param($App) $global:FakeAppPermissions'
        Remove-Variable -Name FakeAppPermissions, FakeAuthType -Scope Global -ErrorAction SilentlyContinue
    }

    It 'passes when every app role is assigned' {
        $global:FakeAppPermissions = @(@{ AppId = $script:Exchange.AppId; DisplayName = $script:Exchange.DisplayName; AppRoles = @('Exchange.ManageAsApp'); Oauth2PermissionScopes = @{} })
        { ./Common_0003__Confirm-MgAppPermission.ps1 -Permissions @($script:Exchange) } | Should -Not -Throw
    }

    It 'stops and names the app role that is missing' {
        $global:FakeAppPermissions = @(@{ AppId = $script:Exchange.AppId; DisplayName = $script:Exchange.DisplayName; AppRoles = @(); Oauth2PermissionScopes = @{} })
        { ./Common_0003__Confirm-MgAppPermission.ps1 -Permissions @($script:Exchange) } | Should -Throw '*Office 365 Exchange Online: app role Exchange.ManageAsApp*'
    }

    It 'stops when the app is not found at all' {
        $global:FakeAppPermissions = @()
        { ./Common_0003__Confirm-MgAppPermission.ps1 -Permissions @($script:Exchange) } | Should -Throw '*Office 365 Exchange Online: service principal not found*'
    }

    It 'matches an entry given by the object ID of the service principal' {
        $global:FakeAppPermissions = @(@{ Id = '11111111-1111-1111-1111-111111111111'; AppId = $script:Exchange.AppId; DisplayName = $script:Exchange.DisplayName; AppRoles = @('Exchange.ManageAsApp'); Oauth2PermissionScopes = @{} })
        $permission = @{ DisplayName = 'Office 365 Exchange Online'; AppId = '11111111-1111-1111-1111-111111111111'; AppRoles = @('Exchange.ManageAsApp') }
        { ./Common_0003__Confirm-MgAppPermission.ps1 -Permissions @($permission) } | Should -Not -Throw
    }

    It 'checks nothing and reads nothing for a delegated sign-in' {
        $global:FakeAuthType = 'Delegated'
        # The stub would fail the run if it were called.
        Set-Content -Path (Join-Path $TestDrive 'Common_0002__Get-MgAppPermission.ps1') -Value 'throw "read for a delegated sign-in"'
        { ./Common_0003__Confirm-MgAppPermission.ps1 -Permissions @($script:Exchange) } | Should -Not -Throw
    }

    It 'stops and names a delegated scope that is missing' {
        $permission = @{ DisplayName = 'Microsoft Graph'; AppId = '00000003-0000-0000-c000-000000000000'; Oauth2PermissionScopes = @{ Admin = @('User.Read') } }
        $global:FakeAppPermissions = @(@{ AppId = $permission.AppId; DisplayName = 'Microsoft Graph'; AppRoles = @(); Oauth2PermissionScopes = @{ Admin = @('openid') } })
        { ./Common_0003__Confirm-MgAppPermission.ps1 -Permissions @($permission) } | Should -Throw '*Microsoft Graph: delegated scope User.Read for Admin*'
    }
}
