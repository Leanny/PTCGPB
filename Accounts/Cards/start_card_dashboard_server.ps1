param(
    [int]$Port = 8081,
    [string]$Root = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AccountJsonSerializer = $null

$resolvedRoot = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    throw "Root path not found: $resolvedRoot"
}

$defaultDocument = "Accounts/Cards/card_database.html"
$shutdownAt = $null

$mimeMap = @{
    ".html" = "text/html; charset=utf-8"
    ".htm" = "text/html; charset=utf-8"
    ".css" = "text/css; charset=utf-8"
    ".js" = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".csv" = "text/csv; charset=utf-8"
    ".txt" = "text/plain; charset=utf-8"
    ".xml" = "application/xml; charset=utf-8"
    ".png" = "image/png"
    ".jpg" = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif" = "image/gif"
    ".webp" = "image/webp"
    ".svg" = "image/svg+xml"
    ".ico" = "image/x-icon"
    ".woff" = "font/woff"
    ".woff2" = "font/woff2"
}

function Write-TextResponse {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [int]$StatusCode,
        [string]$Body,
        [string]$ContentType = "text/plain; charset=utf-8"
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Write-JsonResponse {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [int]$StatusCode,
        $Payload,
        [int]$Depth = 6
    )
    $json = $Payload | ConvertTo-Json -Depth $Depth -Compress
    Write-TextResponse -Context $Context -StatusCode $StatusCode -Body $json -ContentType "application/json; charset=utf-8"
}

function Write-BytesResponse {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [int]$StatusCode,
        [byte[]]$Bytes,
        [string]$ContentType = "application/octet-stream"
    )

    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentLength64 = $Bytes.Length
    $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $response.OutputStream.Close()
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Read-RequestBody {
    param([Parameter(Mandatory = $true)]$Context)
    # Always decode as UTF-8: HttpListener.ContentEncoding falls back to Windows-1252
    # when the request's Content-Type has no charset, which mangles curly apostrophes
    # and other non-ASCII chars in JSON payloads.
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-JsonPayloadProperty {
    param(
        $Payload,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Payload) { return $null }
    $prop = $Payload.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-XmlDeviceAccount {
    param([Parameter(Mandatory = $true)][string]$XmlPath)

    if (-not (Test-Path -LiteralPath $XmlPath -PathType Leaf)) { return "" }
    try {
        $content = [System.IO.File]::ReadAllText($XmlPath)
    } catch {
        return ""
    }
    $match = [regex]::Match($content, '<string\s+name=["'']deviceAccount["'']>([^<]+)</string>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return "" }
    return $match.Groups[1].Value.Trim()
}

function Find-AccountXml {
    param(
        [Parameter(Mandatory = $true)][string]$Account,
        [string]$FileName
    )
    $savedRoot = Join-Path $resolvedRoot "Accounts\Saved"
    if (-not (Test-Path -LiteralPath $savedRoot -PathType Container)) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($FileName)) {
        # Reject anything that looks like a path traversal attempt before any IO.
        if ($FileName -match "[\\/:*?""<>|]" -or $FileName -match "\.\.") { return $null }

        # Strip a trailing .xml so we can build wildcard patterns either way.
        $stem = $FileName
        if ($stem -match "\.xml$") { $stem = $stem.Substring(0, $stem.Length - 4) }
        if (-not [string]::IsNullOrWhiteSpace($stem)) {
            $exactName = "$stem.xml"
            $wildcardName = "*$stem*.xml"

            # Helper: prefer exact match, otherwise the most recently modified wildcard hit.
            $resolveIn = {
                param($root)
                if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
                $exact = Get-ChildItem -LiteralPath $root -Recurse -Filter $exactName -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exact) { return $exact.FullName }
                $fuzzy = Get-ChildItem -LiteralPath $root -Recurse -Filter $wildcardName -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
                if ($fuzzy) { return $fuzzy.FullName }
                return $null
            }

            # Prefer the device-specific subfolder when the account looks like a folder name.
            if ($Account -match "^[A-Za-z0-9_-]{1,32}$") {
                $preferredDir = Join-Path $savedRoot $Account
                $hit = & $resolveIn $preferredDir
                if ($hit) { return $hit }
            }

            # Fallback: search the entire Saved tree by filename.
            $hit = & $resolveIn $savedRoot
            if ($hit) { return $hit }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Account)) { return $null }

    # Final fallback: inspect XML contents and match the embedded deviceAccount.
    $contentMatch = Get-ChildItem -LiteralPath $savedRoot -Recurse -Filter "*.xml" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Where-Object { (Get-XmlDeviceAccount -XmlPath $_.FullName) -eq $Account } |
        Select-Object -First 1
    if ($contentMatch) { return $contentMatch.FullName }

    return $null
}

function Update-InjectIni {
    param(
        [Parameter(Mandatory = $true)][string]$IniPath,
        [Parameter(Mandatory = $true)][hashtable]$UserSettings
    )
    # The .ahk reads via IniRead which expects UTF-16 LE BOM (current format).
    $existing = @()
    if (Test-Path -LiteralPath $IniPath -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllLines($IniPath, [System.Text.Encoding]::Unicode)
    }

    $output = New-Object System.Collections.Generic.List[string]
    $currentSection = ""
    $remaining = @{}
    foreach ($k in $UserSettings.Keys) { $remaining[$k] = $true }
    $userSettingsSeen = $false

    foreach ($line in $existing) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            # Before leaving [UserSettings], flush any keys we did not encounter.
            if ($currentSection -eq "UserSettings") {
                foreach ($k in @($remaining.Keys)) {
                    if ($remaining[$k]) {
                        $output.Add("$k=$($UserSettings[$k])")
                        $remaining[$k] = $false
                    }
                }
            }
            $currentSection = $matches[1]
            if ($currentSection -eq "UserSettings") { $userSettingsSeen = $true }
            $output.Add($line)
            continue
        }

        if ($currentSection -eq "UserSettings" -and $line -match '^\s*([^=;\s][^=]*?)\s*=') {
            $key = $matches[1]
            if ($UserSettings.ContainsKey($key)) {
                $output.Add("$key=$($UserSettings[$key])")
                $remaining[$key] = $false
                continue
            }
        }

        $output.Add($line)
    }

    # Flush any keys still missing.
    if (-not $userSettingsSeen) {
        $output.Add("[UserSettings]")
    }
    foreach ($k in @($remaining.Keys)) {
        if ($remaining[$k]) {
            $output.Add("$k=$($UserSettings[$k])")
        }
    }

    # Preserve UTF-16 LE with BOM (matches what AHK IniRead expects on the existing file).
    $encoding = New-Object System.Text.UnicodeEncoding($false, $true)
    [System.IO.File]::WriteAllLines($IniPath, $output, $encoding)
}

function Normalize-InjectExtraFriendIdsText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $t = [string]$Text
    $t = $t -replace "[\r\n\t]+", ","
    $t = $t -replace "\|", ","
    $t = $t -replace ",+", ","
    $t = $t.Trim().Trim(",").Trim()
    $parts = @(
        $t.Split(",") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" } |
            ForEach-Object { $_ -replace "[=\[\]\r\n]", "" } |
            Where-Object { $_ -match '^\d{16}$' }
    )
    if ($parts.Count -eq 0) { return "" }
    return ($parts -join ",")
}


function Get-InjectFriendSettingsFromIni {
    param([Parameter(Mandatory = $true)][string]$IniPath)
    $settings = Read-IniSection -IniPath $IniPath -Section "UserSettings"
    $favoriteFriendIds = ""
    if ($settings.ContainsKey("favoriteFriendIDs")) {
        $favoriteFriendIds = Normalize-InjectExtraFriendIdsText -Text ([string]$settings["favoriteFriendIDs"])
    }
    $injectExtraFriendIds = ""
    if ($settings.ContainsKey("injectExtraFriendIDs")) {
        $injectExtraFriendIds = Normalize-InjectExtraFriendIdsText -Text ([string]$settings["injectExtraFriendIDs"])
    }
    if ([string]::IsNullOrWhiteSpace($favoriteFriendIds) -and -not [string]::IsNullOrWhiteSpace($injectExtraFriendIds)) {
        $favoriteFriendIds = $injectExtraFriendIds
    }
    $injectSelectedFriendIds = ""
    if ($settings.ContainsKey("injectSelectedFriendIDs")) {
        $injectSelectedFriendIds = Normalize-InjectExtraFriendIdsText -Text ([string]$settings["injectSelectedFriendIDs"])
    }
    if ([string]::IsNullOrWhiteSpace($injectSelectedFriendIds) -and -not [string]::IsNullOrWhiteSpace($injectExtraFriendIds)) {
        $injectSelectedFriendIds = $injectExtraFriendIds
    }
    $favoriteFriendLabels = ""
    if ($settings.ContainsKey("favoriteFriendLabels")) {
        $favoriteFriendLabels = [string]$settings["favoriteFriendLabels"]
    }
    return [pscustomobject]@{
        favoriteFriendIds = $favoriteFriendIds
        favoriteFriendLabels = $favoriteFriendLabels
        injectSelectedFriendIds = $injectSelectedFriendIds
        injectExtraFriendIds = $injectExtraFriendIds
    }
}

function Build-InjectFriendRequestIds {
    param(
        [AllowNull()][AllowEmptyString()][string]$SelectedFriendIds
    )
    return (Normalize-InjectExtraFriendIdsText -Text ([string]$SelectedFriendIds))
}

function Resolve-AutoHotkeyExe {
    $candidates = @(
        "$env:ProgramFiles\AutoHotkey\AutoHotkey.exe",
        "$env:ProgramFiles\AutoHotkey\v1.1\AutoHotkeyU64.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkeyU64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\AutoHotkey.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

function Read-IniSection {
    param(
        [Parameter(Mandatory = $true)][string]$IniPath,
        [Parameter(Mandatory = $true)][string]$Section
    )
    $result = @{}
    if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) { return $result }
    $lines = [System.IO.File]::ReadAllLines($IniPath, [System.Text.Encoding]::Unicode)
    $current = ""
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $current = $matches[1]; continue }
        if ($current -ne $Section) { continue }
        if ($line -match '^\s*([^=;\s][^=]*?)\s*=\s*(.*)\s*$') {
            $result[$matches[1]] = $matches[2]
        }
    }
    return $result
}

function Resolve-MumuBaseFolder {
    param(
        [Parameter(Mandatory = $true)][string]$InjectIniPath,
        [Parameter(Mandatory = $true)][string]$SettingsIniPath
    )

    $injectSettings = Read-IniSection -IniPath $InjectIniPath -Section "UserSettings"
    $settingsIniSettings = Read-IniSection -IniPath $SettingsIniPath -Section "ToolsAndSystem"
    $candidates = New-Object System.Collections.Generic.List[object]

    if ($injectSettings.ContainsKey("folderPath") -and -not [string]::IsNullOrWhiteSpace($injectSettings["folderPath"])) {
        $candidates.Add([pscustomobject]@{
            Path = [string]$injectSettings["folderPath"]
            Source = "Accounts\InjectAccount.ini"
        })
    }
    if ($settingsIniSettings.ContainsKey("folderPath") -and -not [string]::IsNullOrWhiteSpace($settingsIniSettings["folderPath"])) {
        $candidates.Add([pscustomobject]@{
            Path = [string]$settingsIniSettings["folderPath"]
            Source = "Settings.ini"
        })
    }
    $candidates.Add([pscustomobject]@{
        Path = "C:\Program Files\Netease"
        Source = "default"
    })

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate.Path -PathType Container) {
            return [pscustomobject]@{
                Path = $candidate.Path
                Source = $candidate.Source
                InjectSettings = $injectSettings
            }
        }
    }

    return [pscustomobject]@{
        Path = $candidates[0].Path
        Source = $candidates[0].Source
        InjectSettings = $injectSettings
    }
}

function Resolve-MumuFolder {
    param([Parameter(Mandatory = $true)][string]$BaseFolder)
    if (Test-Path -LiteralPath (Join-Path $BaseFolder "vms") -PathType Container) {
        return $BaseFolder
    }
    $candidates = @(
        "MuMu",
        "MuMuPlayerGlobal-12.0",
        "MuMuPlayerGlobal",
        "MuMuPlayer-12.0",
        "MuMu Player 12",
        "MuMuPlayer",
        "MuMuPlayer-12",
        "MuMuPlayer12"
    )
    foreach ($c in $candidates) {
        $p = Join-Path $BaseFolder $c
        if (Test-Path -LiteralPath $p -PathType Container) { return $p }
    }
    return $null
}

