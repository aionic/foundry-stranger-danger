<#
.SYNOPSIS
    Creates and invokes one hello-world agent per Foundry project.

.DESCRIPTION
    Uses the MODERN Foundry Agents surface:

        POST {project}/agents?api-version=v1
        POST {project}/agents/{name}/endpoint/protocols/openai/responses?api-version=v1

    Not the classic /assistants Assistants API, which is deprecated and writes
    to a different set of Cosmos containers.

    The invocation is mandatory, not cosmetic. The modern runtime's
    <project-id>-agent-definitions-v1 and <project-id>-run-state-v1 containers
    are created lazily on a project's FIRST Responses API call. Creating the
    agent alone leaves them absent, which both leaves the evidence incomplete
    and blocks container-scoped role assignments.

    PowerShell rather than Python because PyPI is not reliably reachable from
    this environment; this needs nothing beyond the Azure CLI.
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = (Join-Path $PSScriptRoot '..\evidence')
)

$ErrorActionPreference = 'Stop'
$terraformDir = Join-Path $PSScriptRoot '..\terraform'
. (Join-Path $PSScriptRoot 'EvidenceContract.ps1')
$apiVersion = 'v1'
$runId = if ($env:FOUNDRY_EVIDENCE_RUN_ID) {
    $env:FOUNDRY_EVIDENCE_RUN_ID
}
else {
    New-EvidenceRunId
}

$tf = @{}
(terraform -chdir="$terraformDir" output -json | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $tf[$_.Name] = $_.Value.value }

Write-Host 'Acquiring token for https://ai.azure.com ...' -ForegroundColor Cyan
$token = az account get-access-token --scope 'https://ai.azure.com/.default' --query accessToken -o tsv
if (-not $token) { throw 'Failed to acquire a token.' }

$headers = @{
    Authorization  = "Bearer $token"
    'Content-Type' = 'application/json'
}

function Get-AgentIfPresent {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        return Invoke-RestMethod -Method Get -Uri "$Endpoint/agents/$Name`?api-version=$apiVersion" -Headers $headers
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($status -eq 404) { return $null }
        throw
    }
}

$results = [ordered]@{}
$failed = $false

foreach ($p in $tf.projects.PSObject.Properties) {
    $key = $p.Name
    $project = $p.Value
    $agent = $project.agent
    $endpoint = $project.endpoint
    $canaryToken = if ($agent.instructions -match 'literal token\s+([A-Z0-9][A-Z0-9-]*)') { $Matches[1] } else { $null }

    Write-Host "`n=== $key ===" -ForegroundColor Cyan
    Write-Host "    endpoint : $endpoint"

    try {
        if (-not $canaryToken) {
            throw "Agent instructions for '$key' must declare a literal canary token."
        }

        $createBody = @{
            name       = $agent.name
            definition = @{
                kind         = 'prompt'
                model        = $tf.model_deployment_name
                instructions = $agent.instructions
            }
        } | ConvertTo-Json -Depth 6

        $created = Get-AgentIfPresent -Endpoint $endpoint -Name $agent.name
        $agentReused = $null -ne $created
        if (-not $created) {
            $created = Invoke-RestMethod -Method Post -Uri "$endpoint/agents?api-version=$apiVersion" `
                -Headers $headers -Body $createBody
        }
        Write-Host "    agent    : $($created.id)$(if ($agentReused) { ' (reused)' })" -ForegroundColor Green

        # This call is what materialises the -v1 containers.
        $invokeBody = @{
            input = @(@{ role = 'user'; content = $agent.sample_prompt })
        } | ConvertTo-Json -Depth 6

        $uri = "$endpoint/agents/$($agent.name)/endpoint/protocols/openai/responses?api-version=$apiVersion"
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $invokeBody

        $text = if ($response.output_text) {
            $response.output_text
        }
        else {
            ($response.output | Where-Object { $_.type -eq 'message' } |
                ForEach-Object { $_.content | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text } }) -join "`n"
        }

        Write-Host "    prompt   : $($agent.sample_prompt)"
        Write-Host "    reply    : $text" -ForegroundColor Green

        if (-not "$text".StartsWith($canaryToken, [System.StringComparison]::Ordinal)) {
            throw "Agent '$key' did not return its required canary token '$canaryToken'."
        }

        $results[$key] = [ordered]@{
            status       = 'ok'
            endpoint     = $endpoint
            agent_name   = $agent.name
            agent_id     = $created.id
            instructions = $agent.instructions
            prompt       = $agent.sample_prompt
            reply        = $text
            canary_token = $canaryToken
            response_id  = $response.id
            agent_reused = $agentReused
            internal_id  = $project.internal_id
            guid         = $project.guid
        }
    }
    catch {
        $failed = $true
        $status = $null
        $body = $_.ErrorDetails.Message
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        Write-Host "    FAILED   : HTTP $status" -ForegroundColor Red
        if ($body) { Write-Host "    $body" -ForegroundColor Red }

        $results[$key] = [ordered]@{
            status      = 'failed'
            endpoint    = $endpoint
            agent_name  = $agent.name
            http_status = $status
            error       = $body
        }
    }
}

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$outPath = Join-Path $EvidenceDir 'agents.json'
$report = [ordered]@{
    schema_version = $EvidenceSchemaVersion
    run_id         = $runId
    generated_utc  = (Get-Date).ToUniversalTime().ToString('o')
    isolation_mode = $tf.isolation_mode
    api_version    = $apiVersion
    projects       = $results
}
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath -Encoding utf8
Write-Host "`nWrote $outPath" -ForegroundColor Green

if ($failed) { exit 1 }

Write-Host @'

Every project has now made a Responses API call, so its
-agent-definitions-v1 and -run-state-v1 containers exist.

Next:
  terraform apply -var="modern_containers_exist=true"   (enables container-scoped grants)
  .\scripts\12-collect-evidence.ps1 -SkipAgents
'@ -ForegroundColor Cyan
