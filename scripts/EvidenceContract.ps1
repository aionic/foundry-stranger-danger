$script:EvidenceSchemaVersion = '1.0'

function New-EvidenceRunId {
    $timestamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $nonce = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "$timestamp-$nonce"
}

function Test-AgentEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Evidence,

        [Parameter(Mandatory)]
        [object]$ExpectedProjects,

        [string]$ExpectedRunId
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    if ($Evidence.schema_version -ne $EvidenceSchemaVersion) {
        $failures.Add("Agent evidence schema '$($Evidence.schema_version)' is not supported.")
    }
    if (-not $Evidence.run_id) {
        $failures.Add('Agent evidence has no run_id.')
    }
    elseif ($ExpectedRunId -and $Evidence.run_id -ne $ExpectedRunId) {
        $failures.Add("Agent evidence run_id '$($Evidence.run_id)' does not match '$ExpectedRunId'.")
    }

    $generatedUtc = [datetimeoffset]::MinValue
    if (-not $Evidence.generated_utc -or
        -not [datetimeoffset]::TryParse("$($Evidence.generated_utc)", [ref]$generatedUtc)) {
        $failures.Add('Agent evidence has no valid generated_utc timestamp.')
    }
    if ($Evidence.api_version -ne 'v1') {
        $failures.Add("Agent evidence API version '$($Evidence.api_version)' is not the validated Responses API version 'v1'.")
    }
    if (-not $Evidence.projects) {
        $failures.Add('Agent evidence has no projects object.')
        return $failures.ToArray()
    }

    foreach ($expectedProperty in $ExpectedProjects.PSObject.Properties) {
        $projectName = $expectedProperty.Name
        $expected = $expectedProperty.Value
        $actualProperty = $Evidence.projects.PSObject.Properties[$projectName]
        if (-not $actualProperty) {
            $failures.Add("Agent evidence is missing project '$projectName'.")
            continue
        }

        $actual = $actualProperty.Value
        if ($actual.status -ne 'ok') {
            $failures.Add("Agent evidence for '$projectName' has status '$($actual.status)', expected 'ok'.")
        }
        if ($actual.internal_id -ne $expected.internal_id -or $actual.guid -ne $expected.guid) {
            $failures.Add("Agent evidence identifiers for '$projectName' do not match the deployment inventory.")
        }
        if (-not $actual.canary_token) {
            $failures.Add("Agent evidence for '$projectName' has no canary_token.")
        }
        elseif (-not "$($actual.reply)".StartsWith("$($actual.canary_token)", [System.StringComparison]::Ordinal)) {
            $failures.Add("Agent reply for '$projectName' does not begin with its canary token.")
        }
    }

    foreach ($actualProperty in $Evidence.projects.PSObject.Properties) {
        if (-not $ExpectedProjects.PSObject.Properties[$actualProperty.Name]) {
            $failures.Add("Agent evidence contains unknown project '$($actualProperty.Name)'.")
        }
    }

    return $failures.ToArray()
}

function Merge-AccessOutcome {
    [CmdletBinding()]
    param([object[]]$Results)

    if (-not $Results -or $Results.Count -eq 0) { return 'ERROR' }
    $outcomes = @($Results | ForEach-Object { $_.outcome } | Sort-Object -Unique)
    if ($outcomes -contains 'BLOCKED') { return 'BLOCKED' }
    if ($outcomes -contains 'ERROR') { return 'ERROR' }
    if ($outcomes.Count -eq 1 -and $outcomes[0] -in @('ALLOW', 'DENY')) { return $outcomes[0] }
    return 'PARTIAL'
}

function Get-AccessVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Outcome,
        [Parameter(Mandatory)][string]$Expected
    )

    if ($Outcome -eq 'BLOCKED') { return 'INVALID' }
    if ($Outcome -eq $Expected) { return 'PASS' }
    return 'UNEXPECTED'
}

function Resolve-AccessFailure {
    [CmdletBinding()]
    param(
        [int]$Status,
        [string]$Body
    )

    if ($Status -eq 403 -and $Body -match 'firewall|through public internet|public network access|not allowed from this IP|network access') {
        return [pscustomobject]@{ outcome = 'BLOCKED'; note = 'network refusal, not RBAC - test invalid' }
    }
    if ($Status -eq 403) {
        return [pscustomobject]@{ outcome = 'DENY'; note = 'authorization denied' }
    }
    if ($Status -eq 401) {
        return [pscustomobject]@{ outcome = 'ERROR'; note = 'authentication failed; not an authorization denial' }
    }
    return [pscustomobject]@{ outcome = 'ERROR'; note = "unexpected status $Status" }
}

function Wait-ForSingleNewValue {
    [CmdletBinding()]
    param(
        [string[]]$Baseline = @(),

        [Parameter(Mandatory)]
        [scriptblock]$GetValues,

        [ValidateRange(0, 3600)]
        [int]$TimeoutSeconds = 120,

        [ValidateRange(0, 300)]
        [int]$PollSeconds = 5,

        [string]$Description = 'value'
    )

    $deadline = [datetimeoffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $current = @(& $GetValues | Sort-Object -Unique)
        $newValues = @($current | Where-Object { $_ -notin $Baseline })

        if ($newValues.Count -eq 1) {
            return [pscustomobject]@{
                value      = $newValues[0]
                all_values = $current
            }
        }
        if ($newValues.Count -gt 1) {
            throw "Expected exactly one new $Description; found $($newValues.Count): $($newValues -join ', ')."
        }
        if ([datetimeoffset]::UtcNow -ge $deadline) {
            throw "Timed out after $TimeoutSeconds seconds waiting for one new $Description."
        }
        if ($PollSeconds -gt 0) { Start-Sleep -Seconds $PollSeconds }
    } while ($true)
}