function Get-MumuInstances {
    param([Parameter(Mandatory = $true)][string]$BaseFolder)
    $instances = @()
    $mumuFolder = Resolve-MumuFolder -BaseFolder $BaseFolder
    if (-not $mumuFolder) { return $instances }
    $vmsRoot = Join-Path $mumuFolder "vms"
    if (-not (Test-Path -LiteralPath $vmsRoot -PathType Container)) { return $instances }
    $vmDirs = Get-ChildItem -LiteralPath $vmsRoot -Directory -ErrorAction SilentlyContinue
    foreach ($vm in $vmDirs) {
        $extra = Join-Path $vm.FullName "configs\extra_config.json"
        if (-not (Test-Path -LiteralPath $extra -PathType Leaf)) { continue }
        try {
            $content = [System.IO.File]::ReadAllText($extra)
            $m = [regex]::Match($content, '"playerName"\s*:\s*"([^"]*)"')
            if (-not $m.Success) { continue }
            $name = $m.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            # Also pull adb host port from vm_config.json (best-effort, optional metadata).
            $port = $null
            $vmCfg = Join-Path $vm.FullName "configs\vm_config.json"
            if (Test-Path -LiteralPath $vmCfg -PathType Leaf) {
                $vmContent = [System.IO.File]::ReadAllText($vmCfg)
                $pm = [regex]::Match($vmContent, '"host_port"\s*:\s*"(\d+)"')
                if ($pm.Success) { $port = [int]$pm.Groups[1].Value }
            }
            $instances += [pscustomobject]@{
                name = $name
                vm = $vm.Name
                adbPort = $port
            }
        } catch { continue }
    }
    return $instances
}

function Invoke-ListInstances {
    param([Parameter(Mandatory = $true)]$Context)
    $accountsDir = Join-Path $resolvedRoot "Accounts"
    $iniPath = Join-Path $accountsDir "InjectAccount.ini"
    $settingsPath = Join-Path $resolvedRoot "Settings.ini"
    $folderConfig = Resolve-MumuBaseFolder -InjectIniPath $iniPath -SettingsIniPath $settingsPath
    $settings = $folderConfig.InjectSettings
    $folderPath = $folderConfig.Path
    if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{
            ok = $false
            error = "MuMu base folder not found. Checked Accounts\InjectAccount.ini, Settings.ini [ToolsAndSystem] folderPath, and the default C:\Program Files\Netease."
        }
        return
    }
    $instances = Get-MumuInstances -BaseFolder $folderPath
    $friendSettings = Get-InjectFriendSettingsFromIni -IniPath $iniPath
    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
        ok = $true
        folderPath = $folderPath
        folderPathSource = $folderConfig.Source
        defaultInstance = if ($settings.ContainsKey("winTitle")) { $settings["winTitle"] } else { "" }
        injectExtraFriendIds = $friendSettings.injectExtraFriendIds
        favoriteFriendIds = $friendSettings.favoriteFriendIds
        favoriteFriendLabels = $friendSettings.favoriteFriendLabels
        injectSelectedFriendIds = $friendSettings.injectSelectedFriendIds
        instances = $instances
    }
}

function Invoke-LaunchInstance {
    param([Parameter(Mandatory = $true)]$Context)

    $bodyText = Read-RequestBody -Context $Context
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Empty request body." }
        return
    }
    try { $payload = $bodyText | ConvertFrom-Json } catch {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid JSON body." }
        return
    }

    $name = [string]$payload.name
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Missing 'name'." }
        return
    }
    if ($name -match '[\r\n=\[\]"]') {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid characters in instance name." }
        return
    }

    $accountsDir = Join-Path $resolvedRoot "Accounts"
    $iniPath = Join-Path $accountsDir "InjectAccount.ini"
    $settingsPath = Join-Path $resolvedRoot "Settings.ini"
    $folderConfig = Resolve-MumuBaseFolder -InjectIniPath $iniPath -SettingsIniPath $settingsPath
    $folderPath = $folderConfig.Path
    $mumuFolder = Resolve-MumuFolder -BaseFolder $folderPath
    if (-not $mumuFolder) {
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{ ok = $false; error = "MuMu folder not found under $folderPath." }
        return
    }

    # Find vm folder whose extra_config.json playerName matches.
    $vmsRoot = Join-Path $mumuFolder "vms"
    $instanceNum = $null
    $vmFolderName = $null
    if (Test-Path -LiteralPath $vmsRoot -PathType Container) {
        foreach ($vm in Get-ChildItem -LiteralPath $vmsRoot -Directory -ErrorAction SilentlyContinue) {
            $extra = Join-Path $vm.FullName "configs\extra_config.json"
            if (-not (Test-Path -LiteralPath $extra -PathType Leaf)) { continue }
            try {
                $content = [System.IO.File]::ReadAllText($extra)
                $m = [regex]::Match($content, '"playerName"\s*:\s*"([^"]*)"')
                if ($m.Success -and $m.Groups[1].Value -eq $name) {
                    $vmFolderName = $vm.Name
                    $nm = [regex]::Match($vm.Name, '[^-]+$')
                    if ($nm.Success) { $instanceNum = $nm.Value }
                    break
                }
            } catch { continue }
        }
    }
    if (-not $instanceNum) {
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{ ok = $false; error = "Could not resolve instance number for '$name'." }
        return
    }

    $mumuExe = Join-Path $mumuFolder "shell\MuMuPlayer.exe"
    if (-not (Test-Path -LiteralPath $mumuExe -PathType Leaf)) {
        $mumuExe = Join-Path $mumuFolder "nx_main\MuMuNxMain.exe"
    }
    if (-not (Test-Path -LiteralPath $mumuExe -PathType Leaf)) {
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{ ok = $false; error = "MuMuPlayer.exe not found in $mumuFolder." }
        return
    }

    try {
        Start-Process -FilePath $mumuExe -ArgumentList @("-v", $instanceNum) -WorkingDirectory (Split-Path -Parent $mumuExe) | Out-Null
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{ ok = $false; error = "Failed to launch: $($_.Exception.Message)" }
        return
    }

    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
        ok = $true
        name = $name
        vm = $vmFolderName
        instance = $instanceNum
    }
}

function Invoke-InjectAccount {
    param([Parameter(Mandatory = $true)]$Context)

    $bodyText = Read-RequestBody -Context $Context
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Empty request body." }
        return
    }

    try { $payload = $bodyText | ConvertFrom-Json } catch {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid JSON body." }
        return
    }

    $account = [string]$payload.account
    $fileName = [string]$payload.fileName
    $winTitle = [string]$payload.winTitle
    $sendFriendRequest = $false
    if ($null -ne $payload.sendFriendRequest) {
        try { $sendFriendRequest = [bool]$payload.sendFriendRequest } catch { $sendFriendRequest = $false }
    }
    $selectedFriendIds = ""
    $selectedProp = $payload.PSObject.Properties["selectedFriendIds"]
    if ($null -ne $selectedProp) {
        $selectedFriendIds = Normalize-InjectExtraFriendIdsText -Text ([string]$selectedProp.Value)
    }
    $favoriteFriendIds = ""
    $favoriteProp = $payload.PSObject.Properties["favoriteFriendIds"]
    if ($null -ne $favoriteProp) {
        $favoriteFriendIds = Normalize-InjectExtraFriendIdsText -Text ([string]$favoriteProp.Value)
    }
    $favoriteFriendLabels = ""
    $favoriteLabelsProp = $payload.PSObject.Properties["favoriteFriendLabels"]
    if ($null -ne $favoriteLabelsProp) {
        $favoriteFriendLabels = [string]$favoriteLabelsProp.Value
        $favoriteFriendLabels = ($favoriteFriendLabels -replace "[\r\n=]", " ").Trim()
    }
    if ([string]::IsNullOrWhiteSpace($selectedFriendIds)) {
        $injectExtraProp = $payload.PSObject.Properties["injectExtraFriendIds"]
        if ($null -ne $injectExtraProp) {
            $selectedFriendIds = Normalize-InjectExtraFriendIdsText -Text ([string]$injectExtraProp.Value)
        }
    }
    if ([string]::IsNullOrWhiteSpace($account)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "The 'account' field is required." }
        return
    }

    $xmlPath = Find-AccountXml -Account $account -FileName $fileName
    if (-not $xmlPath) {
        $searchHint = if ([string]::IsNullOrWhiteSpace($fileName)) {
            "deviceAccount '$account'"
        } else {
            "file '$fileName' or deviceAccount '$account'"
        }
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{ ok = $false; error = "No XML matching $searchHint was found under Accounts\Saved." }
        return
    }

    $accountsDir = Join-Path $resolvedRoot "Accounts"
    $iniPath = Join-Path $accountsDir "InjectAccount.ini"
    $ahkPath = Join-Path $accountsDir "_InjectAccount.ahk"

    if (-not (Test-Path -LiteralPath $ahkPath -PathType Leaf)) {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{ ok = $false; error = "_InjectAccount.ahk not found." }
        return
    }

    # fileName must be without extension (the AHK script appends .xml at runtime).
    $fileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($xmlPath)

    $resolvedFriendRequestIds = Build-InjectFriendRequestIds -SelectedFriendIds $selectedFriendIds

    $iniValues = @{
        fileName = $fileNameNoExt
        selectedFilePath = $xmlPath
        sendFriendRequestAfterInject = if ($sendFriendRequest) { 1 } else { 0 }
        injectSelectedFriendIDs = $selectedFriendIds
        injectExtraFriendIDs = $selectedFriendIds
        injectFriendRequestIds = $resolvedFriendRequestIds
    }
    if (-not [string]::IsNullOrWhiteSpace($favoriteFriendIds)) {
        $iniValues["favoriteFriendIDs"] = $favoriteFriendIds
    }
    if ($null -ne $favoriteLabelsProp) {
        $iniValues["favoriteFriendLabels"] = $favoriteFriendLabels
    }
    if (-not [string]::IsNullOrWhiteSpace($winTitle)) {
        # Reject anything weird so we don't write garbage that breaks the ini.
        if ($winTitle -match "[`r`n=\[\]]") {
            Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid winTitle." }
            return
        }
        $iniValues["winTitle"] = $winTitle
    }

    try {
        Update-InjectIni -IniPath $iniPath -UserSettings $iniValues
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{ ok = $false; error = "Failed to update InjectAccount.ini: $($_.Exception.Message)" }
        return
    }

    $headless = -not [string]::IsNullOrWhiteSpace($winTitle)
    $ahkExe = Resolve-AutoHotkeyExe
    try {
        $argList = @()
        if ($ahkExe) { $argList += "`"$ahkPath`"" }
        if ($headless) { $argList += "/headless" }
        if ($ahkExe) {
            Start-Process -FilePath $ahkExe -ArgumentList $argList -WorkingDirectory $accountsDir | Out-Null
        } elseif ($headless) {
            Start-Process -FilePath $ahkPath -ArgumentList @("/headless") -WorkingDirectory $accountsDir | Out-Null
        } else {
            Start-Process -FilePath $ahkPath -WorkingDirectory $accountsDir | Out-Null
        }
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{ ok = $false; error = "Failed to launch AutoHotkey: $($_.Exception.Message)" }
        return
    }

    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
        ok = $true
        file = $xmlPath
        fileName = $fileNameNoExt
        account = $account
        winTitle = $winTitle
        headless = $headless
        sendFriendRequest = $sendFriendRequest
        launcher = if ($ahkExe) { $ahkExe } else { "shell-association" }
    }
}

function ConvertTo-JsonStringLiteral {
    param([AllowNull()][string]$Value)
    return [string]($Value | ConvertTo-Json -Compress)
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-DashboardAccountManifest {
    param(
        [Parameter(Mandatory = $true)][string]$AccountsDataDir,
        [string]$CollectionsDataDir = ""
    )

    $entries = New-Object System.Collections.Generic.List[object]
    $manifestBuilder = New-Object System.Text.StringBuilder
    $totalLength = [int64]0

    $dirs = @(
        @{ Bucket = "accounts"; Path = $AccountsDataDir }
    )
    if ($CollectionsDataDir -and (Test-Path -LiteralPath $CollectionsDataDir -PathType Container)) {
        $dirs += @{ Bucket = "collections"; Path = $CollectionsDataDir }
    }

    foreach ($dirInfo in $dirs) {
        $bucket = [string]$dirInfo.Bucket
        $dirPath = [string]$dirInfo.Path
        $files = @(Get-ChildItem -LiteralPath $dirPath -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($file in $files) {
            $sourceName = $bucket + "/" + $file.Name
            $totalLength += [int64]$file.Length
            [void]$manifestBuilder.Append($sourceName).Append("|").Append($file.Length).Append("|").Append($file.LastWriteTimeUtc.Ticks).Append("`n")
            $entries.Add([pscustomobject]@{
                File = $file
                SourceName = $sourceName
            })
        }
    }

    return [pscustomobject]@{
        Files = $entries
        Signature = Get-TextSha256 -Text $manifestBuilder.ToString()
        Count = $entries.Count
        TotalLength = $totalLength
    }
}

