$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$server = Join-Path $root 'Accounts\Cards\start_card_dashboard_server.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($server, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Invoke-InjectAccount', 'Update-InjectIni', 'Read-IniSection', 'Normalize-InjectExtraFriendIdsText', 'Build-InjectFriendRequestIds')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('trade-parallel-test-' + [guid]::NewGuid().ToString('N'))
$script:launches = @()
$script:responses = @()
function Read-RequestBody { param($Context) return ($Context | ConvertTo-Json) }
function Find-AccountXml { param($Account, $FileName) return (Join-Path $tempRoot ($Account + '.xml')) }
function Resolve-AutoHotkeyExe { return 'test-autohotkey.exe' }
function Write-JsonResponse { param($Context, $StatusCode, $Payload) $script:responses += @{ Status = $StatusCode; Payload = $Payload } }
# Only replace process launch: the test must never inject a real account.
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle)
    $script:launches += @{ Arguments = $ArgumentList; WindowStyle = $WindowStyle }
}
function Assert { param($Condition, $Message) if (-not $Condition) { throw $Message } }
try {
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'Accounts') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $tempRoot 'Accounts\_InjectAccount.ahk') | Out-Null
    $resolvedRoot = $tempRoot
    Invoke-InjectAccount -Context ([pscustomobject]@{ account = 'first'; winTitle = '1'; sendFriendRequest = $true; selectedFriendIds = '1111111111111111' })
    Invoke-InjectAccount -Context ([pscustomobject]@{ account = 'second'; winTitle = '2'; sendFriendRequest = $true; selectedFriendIds = '2222222222222222' })
    Assert ($responses.Count -eq 2 -and $responses[0].Status -eq 200 -and $responses[1].Status -eq 200) 'Both launches must succeed.'
    Assert ($launches.Count -eq 2) 'Both workers must launch without waiting for one another.'
    $configs = @()
    foreach ($launch in $launches) {
        $argsText = $launch.Arguments -join ' '
        Assert ($argsText -match '/run-config "([^"]+)"') 'Each worker must receive its own run config.'
        $configs += $matches[1]
        Assert ($launch.WindowStyle -eq 'Hidden') 'Background launch must be hidden.'
    }
    Assert ($configs[0] -ne $configs[1]) 'Concurrent runs must not share configuration.'
    $first = Read-IniSection -IniPath $configs[0] -Section 'UserSettings'
    $second = Read-IniSection -IniPath $configs[1] -Section 'UserSettings'
    Assert ($first.winTitle -eq '1' -and $first.fileName -eq 'first' -and $first.injectFriendRequestIds -eq '1111111111111111') 'First run must retain its own instance, account, and friends after second launch.'
    Assert ($second.winTitle -eq '2' -and $second.fileName -eq 'second' -and $second.injectFriendRequestIds -eq '2222222222222222') 'Second run must retain its own instance, account, and friends.'
    function Start-Process {
        param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle)
        $script:failedLaunchArguments = $ArgumentList -join ' '
        throw 'Simulated launch failure'
    }
    Invoke-InjectAccount -Context ([pscustomobject]@{ account = 'third'; winTitle = '3' })
    Assert ($responses[2].Status -eq 500) 'Launch failures must be reported.'
    Assert ($failedLaunchArguments -match '/run-config "([^"]+)"') 'Failed launch must have a run config.'
    Assert (-not (Test-Path -LiteralPath $matches[1])) 'Failed launch must remove its temporary account settings.'
    Write-Output 'PASS: overlapping launches keep independent account, instance, and friend settings.'
    Write-Output 'PASS: failed launches clean up their temporary settings.'
} finally {
    foreach ($config in $configs) { if (Test-Path -LiteralPath $config) { Remove-Item -LiteralPath $config } }
    if ((Split-Path $tempRoot -Leaf) -like 'trade-parallel-test-*') { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