function Wait-ForExpectedValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][scriptblock]$GetValues,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 180,
        [ValidateRange(0, 300)][int]$PollSeconds = 5,
        [string]$Description = 'values'
    )

    $deadline = [datetimeoffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $current = @(& $GetValues | Sort-Object -Unique)
        $missing = @($Expected | Where-Object { $_ -notin $current })
        if ($missing.Count -eq 0) { return $current }
        if ([datetimeoffset]::UtcNow -ge $deadline) {
            throw "Timed out after $TimeoutSeconds seconds waiting for $Description. Missing: $($missing -join ', ')."
        }
        if ($PollSeconds -gt 0) { Start-Sleep -Seconds $PollSeconds }
    } while ($true)
}

function Test-DeploymentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Inventory
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $projectNames = @($Inventory.projects.PSObject.Properties.Name)

    if ($projectNames.Count -lt 2) {
        $failures.Add('At least two projects are required for cross-project validation.')
    }

    foreach ($projectName in $projectNames) {
        $cosmosContainerCount = @($Inventory.cosmos_containers | Where-Object { $_.owner -eq $projectName }).Count
        $blobContainerCount = @($Inventory.blob_containers | Where-Object { $_.owner -eq $projectName }).Count
        if ($cosmosContainerCount -ne 5) {
            $failures.Add("$projectName must have five attributable Cosmos containers; found $cosmosContainerCount.")
        }
        if ($blobContainerCount -ne 2) {
            $failures.Add("$projectName must have two attributable Blob containers; found $blobContainerCount.")
        }
    }

    if ($Inventory.isolation_mode -notin @('documented', 'hardened')) {
        $failures.Add("Unknown isolation mode '$($Inventory.isolation_mode)'.")
        return $failures.ToArray()
    }

    foreach ($projectName in $projectNames) {
        $principal = "project:$projectName"
        $cosmosRoles = @($Inventory.cosmos_data_roles | Where-Object { $_.principal -eq $principal })

        if ($Inventory.isolation_mode -eq 'documented') {
            $databaseRoles = @($cosmosRoles | Where-Object { $_.granularity -like 'DATABASE*' })
            if ($cosmosRoles.Count -ne 1 -or $databaseRoles.Count -ne 1) {
                $failures.Add("$principal must have exactly one database-scoped Cosmos grant in documented mode.")
            }
        }
        else {
            $containerRoles = @($cosmosRoles | Where-Object { $_.granularity -eq 'container' })
            if ($cosmosRoles.Count -ne 5 -or $containerRoles.Count -ne 5) {
                $failures.Add("$principal must have exactly five container-scoped Cosmos grants in hardened mode.")
            }
            $expectedContainers = @($Inventory.cosmos_containers | Where-Object { $_.owner -eq $projectName } | ForEach-Object { $_.name })
            foreach ($container in $expectedContainers) {
                if ($container -notin $containerRoles.container) {
                    $failures.Add("$principal has no Cosmos grant for '$container'.")
                }
            }
        }

        $blobRoles = @($Inventory.arm_roles | Where-Object {
                $_.principal -eq $principal -and
                $_.resource -eq 'storage' -and
                $_.role -like 'Storage Blob Data *'
            })
        $conditionedOwners = @($blobRoles | Where-Object {
                $_.role -eq 'Storage Blob Data Owner' -and
                $_.granularity -like 'ACCOUNT*' -and
            $_.is_direct -eq $true -and
                $_.condition -eq 'yes'
            })
        if ($blobRoles.Count -ne 1 -or $conditionedOwners.Count -ne 1) {
            $failures.Add("$principal must have exactly one direct account-scoped, conditioned Storage Blob Data Owner grant.")
        }
        else {
            $expectedCondition = "$($Inventory.projects.$projectName.expected_blob_condition)"
            $actualCondition = "$($conditionedOwners[0].condition_expression)"
            $normalizedExpected = [regex]::Replace($expectedCondition, '\s+', '').ToLowerInvariant()
            $normalizedActual = [regex]::Replace($actualCondition, '\s+', '').ToLowerInvariant()
            if (-not $expectedCondition -or
                $conditionedOwners[0].condition_version -ne '2.0' -or
                $normalizedActual -ne $normalizedExpected -or
                $actualCondition -notmatch '@Resource\[Microsoft\.Storage/storageAccounts/blobServices/containers:name\]' -or
                $actualCondition -notmatch 'StringStartsWithIgnoreCase' -or
                $actualCondition -notmatch [regex]::Escape($Inventory.projects.$projectName.guid)) {
                $failures.Add("$principal Blob condition does not match the Terraform-generated project-prefix condition.")
            }
        }
        if ($blobRoles | Where-Object { $_.condition -ne 'yes' }) {
            $failures.Add("$principal has an unconditioned Blob data grant that applies to the Storage account.")
        }
    }

    return $failures.ToArray()
}