function Test-DashboardAccountsCache {
    param(
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][string]$MetaPath,
        [Parameter(Mandatory = $true)]$Manifest
    )

    if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $MetaPath -PathType Leaf)) { return $false }

    try {
        $cacheFile = Get-Item -LiteralPath $CachePath -ErrorAction Stop
        if ($cacheFile.Length -le 0) { return $false }

        $metaText = [System.IO.File]::ReadAllText($MetaPath)
        $meta = $metaText | ConvertFrom-Json
        return [string]$meta.signature -eq [string]$Manifest.Signature
    } catch {
        return $false
    }
}

function Add-DashboardJsonDefaults {
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $trimmed = $JsonText.Trim()
    if ($trimmed.Length -lt 2 -or -not $trimmed.StartsWith("{") -or -not $trimmed.EndsWith("}")) {
        throw "Account JSON is not an object."
    }

    $isCollection = $FileName -like "collections/*"
    $leafName = [System.IO.Path]::GetFileName($FileName)
    $stemName = [System.IO.Path]::GetFileNameWithoutExtension($leafName)

    $extraFields = New-Object System.Collections.Generic.List[string]
    if ($trimmed -notmatch '(?i)"deviceAccount"\s*:') {
        $deviceAccount = $stemName
        $extraFields.Add('"deviceAccount":' + (ConvertTo-JsonStringLiteral -Value $deviceAccount))
    }
    if ($trimmed -notmatch '(?i)"metadata"\s*:') {
        $extraFields.Add('"metadata":{}')
    }
    if ($trimmed -notmatch '(?i)"pulls"\s*:') {
        $extraFields.Add('"pulls":[]')
    }
    if ($trimmed -notmatch '(?i)"registeredCards"\s*:') {
        $extraFields.Add('"registeredCards":[]')
    }
    if ($trimmed -notmatch '(?i)"sourceFileName"\s*:') {
        $extraFields.Add('"sourceFileName":' + (ConvertTo-JsonStringLiteral -Value $FileName))
    }
    if ($isCollection) {
        if ($trimmed -notmatch '(?i)"sourceType"\s*:') {
            $extraFields.Add('"sourceType":"collection"')
        }
        if ($trimmed -notmatch '(?i)"collectionId"\s*:') {
            $extraFields.Add('"collectionId":' + (ConvertTo-JsonStringLiteral -Value $stemName))
        }
        if ($trimmed -notmatch '(?i)"displayName"\s*:') {
            $extraFields.Add('"displayName":' + (ConvertTo-JsonStringLiteral -Value $stemName))
        }
    }

    if ($extraFields.Count -eq 0) {
        return $trimmed
    }

    $prefix = $trimmed.Substring(0, $trimmed.Length - 1).TrimEnd()
    $extrasJson = [string]::Join(",", $extraFields)
    if ($prefix.EndsWith("{")) {
        return $prefix + $extrasJson + "}"
    }
    return $prefix + "," + $extrasJson + "}"
}

function Convert-SkippedFilesToJson {
    param([Parameter(Mandatory = $true)]$SkippedFiles)

    if ($SkippedFiles.Count -eq 0) { return "[]" }

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in $SkippedFiles) {
        $items.Add(
            '{"file":' +
            (ConvertTo-JsonStringLiteral -Value ([string]$item.File)) +
            ',"error":' +
            (ConvertTo-JsonStringLiteral -Value ([string]$item.Error)) +
            '}'
        )
    }
    return "[" + [string]::Join(",", $items) + "]"
}

function New-DashboardAccountsPayload {
    param([Parameter(Mandatory = $true)]$Files)

    $accountsBuilder = New-Object System.Text.StringBuilder
    $skipped = New-Object System.Collections.Generic.List[object]
    $accountCount = 0

    foreach ($entry in $Files) {
        try {
            $file = $entry.File
            $sourceName = [string]$entry.SourceName
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $documentJson = Add-DashboardJsonDefaults -JsonText $text -FileName $sourceName
            if ($accountCount -gt 0) {
                [void]$accountsBuilder.Append(",")
            }
            [void]$accountsBuilder.Append($documentJson)
            $accountCount++
        } catch {
            $skipped.Add([pscustomobject]@{
                File = $sourceName
                Error = $_.Exception.Message
            })
        }
    }

    $skippedJson = Convert-SkippedFilesToJson -SkippedFiles $skipped
    $payloadBuilder = New-Object System.Text.StringBuilder
    [void]$payloadBuilder.Append('{"ok":true,"source":"Accounts/Cards/accounts+collections","accountCount":')
    [void]$payloadBuilder.Append($accountCount)
    [void]$payloadBuilder.Append(',"skippedCount":')
    [void]$payloadBuilder.Append($skipped.Count)
    [void]$payloadBuilder.Append(',"skipped":')
    [void]$payloadBuilder.Append($skippedJson)
    [void]$payloadBuilder.Append(',"accounts":[')
    [void]$payloadBuilder.Append($accountsBuilder.ToString())
    [void]$payloadBuilder.Append("]}")

    return [pscustomobject]@{
        Json = $payloadBuilder.ToString()
        AccountCount = $accountCount
        SkippedCount = $skipped.Count
    }
}

function Invoke-DashboardIndexBuilder {
    $carddbPath = Join-Path $resolvedRoot "Helper\carddb.exe"
    if (-not (Test-Path -LiteralPath $carddbPath -PathType Leaf)) {
        return $false
    }

    try {
        & $carddbPath @("--root", $resolvedRoot, "ensure-dashboard-index") 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-DashboardIndexCache {
    param(
        [Parameter(Mandatory = $true)][string]$MetaPath,
        [Parameter(Mandatory = $true)]$Manifest
    )

    if (-not (Test-Path -LiteralPath $MetaPath -PathType Leaf)) { return $false }

    try {
        $metaText = [System.IO.File]::ReadAllText($MetaPath)
        $meta = $metaText | ConvertFrom-Json
        return [string]$meta.signature -eq [string]$Manifest.Signature
    } catch {
        return $false
    }
}

function Invoke-LoadAccountsSummary {
    param([Parameter(Mandatory = $true)]$Context)

    $cardsDir = Join-Path $resolvedRoot "Accounts\Cards"
    $cacheDir = Join-Path $cardsDir "database_cache"
    $summaryPath = Join-Path $cacheDir "accounts-summary.json"
    $indexMetaPath = Join-Path $cacheDir "dashboard-index.meta.json"
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

    $accountsDataDir = Join-Path $cardsDir "accounts"
    $collectionsDataDir = Join-Path $cardsDir "collections"
    $manifest = Get-DashboardAccountManifest -AccountsDataDir $accountsDataDir -CollectionsDataDir $collectionsDataDir

    if (-not (Test-DashboardIndexCache -MetaPath $indexMetaPath -Manifest $manifest)) {
        [void](Invoke-DashboardIndexBuilder)
    }

    if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($summaryPath)
            Write-BytesResponse -Context $Context -StatusCode 200 -Bytes $bytes -ContentType "application/json; charset=utf-8"
            return
        } catch {
            # Fall through and rebuild.
        }
    }

    if (Invoke-DashboardIndexBuilder) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($summaryPath)
            Write-BytesResponse -Context $Context -StatusCode 200 -Bytes $bytes -ContentType "application/json; charset=utf-8"
            return
        } catch {}
    }

    Write-JsonResponse -Context $Context -StatusCode 503 -Payload @{ ok = $false; error = "Dashboard index unavailable." }
}

function Invoke-LoadDashboardRows {
    param([Parameter(Mandatory = $true)]$Context)

    $cardsDir = Join-Path $resolvedRoot "Accounts\Cards"
    $cacheDir = Join-Path $cardsDir "database_cache"
    $rowsPath = Join-Path $cacheDir "dashboard-rows.jsonl"
    $indexMetaPath = Join-Path $cacheDir "dashboard-index.meta.json"
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

    $accountsDataDir = Join-Path $cardsDir "accounts"
    $collectionsDataDir = Join-Path $cardsDir "collections"
    $manifest = Get-DashboardAccountManifest -AccountsDataDir $accountsDataDir -CollectionsDataDir $collectionsDataDir

    if (-not (Test-DashboardIndexCache -MetaPath $indexMetaPath -Manifest $manifest)) {
        [void](Invoke-DashboardIndexBuilder)
    }

    if (Test-Path -LiteralPath $rowsPath -PathType Leaf) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($rowsPath)
            Write-BytesResponse -Context $Context -StatusCode 200 -Bytes $bytes -ContentType "application/x-ndjson; charset=utf-8"
            return
        } catch {
            # Fall through and rebuild.
        }
    }

    if (Invoke-DashboardIndexBuilder) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($rowsPath)
            Write-BytesResponse -Context $Context -StatusCode 200 -Bytes $bytes -ContentType "application/x-ndjson; charset=utf-8"
            return
        } catch {}
    }

    Write-JsonResponse -Context $Context -StatusCode 503 -Payload @{ ok = $false; error = "Dashboard rows unavailable." }
}

function Invoke-DashboardCacheBuilder {
    param(
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][string]$MetaPath,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $carddbPath = Join-Path $resolvedRoot "Helper\carddb.exe"
    if (-not (Test-Path -LiteralPath $carddbPath -PathType Leaf)) {
        return $false
    }

    try {
        $args = @(
            "--root", $resolvedRoot,
            "build-dashboard-cache",
            "--output", $CachePath,
            "--meta", $MetaPath,
            "--signature", [string]$Manifest.Signature,
            "--source-count", [string]$Manifest.Count,
            "--source-bytes", [string]$Manifest.TotalLength
        )
        $builderOutput = & $carddbPath @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        return (Test-DashboardAccountsCache -CachePath $CachePath -MetaPath $MetaPath -Manifest $Manifest)
    } catch {
        return $false
    }
}

function Invoke-LoadAccountData {
    param([Parameter(Mandatory = $true)]$Context)

    $cardsDir = Join-Path $resolvedRoot "Accounts\Cards"
    $accountsDataDir = Join-Path $cardsDir "accounts"
    $collectionsDataDir = Join-Path $cardsDir "collections"
    if (-not (Test-Path -LiteralPath $accountsDataDir -PathType Container)) {
        New-Item -ItemType Directory -Path $accountsDataDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $collectionsDataDir -PathType Container)) {
        New-Item -ItemType Directory -Path $collectionsDataDir -Force | Out-Null
    }

    $cacheDir = Join-Path $cardsDir "database_cache"
    $cachePath = Join-Path $cacheDir "accounts-data.cache.json"
    $cacheMetaPath = Join-Path $cacheDir "accounts-data.cache.meta.json"
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $manifest = Get-DashboardAccountManifest -AccountsDataDir $accountsDataDir -CollectionsDataDir $collectionsDataDir

    if (Test-DashboardAccountsCache -CachePath $cachePath -MetaPath $cacheMetaPath -Manifest $manifest) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($cachePath)
            Write-BytesResponse -Context $Context -StatusCode 200 -Bytes $bytes -ContentType "application/json; charset=utf-8"
            return
        } catch {
            # Fall through and rebuild the cache.
        }
    }

    if (Invoke-DashboardCacheBuilder -CachePath $cachePath -MetaPath $cacheMetaPath -Manifest $manifest) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($cachePath)
            Write-BytesResponse -Context $Context -StatusCode 200 -Bytes $bytes -ContentType "application/json; charset=utf-8"
            return
        } catch {
            # Fall through and rebuild using the PowerShell fallback.
        }
    }

    $payload = New-DashboardAccountsPayload -Files $manifest.Files

    try {
        Write-Utf8File -Path $cachePath -Text $payload.Json
        $meta = @{
            signature = $manifest.Signature
            sourceCount = $manifest.Count
            sourceBytes = $manifest.TotalLength
            accountCount = $payload.AccountCount
            skippedCount = $payload.SkippedCount
            generatedAt = (Get-Date).ToUniversalTime().ToString("o")
        } | ConvertTo-Json -Depth 4 -Compress
        Write-Utf8File -Path $cacheMetaPath -Text $meta
    } catch {
        # Cache writes are an optimization; the response should still succeed.
    }

    Write-TextResponse -Context $Context -StatusCode 200 -Body $payload.Json -ContentType "application/json; charset=utf-8"
}

function Get-WishlistPath {
    return Join-Path $resolvedRoot "Accounts\Cards\wishlist.json"
}

function Invoke-GetWishlist {
    param([Parameter(Mandatory = $true)]$Context)

    $path = Get-WishlistPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
            ok = $true
            version = 1
            updatedAt = ""
            cards = @()
        }
        return
    }

    try {
        $text = [System.IO.File]::ReadAllText($path)
        Write-TextResponse -Context $Context -StatusCode 200 -Body $text -ContentType "application/json; charset=utf-8"
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = "Failed to read wishlist.json: $($_.Exception.Message)"
        }
    }
}

