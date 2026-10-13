<#
.SYNOPSIS
    Enables Azure diagnostic settings for resources in a resource group.

.DESCRIPTION
    Discovers every resource's supported log and metric categories and sends
    them to a Log Analytics workspace. The destination workspace is excluded
    to prevent diagnostics from being routed back into itself.

.PARAMETER Subscription
    Azure subscription ID containing the resources.

.PARAMETER ResourceGroup
    Resource group whose resources should emit diagnostics.

.PARAMETER WorkspaceResourceId
    Full resource ID of the destination Log Analytics workspace.

.PARAMETER SettingName
    Diagnostic setting name created or updated on each supported resource.

.EXAMPLE
    .\scripts\Enable-DiagnosticSettings.ps1 `
        -Subscription 00000000-0000-0000-0000-000000000000 `
        -ResourceGroup rg-workloads `
        -WorkspaceResourceId /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-workloads/providers/Microsoft.OperationalInsights/workspaces/log-workloads
#>

#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string]$WorkspaceResourceId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SettingName = 'sre-agent-observability'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ApiVersion = '2021-05-01-preview'
$ManagementEndpoint = 'https://management.azure.com'

function Invoke-AzureRest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'PUT')]
        [string]$Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Body = ''
    )

    $Arguments = @('rest', '--method', $Method, '--url', $Url, '--output', 'json')
    $TemporaryFile = $null

    try {
        if ($Body) {
            $TemporaryFile = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $TemporaryFile -Value $Body -NoNewline
            $Arguments += @(
                '--headers', 'Content-Type=application/json',
                '--body', "@$TemporaryFile"
            )
        }

        $Result = & az @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Azure REST $Method failed for '$Url': $($Result -join [Environment]::NewLine)"
        }

        return ($Result -join [Environment]::NewLine) | ConvertFrom-Json
    }
    finally {
        if ($TemporaryFile) {
            Remove-Item -LiteralPath $TemporaryFile -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    $null = Get-Command az -ErrorAction Stop

    $AccountId = & az account show --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $AccountId) {
        throw 'Azure CLI is not authenticated. Run az login before continuing.'
    }

    & az account set --subscription $Subscription
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to select Azure subscription '$Subscription'."
    }

    $ResourcesJson = & az resource list `
        --resource-group $ResourceGroup `
        --query '[].{name:name,type:type,id:id}' `
        --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list resources in resource group '$ResourceGroup'."
    }

    $Resources = @($ResourcesJson | ConvertFrom-Json)
    $ConfiguredCount = 0
    $SkippedCount = 0

    foreach ($Resource in $Resources) {
        if ($Resource.id -ieq $WorkspaceResourceId) {
            Write-Host "Skipped $($Resource.name): destination workspace" -ForegroundColor DarkGray
            $SkippedCount++
            continue
        }

        $CategoriesUrl = "$ManagementEndpoint$($Resource.id)/providers/microsoft.insights/diagnosticSettingsCategories?api-version=$ApiVersion"

        try {
            $Categories = @((
                Invoke-AzureRest -Method GET -Url $CategoriesUrl
            ).value)
        }
        catch {
            Write-Host "Skipped $($Resource.name): diagnostic settings unsupported" -ForegroundColor DarkGray
            $SkippedCount++
            continue
        }

        $Logs = @(
            $Categories |
                Where-Object { $_.properties.categoryType -eq 'Logs' } |
                ForEach-Object {
                    @{
                        category = $_.name
                        enabled = $true
                        retentionPolicy = @{
                            enabled = $false
                            days = 0
                        }
                    }
                }
        )
        $Metrics = @(
            $Categories |
                Where-Object { $_.properties.categoryType -eq 'Metrics' } |
                ForEach-Object {
                    @{
                        category = $_.name
                        enabled = $true
                        retentionPolicy = @{
                            enabled = $false
                            days = 0
                        }
                    }
                }
        )

        if ($Logs.Count -eq 0 -and $Metrics.Count -eq 0) {
            Write-Host "Skipped $($Resource.name): no diagnostic categories" -ForegroundColor DarkGray
            $SkippedCount++
            continue
        }

        $Body = @{
            properties = @{
                workspaceId = $WorkspaceResourceId
                logs = $Logs
                metrics = $Metrics
            }
        } | ConvertTo-Json -Depth 10 -Compress

        $SettingsUrl = "$ManagementEndpoint$($Resource.id)/providers/microsoft.insights/diagnosticSettings/$SettingName`?api-version=$ApiVersion"
        $CategorySummary = "$($Logs.Count) log and $($Metrics.Count) metric categories"

        if ($PSCmdlet.ShouldProcess($Resource.id, "Enable $CategorySummary")) {
            $null = Invoke-AzureRest -Method PUT -Url $SettingsUrl -Body $Body
            Write-Host "Configured $($Resource.name): $CategorySummary" -ForegroundColor Green
            $ConfiguredCount++
        }
    }

    Write-Host ''
    Write-Host "Configured resources: $ConfiguredCount" -ForegroundColor Green
    Write-Host "Skipped resources: $SkippedCount" -ForegroundColor DarkGray
}
catch {
    Write-Error $_
    exit 1
}
