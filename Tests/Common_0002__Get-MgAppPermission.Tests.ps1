BeforeAll {
    $script:Runbook = Join-Path $PSScriptRoot '../Runbooks/Common_0002__Get-MgAppPermission.ps1'

    function Get-MgContext { [pscustomobject]@{ AuthType = 'AppOnly' } }

    # Stands in for the Microsoft Graph cmdlet: answers from $global:FakeGraphPages by URI, or throws for a URI in $global:FakeGraphFailing.
    function Invoke-MgGraphRequest {
        [CmdletBinding()]
        param($Uri)
        if ($global:FakeGraphFailing -and $Uri -like $global:FakeGraphFailing) { throw 'Insufficient privileges to complete the operation.' }
        foreach ($key in $global:FakeGraphPages.Keys) {
            if ($Uri -like $key) { return $global:FakeGraphPages[$key] }
        }
        @{ value = @() }
    }
}

Describe 'Common_0002__Get-MgAppPermission' {
    BeforeEach {
        $env:MG_PRINCIPAL_ID = 'identity'
        $global:FakeGraphFailing = $null
        $global:FakeGraphPages = [ordered] @{
            '/v1.0/servicePrincipals/identity/appRoleAssignments'       = @{ value = @(@{ resourceId = 'exo'; appRoleId = 'role-1' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/page2' }
            'https://graph.microsoft.com/v1.0/page2'                    = @{ value = @(@{ resourceId = 'exo'; appRoleId = 'role-2' }) }
            '/v1.0/servicePrincipals/identity/oauth2PermissionGrants'   = @{ value = @() }
            '/v1.0/servicePrincipals?*'                                 = @{ value = @(@{ id = 'exo'; appId = 'exo-app'; displayName = 'Office 365 Exchange Online'; appRoles = @(@{ id = 'role-1'; value = 'Exchange.ManageAsApp' }, @{ id = 'role-2'; value = 'Mailbox.Migration' }) }) }
        }
    }

    AfterEach {
        Remove-Variable -Name FakeGraphPages, FakeGraphFailing -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -Path env:MG_PRINCIPAL_ID -ErrorAction SilentlyContinue
    }

    It 'reads the app roles from every page' {
        $result = & $script:Runbook -App 'exo-app'
        @($result.AppRoles) | Should -Be @('Exchange.ManageAsApp', 'Mailbox.Migration')
        $result.Id | Should -Be 'exo'
    }

    It 'throws when the app role assignments cannot be read' {
        $global:FakeGraphFailing = '*/appRoleAssignments'
        { & $script:Runbook -App 'exo-app' } | Should -Throw '*Insufficient privileges*'
    }
}