function Invoke-SaveWishlist {
    param([Parameter(Mandatory = $true)]$Context)

    $bodyText = Read-RequestBody -Context $Context
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Empty request body." }
        return
    }
    try { $payload = $bodyText | ConvertFrom-Json } catch {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid JSON body." }
        return
    }

    if ($null -eq $payload.cards) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Missing 'cards' field." }
        return
    }

    # Validate and normalise each card entry. Accept either bare cardId strings or {id, name} objects.
    $cardRegex = '^(PK|TR)_\d{2}_\d{6}(_\d{2})?$'
    $normalised = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($entry in $payload.cards) {
        $cardId = $null
        $cardName = ""
        if ($entry -is [string]) {
            $cardId = $entry
        } elseif ($null -ne $entry) {
            $cardId = [string]$entry.id
            if ($null -ne $entry.name) { $cardName = [string]$entry.name }
        }
        if ([string]::IsNullOrWhiteSpace($cardId)) { continue }
        $cardId = $cardId.Trim()
        if ($cardId -notmatch $cardRegex) { continue }
        if (-not $seen.Add($cardId)) { continue }
        $normalised.Add([pscustomobject]@{ id = $cardId; name = $cardName })
    }

    $payloadOut = [ordered]@{
        version = 1
        updatedAt = (Get-Date).ToString("o")
        cards = $normalised.ToArray()
    }
    $json = $payloadOut | ConvertTo-Json -Depth 4

    $path = Get-WishlistPath
    $tmp = "$path.tmp"
    try {
        Write-Utf8File -Path $tmp -Text $json
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = "Failed to write wishlist.json: $($_.Exception.Message)"
        }
        return
    }

    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
        ok = $true
        count = $normalised.Count
        path = $path
    }
}

function Test-DeviceAccountId {
    param([AllowNull()][string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and ($Value -match '^[a-fA-F0-9]{8,64}$')
}

function Get-AccountJsonPath {
    param([Parameter(Mandatory = $true)][string]$DeviceAccount)

    if (-not (Test-DeviceAccountId -Value $DeviceAccount)) { return $null }
    $accountsDir = Join-Path $resolvedRoot "Accounts\Cards\accounts"
    $path = Join-Path $accountsDir ($DeviceAccount + ".json")
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return $path
}

function Test-TradeCardId {
    param([AllowNull()][string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and ($Value -match '^(PK|TR)_\d{2}_\d{6}(_\d{2})?$')
}

function Get-AccountJsonSerializer {
    if (-not $script:AccountJsonSerializer) {
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = 268435456
        $serializer.RecursionLimit = 512
        $script:AccountJsonSerializer = $serializer
    }
    return $script:AccountJsonSerializer
}

function ConvertTo-JsonHashtable {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($entry in $Value.GetEnumerator()) {
            $table[[string]$entry.Key] = ConvertTo-JsonHashtable $entry.Value
        }
        return $table
    }
    if ($Value -is [pscustomobject]) {
        $table = @{}
        foreach ($prop in $Value.PSObject.Properties) {
            $table[[string]$prop.Name] = ConvertTo-JsonHashtable $prop.Value
        }
        return $table
    }
    if ($Value -is [System.Array]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $list.Add((ConvertTo-JsonHashtable $item))
        }
        return $list.ToArray()
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $list.Add((ConvertTo-JsonHashtable $item))
        }
        return $list.ToArray()
    }
    return $Value
}

function Read-AccountJsonDocument {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -notmatch '(?i)"deviceAccount"\s*:\s*"([^"]+)"') {
        throw "Account JSON is missing deviceAccount."
    }
    $deviceAccount = $Matches[1].Trim()
    $serializer = Get-AccountJsonSerializer
    $rawDoc = $serializer.DeserializeObject($text)
    if (-not ($rawDoc -is [System.Collections.IDictionary])) {
        throw "Account JSON root must be an object."
    }
    $doc = ConvertTo-JsonHashtable $rawDoc
    if (-not ($doc -is [hashtable])) {
        throw "Account JSON root must be an object."
    }
    Merge-AccountCardMarksFromMetadataToRoot -Doc $doc | Out-Null
    return [pscustomobject]@{
        Path = $Path
        Text = $text
        DeviceAccount = $deviceAccount
        Doc = $doc
    }
}

function Write-AccountJsonDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Doc
    )

    if ($Doc -isnot [hashtable]) {
        if ($Doc -is [System.Collections.IDictionary]) {
            $Doc = ConvertTo-JsonHashtable $Doc
        } else {
            throw "Account JSON document must be an object."
        }
    }

    $json = ConvertTo-Json -InputObject $Doc -Depth 100
    $tmp = "$Path.tmp"
    Write-Utf8File -Path $tmp -Text $json
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Find-JsonValueEndIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$ValueStartIndex
    )

    $i = $ValueStartIndex
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text, $i)) {
        $i++
    }
    if ($i -ge $Text.Length) {
        throw "Unexpected end of JSON while reading a value."
    }

    $c = $Text[$i]
    if ($c -eq '"') {
        $i++
        $escape = $false
        while ($i -lt $Text.Length) {
            $ch = $Text[$i]
            if ($escape) {
                $escape = $false
                $i++
                continue
            }
            if ($ch -eq '\') {
                $escape = $true
                $i++
                continue
            }
            if ($ch -eq '"') {
                return $i + 1
            }
            $i++
        }
        throw "Unterminated JSON string."
    }

    if ($c -eq '{' -or $c -eq '[') {
        $open = $c
        $close = if ($open -eq '{') { '}' } else { ']' }
        $depth = 0
        $inString = $false
        $escape = $false
        for ($pos = $i; $pos -lt $Text.Length; $pos++) {
            $ch = $Text[$pos]
            if ($inString) {
                if ($escape) {
                    $escape = $false
                    continue
                }
                if ($ch -eq '\') {
                    $escape = $true
                    continue
                }
                if ($ch -eq '"') {
                    $inString = $false
                }
                continue
            }
            if ($ch -eq '"') {
                $inString = $true
                continue
            }
            if ($ch -eq $open) {
                $depth++
                continue
            }
            if ($ch -eq $close) {
                $depth--
                if ($depth -eq 0) {
                    return $pos + 1
                }
            }
        }
        throw "Unterminated JSON object or array."
    }

    $primitiveMatch = [regex]::Match(
        $Text.Substring($i),
        '^(?:true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)'
    )
    if ($primitiveMatch.Success) {
        return $i + $primitiveMatch.Length
    }

    throw "Unsupported JSON value near index $i."
}

function Get-JsonPropertyValueSubstring {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [int]$SearchFrom = 0
    )

    $pattern = '(?ms)"' + [regex]::Escape($PropertyName) + '"\s*:\s*'
    $slice = if ($SearchFrom -gt 0) { $Text.Substring($SearchFrom) } else { $Text }
    $match = [regex]::Match($slice, $pattern)
    if (-not $match.Success) {
        return $null
    }

    $valueStart = $SearchFrom + $match.Index + $match.Length
    $valueEnd = Find-JsonValueEndIndex -Text $Text -ValueStartIndex $valueStart
    return $Text.Substring($valueStart, $valueEnd - $valueStart).Trim()
}

function Remove-JsonObjectPropertyByName {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    $pattern = '(?ms),\s*"' + [regex]::Escape($PropertyName) + '"\s*:\s*'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
        $valueStart = $match.Index + $match.Length
        $valueEnd = Find-JsonValueEndIndex -Text $Text -ValueStartIndex ($valueStart - 1)
        while ($valueStart -lt $Text.Length -and [char]::IsWhiteSpace($Text, $valueStart)) {
            $valueStart++
        }
        if ($valueStart -lt $Text.Length -and $Text[$valueStart] -ne '{' -and $Text[$valueStart] -ne '[') {
            $valueEnd = Find-JsonValueEndIndex -Text $Text -ValueStartIndex $valueStart
        }
        return $Text.Remove($match.Index, $valueEnd - $match.Index)
    }

    $patternLead = '(?ms)"' + [regex]::Escape($PropertyName) + '"\s*:\s*'
    $match = [regex]::Match($Text, $patternLead)
    if (-not $match.Success) {
        return $Text
    }

    $valueStart = $match.Index + $match.Length
    while ($valueStart -lt $Text.Length -and [char]::IsWhiteSpace($Text, $valueStart)) {
        $valueStart++
    }
    $valueEnd = Find-JsonValueEndIndex -Text $Text -ValueStartIndex $valueStart
    $removeLength = $valueEnd - $match.Index
    $tail = $Text.Substring($valueEnd)
    if ($tail -match '^\s*,') {
        $removeLength += ($tail.Length - $tail.TrimStart(',').Length)
    }
    return $Text.Remove($match.Index, $removeLength)
}

function Add-MetadataJsonComma {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [ref]$FirstField
    )

    if (-not $FirstField.Value) {
        [void]$Builder.Append(",`r`n")
    }
    $FirstField.Value = $false
}

function Add-MetadataJsonStringField {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [ref]$FirstField,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value,
        [string]$Indent = "    "
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    Add-MetadataJsonComma -Builder $Builder -FirstField $FirstField
    [void]$Builder.Append($Indent)
    [void]$Builder.Append('"')
    [void]$Builder.Append($Name)
    [void]$Builder.Append('": ')
    [void]$Builder.Append((ConvertTo-JsonStringLiteral -Value $Value))
}

function Add-MetadataJsonNumberField {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [ref]$FirstField,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value,
        [string]$Indent = "    "
    )

    if ($null -eq $Value) { return }
    try {
        $number = [int][Math]::Round([double]$Value)
    } catch {
        return
    }
    if ($Name -ne 'packCount' -and $number -eq 0) { return }
    Add-MetadataJsonComma -Builder $Builder -FirstField $FirstField
    [void]$Builder.Append($Indent)
    [void]$Builder.Append('"')
    [void]$Builder.Append($Name)
    [void]$Builder.Append('": ')
    [void]$Builder.Append([string]$number)
}

function Format-AccountMetadataShinedustJson {
    param($Shinedust)

    if ($null -eq $Shinedust) { return "" }
    $table = Get-CardMarkHashtable $Shinedust
    if (-not $table) { return "" }

    $value = -1
    if ($table.ContainsKey('value')) {
        try { $value = [int][Math]::Round([double]$table['value']) } catch { $value = -1 }
    }
    $lastUpdatedAt = ""
    if ($table.ContainsKey('lastUpdatedAt')) {
        $lastUpdatedAt = [string]$table['lastUpdatedAt']
    }
    if ($value -lt 0 -and ([string]::IsNullOrWhiteSpace($lastUpdatedAt) -or $lastUpdatedAt -eq '0')) {
        return ""
    }

    $builder = New-Object System.Text.StringBuilder
    $first = $true
    [void]$builder.Append("{")
    if ($value -ge 0) {
        if (-not $first) { [void]$builder.Append(",`r`n") }
        [void]$builder.Append("`r`n      ""value"": ")
        [void]$builder.Append([string]$value)
        $first = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($lastUpdatedAt) -and $lastUpdatedAt -ne '0') {
        if (-not $first) { [void]$builder.Append(",`r`n") }
        [void]$builder.Append('      "lastUpdatedAt": ')
        [void]$builder.Append((ConvertTo-JsonStringLiteral -Value $lastUpdatedAt))
        $first = $false
    }
    [void]$builder.Append("`r`n    }")
    return $builder.ToString()
}

