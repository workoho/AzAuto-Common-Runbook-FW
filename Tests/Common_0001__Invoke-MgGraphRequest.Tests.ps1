BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/FakeGraph.ps1')
    $script:Runbook = Join-Path $PSScriptRoot '../Runbooks/Common_0001__Invoke-MgGraphRequest.ps1'

    # Stands in for the Microsoft Graph cmdlet: answers with an object, or throws the status in $global:FakeGraphStatus.
    function Invoke-MgGraphRequest {
        if ($global:FakeGraphStatus) {
            throw [FakeGraphException]::new($global:FakeGraphStatus, 'Request_Error', 'Simulated error.')
        }
        @{ id = 'result' }
    }
}

Describe 'Common_0001__Invoke-MgGraphRequest' {
    BeforeEach {
        $global:FakeGraphStatus = 0
    }

    AfterAll {
        Remove-Variable -Name FakeGraphStatus -Scope Global -ErrorAction SilentlyContinue
    }

    It 'returns the response of a successful request' {
        (& $script:Runbook @{ Method = 'GET'; Uri = '/v1.0/users/x' }).id | Should -Be 'result'
    }

    It 'returns nothing on 404' {
        $global:FakeGraphStatus = 404
        & $script:Runbook @{ Method = 'GET'; Uri = '/v1.0/users/x' } | Should -BeNullOrEmpty
    }

    It 'throws the status and the Graph error on 403' {
        $global:FakeGraphStatus = 403
        { & $script:Runbook @{ Method = 'PATCH'; Uri = '/v1.0/users/x' } } | Should -Throw '*403*Request_Error*'
    }
}