function Format-AccountMetadataFlagsJson {
    param($Flags)

    if ($null -eq $Flags) { return "" }
    $table = Get-CardMarkHashtable $Flags
    if (-not $table -or $table.Count -eq 0) { return "" }

    $flagOrder = @('B', 'X', 'T', 'R', 'W', 'H', 'SH')
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append("{")
    $firstFlag = $true
    foreach ($flagName in $flagOrder) {
        if (-not $table.ContainsKey($flagName)) { continue }
        $flag = $table[$flagName]
        $flagTable = Get-CardMarkHashtable $flag
        if (-not $flagTable) { continue }

        $flagValue = 0
        if ($flagTable.ContainsKey('value')) {
            try { $flagValue = [int][Math]::Round([double]$flagTable['value']) } catch { $flagValue = 0 }
        }
        $setAt = if ($flagTable.ContainsKey('setAt')) { [string]$flagTable['setAt'] } else { "" }
        $validUntil = if ($flagTable.ContainsKey('validUntil')) { [string]$flagTable['validUntil'] } else { "" }
        if ($flagValue -le 0 -and [string]::IsNullOrWhiteSpace($setAt) -and [string]::IsNullOrWhiteSpace($validUntil)) {
            continue
        }

        if (-not $firstFlag) { [void]$builder.Append(",`r`n") }
        [void]$builder.Append("`r`n      """)
        [void]$builder.Append($flagName)
        [void]$builder.Append('": {')
        [void]$builder.Append("`r`n")
        $firstField = $true
        if ($flagValue -gt 0) {
            if (-not $firstField) { [void]$builder.Append(",`r`n") }
            [void]$builder.Append('        "value": ')
            [void]$builder.Append([string]$flagValue)
            $firstField = $false
        }
        if (-not [string]::IsNullOrWhiteSpace($setAt)) {
            if (-not $firstField) { [void]$builder.Append(",`r`n") }
            [void]$builder.Append('        "setAt": ')
            [void]$builder.Append((ConvertTo-JsonStringLiteral -Value $setAt))
            $firstField = $false
        }
        if (-not [string]::IsNullOrWhiteSpace($validUntil)) {
            if (-not $firstField) { [void]$builder.Append(",`r`n") }
            [void]$builder.Append('        "validUntil": ')
            [void]$builder.Append((ConvertTo-JsonStringLiteral -Value $validUntil))
            $firstField = $false
        }
        [void]$builder.Append("`r`n      }")
        $firstFlag = $false
    }
    [void]$builder.Append("`r`n    }")
    return $builder.ToString()
}

function Get-CardMarkHashtable {
    param($Value)

    if ($null -eq $Value) { return $null }
    $converted = ConvertTo-JsonHashtable $Value
    if ($converted -is [hashtable]) {
        return $converted
    }
    return $null
}

function Format-AccountMetadataCardMarkEntryJson {
    param(
        [Parameter(Mandatory = $true)][string]$CardId,
        $Mark,
        [int]$EntryIndentSpaces = 4
    )

    $markTable = Get-CardMarkHashtable $Mark
    if (-not $markTable) { return "" }

    $entryPad = (' ' * $EntryIndentSpaces)
    $fieldPad = (' ' * ($EntryIndentSpaces + 2))

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append($entryPad)
    [void]$builder.Append('"')
    [void]$builder.Append($CardId)
    [void]$builder.Append('": {')
    [void]$builder.Append("`r`n")

    $pairings = @()
    if ($markTable.ContainsKey('pairings')) {
        $rawPairings = $markTable['pairings']
        if ($rawPairings -is [System.Array]) {
            $pairings = @($rawPairings)
        } elseif ($rawPairings -is [System.Collections.IEnumerable] -and -not ($rawPairings -is [string])) {
            $pairings = @($rawPairings)
        }
    }
    [void]$builder.Append($fieldPad)
    [void]$builder.Append('"pairings": [')
    $pairingLines = New-Object System.Collections.Generic.List[string]
    $pairingPad = (' ' * ($EntryIndentSpaces + 4))
    $pairingFieldPad = (' ' * ($EntryIndentSpaces + 6))
    foreach ($pairing in $pairings) {
        $pairTable = Get-CardMarkHashtable $pairing
        if (-not $pairTable) { continue }
        $receivedCardId = ""
        if ($pairTable.ContainsKey('receivedCardId')) {
            $receivedCardId = [string]$pairTable['receivedCardId']
        }
        if ([string]::IsNullOrWhiteSpace($receivedCardId)) { continue }
        $timestampMs = 0
        if ($pairTable.ContainsKey('timestampMs')) {
            try { $timestampMs = [int64][Math]::Round([double]$pairTable['timestampMs']) } catch { $timestampMs = 0 }
        }
        $pairingLines.Add(
            $pairingPad + "{`r`n" +
            $pairingFieldPad + """receivedCardId"": " + (ConvertTo-JsonStringLiteral -Value $receivedCardId) +
            ",`r`n" + $pairingFieldPad + """timestampMs"": " + [string]$timestampMs + "`r`n" +
            $pairingPad + "}"
        )
    }
    if ($pairingLines.Count -gt 0) {
        [void]$builder.Append("`r`n")
        [void]$builder.Append(($pairingLines -join ",`r`n"))
        [void]$builder.Append("`r`n")
        [void]$builder.Append($fieldPad)
    }
    [void]$builder.Append("],")

    $timestampMs = 0
    if ($markTable.ContainsKey('timestampMs')) {
        try { $timestampMs = [int64][Math]::Round([double]$markTable['timestampMs']) } catch { $timestampMs = 0 }
    }
    [void]$builder.Append("`r`n")
    [void]$builder.Append($fieldPad)
    [void]$builder.Append('"timestampMs": ')
    [void]$builder.Append([string]$timestampMs)

    $count = 0
    if ($markTable.ContainsKey('count')) {
        try { $count = [int][Math]::Round([double]$markTable['count']) } catch { $count = 0 }
    }
    if ($count -gt 0) {
        [void]$builder.Append(",`r`n")
        [void]$builder.Append($fieldPad)
        [void]$builder.Append('"count": ')
        [void]$builder.Append([string]$count)
    }

    [void]$builder.Append("`r`n")
    [void]$builder.Append($entryPad)
    [void]$builder.Append('}')
    return $builder.ToString()
}

function Format-AccountMetadataSharedCardEntryJson {
    param(
        [Parameter(Mandatory = $true)][string]$CardId,
        $Mark,
        [int]$EntryIndentSpaces = 4
    )

    $markTable = Get-CardMarkHashtable $Mark
    if (-not $markTable) { return "" }

    $entryPad = (' ' * $EntryIndentSpaces)
    $fieldPad = (' ' * ($EntryIndentSpaces + 2))

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append($entryPad)
    [void]$builder.Append('"')
    [void]$builder.Append($CardId)
    [void]$builder.Append('": {')
    [void]$builder.Append("`r`n")

    $timestampMs = 0
    if ($markTable.ContainsKey('timestampMs')) {
        try { $timestampMs = [int64][Math]::Round([double]$markTable['timestampMs']) } catch { $timestampMs = 0 }
    }
    [void]$builder.Append($fieldPad)
    [void]$builder.Append('"timestampMs": ')
    [void]$builder.Append([string]$timestampMs)

    $count = 0
    if ($markTable.ContainsKey('count')) {
        try { $count = [int][Math]::Round([double]$markTable['count']) } catch { $count = 0 }
    }
    if ($count -gt 0) {
        [void]$builder.Append(",`r`n")
        [void]$builder.Append($fieldPad)
        [void]$builder.Append('"count": ')
        [void]$builder.Append([string]$count)
    }

    [void]$builder.Append("`r`n")
    [void]$builder.Append($entryPad)
    [void]$builder.Append('}')
    return $builder.ToString()
}

function Format-AccountMetadataCardMarksPropertyJson {
    param(
        [Parameter(Mandatory = $true)][string]$PropertyName,
        $Marks,
        [int]$PropertyIndentSpaces = 2
    )

    $marksTable = Get-CardMarkHashtable $Marks
    if (-not $marksTable -or $marksTable.Count -eq 0) {
        return ""
    }

    $cardIds = @($marksTable.Keys | ForEach-Object { [string]$_ } | Where-Object { Test-TradeCardId -Value $_ } | Sort-Object)
    if ($cardIds.Count -eq 0) {
        return ""
    }

    $propertyPad = (' ' * $PropertyIndentSpaces)
    $cardEntryIndent = $PropertyIndentSpaces + 2
    $isShared = ($PropertyName -eq 'sharedCards')
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append($propertyPad)
    [void]$builder.Append('"')
    [void]$builder.Append($PropertyName)
    [void]$builder.Append('": {')
    [void]$builder.Append("`r`n")
    $firstCard = $true
    foreach ($cardId in $cardIds) {
        if (-not $firstCard) {
            [void]$builder.Append(",`r`n")
        }
        if ($isShared) {
            [void]$builder.Append((Format-AccountMetadataSharedCardEntryJson -CardId $cardId -Mark $marksTable[$cardId] -EntryIndentSpaces $cardEntryIndent))
        } else {
            [void]$builder.Append((Format-AccountMetadataCardMarkEntryJson -CardId $cardId -Mark $marksTable[$cardId] -EntryIndentSpaces $cardEntryIndent))
        }
        $firstCard = $false
    }
    [void]$builder.Append("`r`n")
    [void]$builder.Append($propertyPad)
    [void]$builder.Append('}')
    return $builder.ToString()
}

function Format-AccountMetadataBlock {
    param([Parameter(Mandatory = $true)][hashtable]$Metadata)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append("{`r`n")
    $firstField = $true

    Add-MetadataJsonStringField -Builder $builder -FirstField ([ref]$firstField) -Name 'instance' -Value ([string]$Metadata['instance'])
    Add-MetadataJsonStringField -Builder $builder -FirstField ([ref]$firstField) -Name 'fileName' -Value ([string]$Metadata['fileName'])
    Add-MetadataJsonStringField -Builder $builder -FirstField ([ref]$firstField) -Name 'accountName' -Value ([string]$Metadata['accountName'])
    Add-MetadataJsonStringField -Builder $builder -FirstField ([ref]$firstField) -Name 'friendCode' -Value ([string]$Metadata['friendCode'])
    Add-MetadataJsonStringField -Builder $builder -FirstField ([ref]$firstField) -Name 'language' -Value ([string]$Metadata['language'])
    Add-MetadataJsonNumberField -Builder $builder -FirstField ([ref]$firstField) -Name 'packCount' -Value $Metadata['packCount']
    Add-MetadataJsonStringField -Builder $builder -FirstField ([ref]$firstField) -Name 'createdAt' -Value ([string]$Metadata['createdAt'])
    Add-MetadataJsonStringField -Builder $builder -FirstField ([ref]$firstField) -Name 'lastPackPulled' -Value ([string]$Metadata['lastPackPulled'])
    Add-MetadataJsonStringField -Builder $builder -FirstField ([ref]$firstField) -Name 'lastLoggedIn' -Value ([string]$Metadata['lastLoggedIn'])

    $shinedustJson = Format-AccountMetadataShinedustJson -Shinedust $Metadata['shinedust']
    if (-not [string]::IsNullOrWhiteSpace($shinedustJson)) {
        Add-MetadataJsonComma -Builder $builder -FirstField ([ref]$firstField)
        [void]$builder.Append('    "shinedust": ')
        [void]$builder.Append($shinedustJson)
    }

    $flagsJson = Format-AccountMetadataFlagsJson -Flags $Metadata['flags']
    if (-not [string]::IsNullOrWhiteSpace($flagsJson)) {
        Add-MetadataJsonComma -Builder $builder -FirstField ([ref]$firstField)
        [void]$builder.Append('    "flags": ')
        [void]$builder.Append($flagsJson)
    }

    [void]$builder.Append("`r`n  }")
    return $builder.ToString()
}

function Merge-AccountCardMarksFromMetadataToRoot {
    param([Parameter(Mandatory = $true)][hashtable]$Doc)

    $metadata = Get-AccountMetadataHashtable -Doc $Doc
    foreach ($propertyName in @('tradedCards', 'sharedCards')) {
        $legacyMarks = $null
        if ($metadata.ContainsKey($propertyName)) {
            $legacyMarks = $metadata[$propertyName]
            $metadata.Remove($propertyName) | Out-Null
        }

        $rootMarks = $null
        if ($Doc.ContainsKey($propertyName)) {
            $rootMarks = $Doc[$propertyName]
        }

        $rootTable = Get-CardMarkHashtable $rootMarks
        $legacyTable = Get-CardMarkHashtable $legacyMarks
        if ($legacyTable -and $legacyTable.Count -gt 0) {
            if (-not $rootTable -or $rootTable.Count -eq 0) {
                $Doc[$propertyName] = ConvertTo-TradeMarksObject -InputObject $legacyTable
            }
        }

        if ($Doc.ContainsKey($propertyName)) {
            $normalised = Normalize-CardMarksInput -InputObject $Doc[$propertyName]
            if ($normalised.Count -eq 0) {
                $Doc.Remove($propertyName) | Out-Null
            } else {
                $Doc[$propertyName] = ConvertTo-TradeMarksObject -InputObject $normalised
            }
        }
    }
}

function Get-AccountCardMarksTable {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Doc,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    Merge-AccountCardMarksFromMetadataToRoot -Doc $Doc | Out-Null
    if (-not $Doc.ContainsKey($PropertyName)) {
        return $null
    }
    return Get-CardMarkHashtable $Doc[$PropertyName]
}

function Write-AccountJsonCardMarksPreserveFormat {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OriginalText,
        [Parameter(Mandatory = $true)][hashtable]$Doc
    )

    if ($Doc -isnot [hashtable]) {
        throw "Account JSON document must be an object."
    }

    $deviceAccount = [string]$Doc['deviceAccount']
    if ([string]::IsNullOrWhiteSpace($deviceAccount)) {
        throw "Account JSON is missing deviceAccount."
    }

    Merge-AccountCardMarksFromMetadataToRoot -Doc $Doc | Out-Null
    $metadata = Get-AccountMetadataHashtable -Doc $Doc
    $metadataJson = Format-AccountMetadataBlock -Metadata $metadata

    $pullsJson = Get-JsonPropertyValueSubstring -Text $OriginalText -PropertyName 'pulls'
    if ([string]::IsNullOrWhiteSpace($pullsJson)) {
        $pullsJson = '[]'
    }

    $registeredCardsJson = Get-JsonPropertyValueSubstring -Text $OriginalText -PropertyName 'registeredCards'
    if ([string]::IsNullOrWhiteSpace($registeredCardsJson) -or $registeredCardsJson -eq '{}') {
        $registeredCardsJson = '[]'
    }

    $tradedJson = Format-AccountMetadataCardMarksPropertyJson `
        -PropertyName 'tradedCards' `
        -Marks (Get-AccountCardMarksTable -Doc $Doc -PropertyName 'tradedCards')
    $sharedJson = Format-AccountMetadataCardMarksPropertyJson `
        -PropertyName 'sharedCards' `
        -Marks (Get-AccountCardMarksTable -Doc $Doc -PropertyName 'sharedCards')

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append("{`r`n")
    [void]$builder.Append('  "deviceAccount": ')
    [void]$builder.Append((ConvertTo-JsonStringLiteral -Value $deviceAccount))
    [void]$builder.Append(",`r`n")
    [void]$builder.Append('  "metadata": ')
    [void]$builder.Append($metadataJson)
    [void]$builder.Append(",`r`n")
    [void]$builder.Append('  "pulls": ')
    [void]$builder.Append($pullsJson)
    [void]$builder.Append(",`r`n")
    [void]$builder.Append('  "registeredCards": ')
    [void]$builder.Append($registeredCardsJson)
    if (-not [string]::IsNullOrWhiteSpace($tradedJson)) {
        [void]$builder.Append(",`r`n")
        [void]$builder.Append($tradedJson)
    }
    if (-not [string]::IsNullOrWhiteSpace($sharedJson)) {
        [void]$builder.Append(",`r`n")
        [void]$builder.Append($sharedJson)
    }
    [void]$builder.Append("`r`n}`r`n")

    $tmp = "$Path.tmp"
    Write-Utf8File -Path $tmp -Text $builder.ToString()
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Invoke-FormatAccountJson {
    param([Parameter(Mandatory = $true)][string]$DeviceAccount)

    if ([string]::IsNullOrWhiteSpace($DeviceAccount)) { return $false }
    $carddbPath = Join-Path $resolvedRoot "Helper\carddb.exe"
    if (-not (Test-Path -LiteralPath $carddbPath -PathType Leaf)) {
        return $false
    }

    try {
        & $carddbPath @('--root', $resolvedRoot, 'format-account', '--device-account', $DeviceAccount) 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function ConvertTo-TradeMarksObject {
    param($InputObject)

    $normalised = Normalize-CardMarksInput -InputObject $InputObject
    if ($normalised.Count -eq 0) { return @{} }
    return ConvertTo-JsonHashtable $normalised
}

function Normalize-CardMarksInput {
    param($InputObject)

    $normalised = [ordered]@{}
    if ($null -eq $InputObject) { return $normalised }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($entry in $InputObject.GetEnumerator()) {
            $cardId = [string]$entry.Key
            if (-not (Test-TradeCardId -Value $cardId)) { continue }
            $normalised[$cardId] = $entry.Value
        }
        return $normalised
    }
    foreach ($prop in $InputObject.PSObject.Properties) {
        $cardId = [string]$prop.Name
        if (-not (Test-TradeCardId -Value $cardId)) { continue }
        $normalised[$cardId] = $prop.Value
    }
    return $normalised
}

function Get-AccountMetadataHashtable {
    param([Parameter(Mandatory = $true)][hashtable]$Doc)

    if (-not $Doc.ContainsKey('metadata') -or $null -eq $Doc['metadata']) {
        $metadata = @{}
        $Doc['metadata'] = $metadata
        return $metadata
    }
    $metadata = $Doc['metadata']
    $converted = ConvertTo-JsonHashtable $metadata
    if (-not ($converted -is [hashtable])) { $converted = @{} }
    $Doc['metadata'] = $converted
    return $converted
}

function Set-AccountCardMarks {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Doc,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        $InputObject
    )

    Merge-AccountCardMarksFromMetadataToRoot -Doc $Doc | Out-Null
    $metadata = Get-AccountMetadataHashtable -Doc $Doc
    if ($metadata.ContainsKey($PropertyName)) {
        $metadata.Remove($PropertyName) | Out-Null
    }

    $normalised = Normalize-CardMarksInput -InputObject $InputObject
    if ($normalised.Count -eq 0) {
        if ($Doc.ContainsKey($PropertyName)) {
            $Doc.Remove($PropertyName) | Out-Null
        }
        return 0
    }
    $Doc[$PropertyName] = ConvertTo-TradeMarksObject -InputObject $normalised
    return $normalised.Count
}

function Invoke-SetAccountCardMarks {
    param([Parameter(Mandatory = $true)]$Context)

    $bodyText = Read-RequestBody -Context $Context
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Empty request body." }
        return
    }
    $bodyText = $bodyText.TrimStart([char]0xFEFF)
    try {
        $payload = $bodyText | ConvertFrom-Json
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid JSON body." }
        return
    }
    if ($null -eq $payload) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "JSON body must be an object." }
        return
    }

    $deviceAccount = [string](Get-JsonPayloadProperty -Payload $payload -Name "deviceAccount")
    if ([string]::IsNullOrWhiteSpace($deviceAccount)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Missing 'deviceAccount' field." }
        return
    }
    $deviceAccount = $deviceAccount.Trim()
    if (-not (Test-DeviceAccountId -Value $deviceAccount)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid deviceAccount." }
        return
    }

    $tradedPayload = Get-JsonPayloadProperty -Payload $payload -Name "tradedCards"
    $sharedPayload = Get-JsonPayloadProperty -Payload $payload -Name "sharedCards"
    $hasTraded = $null -ne $tradedPayload
    $hasShared = $null -ne $sharedPayload
    if (-not $hasTraded -and -not $hasShared) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{
            ok = $false
            error = "Missing 'tradedCards' and/or 'sharedCards' field."
        }
        return
    }

    $path = Get-AccountJsonPath -DeviceAccount $deviceAccount
    if (-not $path) {
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{
            ok = $false
            error = "Account JSON not found for deviceAccount '$deviceAccount'."
        }
        return
    }

    try {
        $loaded = Read-AccountJsonDocument -Path $path
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = "Failed to read account JSON: $($_.Exception.Message)"
        }
        return
    }

    if ($loaded.DeviceAccount -ne $deviceAccount) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{
            ok = $false
            error = "deviceAccount mismatch in account JSON."
        }
        return
    }

    $doc = $loaded.Doc

    $tradedCount = 0
    $sharedCount = 0
    if ($hasTraded) {
        $tradedCount = Set-AccountCardMarks -Doc $doc -PropertyName "tradedCards" -InputObject $tradedPayload
    }
    if ($hasShared) {
        $sharedCount = Set-AccountCardMarks -Doc $doc -PropertyName "sharedCards" -InputObject $sharedPayload
    }

    try {
        Write-AccountJsonCardMarksPreserveFormat -Path $path -OriginalText $loaded.Text -Doc $doc
        Invoke-FormatAccountJson -DeviceAccount $deviceAccount | Out-Null
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = "Failed to write account JSON: $($_.Exception.Message)"
        }
        return
    }

    Invoke-InvalidateAccountCardMarksCache

    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
        ok = $true
        deviceAccount = $deviceAccount
        tradedCount = $tradedCount
        sharedCount = $sharedCount
        path = $path
    }
}

function Invoke-SetAccountTradeMarks {
    param([Parameter(Mandatory = $true)]$Context)
    Invoke-SetAccountCardMarks -Context $Context
}

function Get-AccountCardMarksCachePaths {
    $cacheDir = Join-Path $resolvedRoot "Accounts\Cards\database_cache"
    return [pscustomobject]@{
        Cache = Join-Path $cacheDir "account-card-marks.v2.cache.json"
        Meta = Join-Path $cacheDir "account-card-marks.v2.cache.meta.json"
    }
}

function Invoke-InvalidateAccountCardMarksCache {
    $paths = Get-AccountCardMarksCachePaths
    foreach ($path in @($paths.Cache, $paths.Meta)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-AccountJsonHasCardMarks {
    param([Parameter(Mandatory = $true)][hashtable]$Doc)

    Merge-AccountCardMarksFromMetadataToRoot -Doc $Doc | Out-Null
    $traded = Get-AccountCardMarksTable -Doc $Doc -PropertyName 'tradedCards'
    $shared = Get-AccountCardMarksTable -Doc $Doc -PropertyName 'sharedCards'
    return (
        ($traded -and $traded.Count -gt 0) -or
        ($shared -and $shared.Count -gt 0)
    )
}

function Export-AccountCardMarksEntryFromFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Doc
    )

    $serializer = Get-AccountJsonSerializer
    $text = [System.IO.File]::ReadAllText($Path)
    $entry = @{
        deviceAccount = [string]$Doc['deviceAccount']
    }

    $tradedJson = Get-JsonPropertyValueSubstring -Text $text -PropertyName 'tradedCards'
    if (-not [string]::IsNullOrWhiteSpace($tradedJson)) {
        $tradedTrim = $tradedJson.Trim()
        if ($tradedTrim -ne '{}' -and $tradedTrim -ne 'null') {
            $tradedObj = $serializer.DeserializeObject($tradedTrim)
            if ($null -ne $tradedObj) {
                $entry['tradedCards'] = $tradedObj
            }
        }
    }

    $sharedJson = Get-JsonPropertyValueSubstring -Text $text -PropertyName 'sharedCards'
    if (-not [string]::IsNullOrWhiteSpace($sharedJson)) {
        $sharedTrim = $sharedJson.Trim()
        if ($sharedTrim -ne '{}' -and $sharedTrim -ne 'null') {
            $sharedObj = $serializer.DeserializeObject($sharedTrim)
            if ($null -ne $sharedObj) {
                $entry['sharedCards'] = $sharedObj
            }
        }
    }

    return $entry
}

function Export-AccountCardMarksEntry {
    param([Parameter(Mandatory = $true)][hashtable]$Doc)

    Merge-AccountCardMarksFromMetadataToRoot -Doc $Doc | Out-Null
    $entry = @{
        deviceAccount = [string]$Doc['deviceAccount']
    }
    $traded = Get-AccountCardMarksTable -Doc $Doc -PropertyName 'tradedCards'
    if ($traded -and $traded.Count -gt 0) {
        $tradedOut = @{}
        foreach ($markEntry in $traded.GetEnumerator()) {
            $tradedOut[[string]$markEntry.Key] = ConvertTo-JsonHashtable $markEntry.Value
        }
        $entry['tradedCards'] = $tradedOut
    }
    $shared = Get-AccountCardMarksTable -Doc $Doc -PropertyName 'sharedCards'
    if ($shared -and $shared.Count -gt 0) {
        $sharedOut = @{}
        foreach ($markEntry in $shared.GetEnumerator()) {
            $sharedOut[[string]$markEntry.Key] = ConvertTo-JsonHashtable $markEntry.Value
        }
        $entry['sharedCards'] = $sharedOut
    }
    return $entry
}

function Build-AccountCardMarksPayload {
    $accountsDir = Join-Path $resolvedRoot "Accounts\Cards\accounts"
    $accounts = @()
    if (-not (Test-Path -LiteralPath $accountsDir -PathType Container)) {
        return @{
            ok = $true
            accountCount = 0
            accounts = @()
        }
    }

    $markPattern = '(?ms)"(?:tradedCards|sharedCards)"\s*:\s*\{\s*"'
    foreach ($file in Get-ChildItem -LiteralPath $accountsDir -Filter "*.json" -File | Sort-Object Name) {
        try {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            if (-not [regex]::IsMatch($text, $markPattern)) {
                continue
            }
            $loaded = Read-AccountJsonDocument -Path $file.FullName
            if (-not (Test-AccountJsonHasCardMarks -Doc $loaded.Doc)) {
                continue
            }
            $accounts += Export-AccountCardMarksEntryFromFile -Path $file.FullName -Doc $loaded.Doc
        } catch {
            continue
        }
    }

    return @{
        ok = $true
        accountCount = $accounts.Count
        accounts = $accounts
    }
}

function Invoke-GetAccountCardMarks {
    param([Parameter(Mandatory = $true)]$Context)

    $cardsDir = Join-Path $resolvedRoot "Accounts\Cards"
    $accountsDataDir = Join-Path $cardsDir "accounts"
    $collectionsDataDir = Join-Path $cardsDir "collections"
    $manifest = Get-DashboardAccountManifest -AccountsDataDir $accountsDataDir -CollectionsDataDir $collectionsDataDir
    $paths = Get-AccountCardMarksCachePaths
    $cacheDir = Split-Path $paths.Cache -Parent
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    if (Test-DashboardAccountsCache -CachePath $paths.Cache -MetaPath $paths.Meta -Manifest $manifest) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($paths.Cache)
            Write-BytesResponse -Context $Context -StatusCode 200 -Bytes $bytes -ContentType "application/json; charset=utf-8"
            return
        } catch {
            # Fall through and rebuild the cache.
        }
    }

    $payload = Build-AccountCardMarksPayload
    $serializer = Get-AccountJsonSerializer
    $json = $serializer.Serialize($payload)
    try {
        Write-Utf8File -Path $paths.Cache -Text $json
        $meta = @{
            signature = $manifest.Signature
            accountCount = $payload.accountCount
            generatedAt = (Get-Date).ToUniversalTime().ToString("o")
        } | ConvertTo-Json -Depth 4 -Compress
        Write-Utf8File -Path $paths.Meta -Text $meta
    } catch {
        # Cache writes are an optimization; the response should still succeed.
    }

    Write-TextResponse -Context $Context -StatusCode 200 -Body $json -ContentType "application/json; charset=utf-8"
}

function Invoke-DeductAccountShinedust {
    param([Parameter(Mandatory = $true)]$Context)

    $bodyText = Read-RequestBody -Context $Context
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Empty request body." }
        return
    }
    try { $payload = $bodyText | ConvertFrom-Json } catch {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid JSON body." }
        return
    }

    $deviceAccount = [string](Get-JsonPayloadProperty -Payload $payload -Name "deviceAccount")
    $deductRaw = Get-JsonPayloadProperty -Payload $payload -Name "deduct"
    $creditRaw = Get-JsonPayloadProperty -Payload $payload -Name "credit"
    if ([string]::IsNullOrWhiteSpace($deviceAccount)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Missing 'deviceAccount' field." }
        return
    }
    $deviceAccount = $deviceAccount.Trim()
    if (-not (Test-DeviceAccountId -Value $deviceAccount)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid deviceAccount." }
        return
    }

    try { $deduct = [int][Math]::Round([double]$deductRaw) } catch { $deduct = 0 }
    try { $credit = [int][Math]::Round([double]$creditRaw) } catch { $credit = 0 }
    if ($deduct -gt 0 -and $credit -gt 0) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{
            ok = $false
            error = "Specify either 'deduct' or 'credit', not both."
        }
        return
    }
    if ($deduct -le 0 -and $credit -le 0) {
        Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
            ok = $true
            skipped = $true
            deviceAccount = $deviceAccount
            deducted = 0
            credited = 0
        }
        return
    }

    $path = Get-AccountJsonPath -DeviceAccount $deviceAccount
    if (-not $path) {
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{
            ok = $false
            error = "Account JSON not found for deviceAccount '$deviceAccount'."
        }
        return
    }

    try {
        $text = [System.IO.File]::ReadAllText($path)
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = "Failed to read account JSON: $($_.Exception.Message)"
        }
        return
    }

    if ($text -notmatch '(?i)"deviceAccount"\s*:\s*"([^"]+)"') {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{
            ok = $false
            error = "Account JSON is missing deviceAccount."
        }
        return
    }
    $embeddedAccount = $Matches[1].Trim()
    if ($embeddedAccount -ne $deviceAccount) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{
            ok = $false
            error = "deviceAccount mismatch in account JSON."
        }
        return
    }

    $pattern = '(?ms)("shinedust"\s*:\s*\{\s*"value"\s*:\s*)(-?\d+)(\s*,\s*"lastUpdatedAt"\s*:\s*")([^"]*)(")'
    if ($text -notmatch $pattern) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{
            ok = $false
            error = "Account JSON has no shinedust metadata to update."
        }
        return
    }

    $previous = [int]$Matches[2]

    if ($credit -gt 0) {
        $actualCredit = $credit
        $newValue = $previous + $actualCredit
        $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
        $updatedText = [regex]::Replace($text, $pattern, {
            param($match)
            return $match.Groups[1].Value + $newValue + $match.Groups[3].Value + $stamp + $match.Groups[5].Value
        }, 1)
        if ($updatedText -eq $text) {
            Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
                ok = $false
                error = "Failed to update shinedust in account JSON."
            }
            return
        }

        $tmp = "$path.tmp"
        try {
            Write-Utf8File -Path $tmp -Text $updatedText
            Move-Item -LiteralPath $tmp -Destination $path -Force
        } catch {
            if (Test-Path -LiteralPath $tmp -PathType Leaf) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
            Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
                ok = $false
                error = "Failed to write account JSON: $($_.Exception.Message)"
            }
            return
        }

        Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
            ok = $true
            deviceAccount = $deviceAccount
            previous = $previous
            value = $newValue
            credited = $actualCredit
            lastUpdatedAt = $stamp
            path = $path
        }
        return
    }

    if ($previous -lt 0) {
        Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
            ok = $true
            skipped = $true
            reason = "unknown_balance"
            deviceAccount = $deviceAccount
            deducted = 0
            previous = $previous
        }
        return
    }

    $actualDeduct = [Math]::Min($deduct, $previous)
    $newValue = $previous - $actualDeduct
    $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $updatedText = [regex]::Replace($text, $pattern, {
        param($match)
        return $match.Groups[1].Value + $newValue + $match.Groups[3].Value + $stamp + $match.Groups[5].Value
    }, 1)
    if ($updatedText -eq $text) {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = "Failed to update shinedust in account JSON."
        }
        return
    }

    $tmp = "$path.tmp"
    try {
        Write-Utf8File -Path $tmp -Text $updatedText
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = "Failed to write account JSON: $($_.Exception.Message)"
        }
        return
    }

    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
        ok = $true
        deviceAccount = $deviceAccount
        previous = $previous
        value = $newValue
        deducted = $actualDeduct
        lastUpdatedAt = $stamp
        path = $path
    }
}

function Invoke-OpenAccountJson {
    param([Parameter(Mandatory = $true)]$Context)

    $bodyText = Read-RequestBody -Context $Context
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Empty request body." }
        return
    }
    try { $payload = $bodyText | ConvertFrom-Json } catch {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid JSON body." }
        return
    }

    $deviceAccount = [string](Get-JsonPayloadProperty -Payload $payload -Name "deviceAccount")
    if ([string]::IsNullOrWhiteSpace($deviceAccount)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Missing 'deviceAccount' field." }
        return
    }
    $deviceAccount = $deviceAccount.Trim()
    if (-not (Test-DeviceAccountId -Value $deviceAccount)) {
        Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid deviceAccount." }
        return
    }

    $path = Get-AccountJsonPath -DeviceAccount $deviceAccount
    if (-not $path) {
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{
            ok = $false
            error = "Account JSON not found for deviceAccount '$deviceAccount'."
        }
        return
    }

    try {
        Start-Process -FilePath $path | Out-Null
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = "Failed to open account JSON: $($_.Exception.Message)"
        }
        return
    }

    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
        ok = $true
        deviceAccount = $deviceAccount
        path = $path
    }
}

function Is-LocalRequest {
    param([Parameter(Mandatory = $true)]$Context)
    $remoteAddress = $Context.Request.RemoteEndPoint.Address.ToString()
    return $remoteAddress -eq "127.0.0.1" -or $remoteAddress -eq "::1"
}

function Resolve-RequestedPath {
    param([Parameter(Mandatory = $true)][string]$RawUrl)

    $requestPath = [Uri]::UnescapeDataString(($RawUrl -split "\?", 2)[0])
    if ([string]::IsNullOrWhiteSpace($requestPath) -or $requestPath -eq "/") {
        $requestPath = "/$defaultDocument"
    }

    $relativePath = $requestPath.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $relativePath))
    if (-not $candidate.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $candidate
}

$script:CardImageBaseUrl = "https://leanny.github.io/pocket_tcg_resources/img/S/US"
$script:CardImageCacheDir = Join-Path $resolvedRoot "Helper\CardImageCache"
$script:CardImagePrefetchPowerShell = $null
$script:CardImagePrefetchHandle = $null
$script:CardImagePrefetch = [hashtable]::Synchronized(@{
    Running = $false
    CancelRequested = $false
    Total = 0
    Done = 0
    Downloaded = 0
    Skipped = 0
    Failed = 0
    Current = ""
    StartedAt = $null
    FinishedAt = $null
    LastError = ""
})

function Get-SafeIllustrationFileName {
    param([Parameter(Mandatory = $true)][string]$IllustrationId)
    $bad = [char[]]@('\', '/', ':', '<', '>', '"', '*', '?', '|')
    $chars = $IllustrationId.ToCharArray() | ForEach-Object {
        if ($bad -contains $_) { '_' } else { $_ }
    }
    return -join $chars
}

function Test-ValidCachedCardImage {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        return ([System.IO.FileInfo]$Path).Length -gt 1000
    } catch {
        return $false
    }
}

function Get-UniqueIllustrationIdsFromCardmap {
    $cardmapPath = Join-Path $resolvedRoot "Helper\cardmap.json"
    if (-not (Test-Path -LiteralPath $cardmapPath -PathType Leaf)) {
        throw "Helper\cardmap.json was not found."
    }
    try {
        $raw = [System.IO.File]::ReadAllText($cardmapPath)
        $map = $raw | ConvertFrom-Json
    } catch {
        throw "Could not parse Helper\cardmap.json: $($_.Exception.Message)"
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($prop in $map.PSObject.Properties) {
        $ill = $prop.Value.IllustrationID
        if (-not [string]::IsNullOrWhiteSpace($ill)) {
            [void]$seen.Add([string]$ill)
        }
    }
    return @($seen)
}

function Get-CardImagePrefetchSnapshot {
    return @{
        ok = $true
        running = [bool]$script:CardImagePrefetch.Running
        cacheDir = "Helper/CardImageCache"
        total = [int]$script:CardImagePrefetch.Total
        done = [int]$script:CardImagePrefetch.Done
        downloaded = [int]$script:CardImagePrefetch.Downloaded
        skipped = [int]$script:CardImagePrefetch.Skipped
        failed = [int]$script:CardImagePrefetch.Failed
        current = [string]$script:CardImagePrefetch.Current
        startedAt = $script:CardImagePrefetch.StartedAt
        finishedAt = $script:CardImagePrefetch.FinishedAt
        lastError = [string]$script:CardImagePrefetch.LastError
    }
}

$script:CardImagePrefetchWorkerScript = {
    param(
        [string]$Root,
        [hashtable]$State,
        [string[]]$IllustrationIds,
        [int]$Concurrency,
        [bool]$Force,
        [string]$BaseUrl
    )

    function Get-SafeIllustrationFileNameLocal {
        param([string]$IllustrationId)
        $bad = [char[]]@('\', '/', ':', '<', '>', '"', '*', '?', '|')
        $chars = $IllustrationId.ToCharArray() | ForEach-Object {
            if ($bad -contains $_) { '_' } else { $_ }
        }
        return -join $chars
    }

    function Test-ValidCachedCardImageLocal {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        try { return ([System.IO.FileInfo]$Path).Length -gt 1000 } catch { return $false }
    }

    function Sync-CardImagePrefetchProgress {
        param(
            [hashtable]$ProgressState,
            [int]$Done,
            [int]$Downloaded,
            [int]$Skipped,
            [int]$Failed,
            [string]$Current = ""
        )
        $ProgressState.Done = $Done
        $ProgressState.Downloaded = $Downloaded
        $ProgressState.Skipped = $Skipped
        $ProgressState.Failed = $Failed
        if ($Current) { $ProgressState.Current = $Current }
    }

    if ($Concurrency -lt 1) { $Concurrency = 1 }
    if ($Concurrency -gt 32) { $Concurrency = 32 }

    $cacheDir = Join-Path $Root "Helper\CardImageCache"
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

    $toDownload = New-Object System.Collections.Generic.List[object]
    $skippedCount = 0
    $downloadedCount = 0
    $failedCount = 0

    try {
        foreach ($illId in $IllustrationIds) {
            if ([bool]$State.CancelRequested) { break }

            $safe = Get-SafeIllustrationFileNameLocal -IllustrationId $illId
            $dest = Join-Path $cacheDir "$safe.png"

            if (-not $Force -and (Test-ValidCachedCardImageLocal -Path $dest)) {
                $skippedCount++
                continue
            }

            $toDownload.Add([pscustomobject]@{
                IllustrationId = $illId
                Url = "$BaseUrl/$illId.png"
                Destination = $dest
            }) | Out-Null
        }

        $doneCount = $skippedCount
        $downloadedCount = 0
        $failedCount = 0
        Sync-CardImagePrefetchProgress -ProgressState $State -Done $doneCount -Downloaded 0 -Skipped $skippedCount -Failed 0

        if ($toDownload.Count -gt 0 -and -not [bool]$State.CancelRequested) {
            Add-Type -AssemblyName System.Net.Http
            [System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max(
                $Concurrency,
                [System.Net.ServicePointManager]::DefaultConnectionLimit
            )

            $handler = New-Object System.Net.Http.HttpClientHandler
            $handler.MaxConnectionsPerServer = $Concurrency
            $httpClient = New-Object System.Net.Http.HttpClient($handler)
            $httpClient.Timeout = [TimeSpan]::FromSeconds(120)
            $null = $httpClient.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "PTCGPB-CardDashboard/1.0")

            try {
                for ($offset = 0; $offset -lt $toDownload.Count; $offset += $Concurrency) {
                    if ([bool]$State.CancelRequested) { break }

                    $batch = @(
                        for ($i = $offset; $i -lt [Math]::Min($offset + $Concurrency, $toDownload.Count); $i++) {
                            $toDownload[$i]
                        }
                    )

                    $tasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task[byte[]]]
                    foreach ($item in $batch) {
                        $tasks.Add($httpClient.GetByteArrayAsync($item.Url)) | Out-Null
                    }

                    try {
                        [void][System.Threading.Tasks.Task]::WaitAll($tasks.ToArray())
                    } catch {
                        # Individual task failures are handled per item below.
                    }

                    for ($ti = 0; $ti -lt $batch.Count; $ti++) {
                        $item = $batch[$ti]
                        $task = $tasks[$ti]
                        $ok = $false
                        try {
                            if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                                $bytes = $task.Result
                                if ($bytes.Length -gt 1000) {
                                    [System.IO.File]::WriteAllBytes($item.Destination, $bytes)
                                    $ok = $true
                                }
                            }
                        } catch {
                            $ok = $false
                        }

                        $doneCount++
                        if ($ok) { $downloadedCount++ } else { $failedCount++ }

                        if (($doneCount % 25) -eq 0) {
                            Sync-CardImagePrefetchProgress `
                                -ProgressState $State `
                                -Done $doneCount `
                                -Downloaded $downloadedCount `
                                -Skipped $skippedCount `
                                -Failed $failedCount `
                                -Current $item.IllustrationId
                        }
                    }
                }
            } finally {
                $httpClient.Dispose()
                $handler.Dispose()
            }
        }

        Sync-CardImagePrefetchProgress `
            -ProgressState $State `
            -Done ($skippedCount + $downloadedCount + $failedCount) `
            -Downloaded $downloadedCount `
            -Skipped $skippedCount `
            -Failed $failedCount
    } catch {
        $State.LastError = $_.Exception.Message
        Sync-CardImagePrefetchProgress `
            -ProgressState $State `
            -Done ($skippedCount + $downloadedCount + $failedCount) `
            -Downloaded $downloadedCount `
            -Skipped $skippedCount `
            -Failed $failedCount
    } finally {
        $State.Running = $false
        $State.Current = ""
        $State.FinishedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Start-CardImagePrefetchJob {
    param(
        [bool]$Force = $false,
        [int]$Concurrency = 20
    )

    if ([bool]$script:CardImagePrefetch.Running) {
        return $false
    }

    $script:CardImagePrefetch.Running = $true
    $script:CardImagePrefetch.CancelRequested = $false
    $script:CardImagePrefetch.Total = 0
    $script:CardImagePrefetch.Done = 0
    $script:CardImagePrefetch.Downloaded = 0
    $script:CardImagePrefetch.Skipped = 0
    $script:CardImagePrefetch.Failed = 0
    $script:CardImagePrefetch.Current = ""
    $script:CardImagePrefetch.StartedAt = (Get-Date).ToUniversalTime().ToString("o")
    $script:CardImagePrefetch.FinishedAt = $null
    $script:CardImagePrefetch.LastError = ""

    try {
        $ids = Get-UniqueIllustrationIdsFromCardmap
    } catch {
        $script:CardImagePrefetch.Running = $false
        $script:CardImagePrefetch.LastError = $_.Exception.Message
        $script:CardImagePrefetch.FinishedAt = (Get-Date).ToUniversalTime().ToString("o")
        throw
    }

    $script:CardImagePrefetch.Total = $ids.Count

    if ($script:CardImagePrefetchPowerShell) {
        try {
            if ($script:CardImagePrefetchHandle -and $script:CardImagePrefetchHandle.IsCompleted) {
                $script:CardImagePrefetchPowerShell.EndInvoke($script:CardImagePrefetchHandle) | Out-Null
                $script:CardImagePrefetchPowerShell.Dispose()
                $script:CardImagePrefetchPowerShell = $null
                $script:CardImagePrefetchHandle = $null
            }
        } catch {
            $script:CardImagePrefetchPowerShell = $null
            $script:CardImagePrefetchHandle = $null
        }
    }

    $script:CardImagePrefetchPowerShell = [powershell]::Create()
    [void]$script:CardImagePrefetchPowerShell.AddScript($script:CardImagePrefetchWorkerScript)
    [void]$script:CardImagePrefetchPowerShell.AddArgument($resolvedRoot)
    [void]$script:CardImagePrefetchPowerShell.AddArgument($script:CardImagePrefetch)
    [void]$script:CardImagePrefetchPowerShell.AddArgument($ids)
    [void]$script:CardImagePrefetchPowerShell.AddArgument($Concurrency)
    [void]$script:CardImagePrefetchPowerShell.AddArgument($Force)
    [void]$script:CardImagePrefetchPowerShell.AddArgument($script:CardImageBaseUrl)
    $script:CardImagePrefetchHandle = $script:CardImagePrefetchPowerShell.BeginInvoke()
    return $true
}

function Invoke-GetCardImagePrefetchStatus {
    param([Parameter(Mandatory = $true)]$Context)
    Write-JsonResponse -Context $Context -StatusCode 200 -Payload (Get-CardImagePrefetchSnapshot)
}

function Invoke-StartCardImagePrefetch {
    param([Parameter(Mandatory = $true)]$Context)

    $force = $false
    $concurrency = 20
    $bodyText = Read-RequestBody -Context $Context
    if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
        try {
            $payload = $bodyText | ConvertFrom-Json
        } catch {
            Write-JsonResponse -Context $Context -StatusCode 400 -Payload @{ ok = $false; error = "Invalid JSON body." }
            return
        }
        $forceValue = Get-JsonPayloadProperty -Payload $payload -Name "force"
        if ($null -ne $forceValue) {
            try { $force = [bool]$forceValue } catch { $force = $false }
        }
        $concurrencyValue = Get-JsonPayloadProperty -Payload $payload -Name "concurrency"
        if ($null -ne $concurrencyValue) {
            try { $concurrency = [int]$concurrencyValue } catch { $concurrency = 20 }
        }
        $modeValue = Get-JsonPayloadProperty -Payload $payload -Name "mode"
        if ($null -ne $modeValue -and [string]$modeValue -eq "all") {
            $force = $true
        }
    }

    if ([bool]$script:CardImagePrefetch.Running) {
        Write-JsonResponse -Context $Context -StatusCode 409 -Payload @{
            ok = $false
            error = "Card image download is already running."
            status = (Get-CardImagePrefetchSnapshot)
        }
        return
    }

    try {
        if (-not (Start-CardImagePrefetchJob -Force:$force -Concurrency $concurrency)) {
            Write-JsonResponse -Context $Context -StatusCode 409 -Payload @{
                ok = $false
                error = "Card image download is already running."
            }
            return
        }
    } catch {
        Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
            ok = $false
            error = $_.Exception.Message
        }
        return
    }

    $snapshot = Get-CardImagePrefetchSnapshot
    $snapshot.ok = $true
    Write-JsonResponse -Context $Context -StatusCode 202 -Payload $snapshot
}

function Invoke-StopCardImagePrefetch {
    param([Parameter(Mandatory = $true)]$Context)
    $script:CardImagePrefetch.CancelRequested = $true
    $snapshot = Get-CardImagePrefetchSnapshot
    $snapshot.ok = $true
    Write-JsonResponse -Context $Context -StatusCode 200 -Payload $snapshot
}

if ($env:PTCGP_CARD_DASHBOARD_NO_LISTEN -eq '1') {
    return
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

Write-Host "Serving $resolvedRoot at http://localhost:$Port"

try {
    $shouldStop = $false
    while (-not $shouldStop) {
        $iar = $listener.BeginGetContext($null, $null)
        while (-not $iar.AsyncWaitHandle.WaitOne(200)) {
            if ($shutdownAt -and (Get-Date) -ge $shutdownAt) {
                $shouldStop = $true
                break
            }
        }

        if ($shouldStop) {
            break
        }

        $context = $listener.EndGetContext($iar)
        $request = $context.Request

        if ($request.Url.AbsolutePath -eq "/__dashboard/ping" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-TextResponse -Context $context -StatusCode 403 -Body "Local requests only"
                continue
            }
            $shutdownAt = $null
            $context.Response.StatusCode = 204
            $context.Response.OutputStream.Close()
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/shutdown" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-TextResponse -Context $context -StatusCode 403 -Body "Local requests only"
                continue
            }
            $shutdownAt = (Get-Date).AddSeconds(3)
            Write-TextResponse -Context $context -StatusCode 202 -Body "shutdown scheduled"
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/settings-friend-id" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            $accountsDir = Join-Path $resolvedRoot "Accounts"
            $iniPath = Join-Path $accountsDir "InjectAccount.ini"
            $friendSettings = Get-InjectFriendSettingsFromIni -IniPath $iniPath
            Write-JsonResponse -Context $context -StatusCode 200 -Payload @{
                ok = $true
                favoriteFriendIds = $friendSettings.favoriteFriendIds
                favoriteFriendLabels = $friendSettings.favoriteFriendLabels
                injectSelectedFriendIds = $friendSettings.injectSelectedFriendIds
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/inject" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-InjectAccount -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/accounts-data" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-LoadAccountData -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/accounts-summary" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-LoadAccountsSummary -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/dashboard-rows" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-LoadDashboardRows -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/wishlist" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-GetWishlist -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/wishlist" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-SaveWishlist -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/account-shinedust/deduct" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-DeductAccountShinedust -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/account-json/open" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-OpenAccountJson -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if (
            ($request.Url.AbsolutePath -eq "/__dashboard/account-trade-marks" -or $request.Url.AbsolutePath -eq "/__dashboard/account-card-marks") -and
            $request.HttpMethod -eq "GET"
        ) {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-GetAccountCardMarks -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if (
            ($request.Url.AbsolutePath -eq "/__dashboard/account-trade-marks" -or $request.Url.AbsolutePath -eq "/__dashboard/account-card-marks") -and
            $request.HttpMethod -eq "POST"
        ) {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-SetAccountCardMarks -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/instances" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-ListInstances -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/launch-instance" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-LaunchInstance -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/card-images/status" -and $request.HttpMethod -eq "GET") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-GetCardImagePrefetchStatus -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/card-images/prefetch" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-StartCardImagePrefetch -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/__dashboard/card-images/prefetch/stop" -and $request.HttpMethod -eq "POST") {
            if (-not (Is-LocalRequest -Context $context)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Payload @{ ok = $false; error = "Local requests only" }
                continue
            }
            try {
                Invoke-StopCardImagePrefetch -Context $context
            } catch {
                Write-JsonResponse -Context $context -StatusCode 500 -Payload @{ ok = $false; error = "Unexpected server error: $($_.Exception.Message)" }
            }
            continue
        }

        if ($request.HttpMethod -ne "GET") {
            Write-TextResponse -Context $context -StatusCode 405 -Body "Method not allowed"
            continue
        }

        $resolved = Resolve-RequestedPath -RawUrl $request.RawUrl
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            Write-TextResponse -Context $context -StatusCode 404 -Body "Not found"
            continue
        }

        try {
            $bytes = [System.IO.File]::ReadAllBytes($resolved)
            $extension = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
            $contentType = if ($mimeMap.ContainsKey($extension)) { $mimeMap[$extension] } else { "application/octet-stream" }

            $response = $context.Response
            $response.StatusCode = 200
            $response.ContentType = $contentType
            if ($extension -eq ".html" -or $extension -eq ".htm") {
                $response.Headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
                $response.Headers["Pragma"] = "no-cache"
            }
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $response.OutputStream.Close()
        }
        catch {
            Write-TextResponse -Context $context -StatusCode 500 -Body "Server error"
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
