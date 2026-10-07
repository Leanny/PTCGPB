<#
.SYNOPSIS
    Formats AutoHotkey v1 scripts: indentation and trailing whitespace.

.DESCRIPTION
    Re-indents AutoHotkey v1 code by its block structure with 4 spaces per level:
    braces, braceless if/else/loop/for/while/try bodies, label and hotkey bodies
    (up to their top-level return), #If sections and continuation lines.

    Only whitespace at the start and end of lines changes. Every file is checked
    for this before it is written. Block comments and continuation sections
    ( ... ) are kept exactly as they are, because their whitespace can be part
    of a string.

    The block structure follows AHK v1's rules instead of counting braces: a
    block is only closed by a "}" at the start of a line and only opened by a
    lone "{" or a "{" ending an if/else/loop/for/while/try/catch/finally/switch,
    function, class or property line. Braces inside expressions and commands,
    like {x: 1} or Send {Enter}, never change the indentation.

    Files listed in Helper\ahkfmt-exclude.list (third-party libraries) are skipped.

.PARAMETER Path
    Files or folders to format. Default: all .ahk files tracked by git.

.PARAMETER Check
    Do not write anything. Exit code 1 if a file is not formatted.

.PARAMETER Staged
    Use the .ahk files staged for commit. With -Check, the staged content is
    checked (used by Helper\hooks\pre-commit).

.PARAMETER Test
    Run the formatter's own tests in Helper\ahkfmt-tests.

.PARAMETER Stdin
    Format the text from standard input and write it to standard output, for
    editor integration (.vscode/settings.json). Pass the file name as Path so the
    exclude list applies. Code that cannot be formatted, for example while a
    block is still being typed, is returned unchanged with a note on stderr.

.EXAMPLE
    .\Helper\Format-Ahk.ps1                  # format all tracked .ahk files
    .\Helper\Format-Ahk.ps1 Scripts\1.ahk    # format one file
    .\Helper\Format-Ahk.ps1 -Check           # report files that need formatting
    .\Helper\Format-Ahk.ps1 -Staged          # format the files staged for commit

.NOTES
    Exit codes: 0 = ok, 1 = files need formatting (-Check) or tests failed,
    2 = a file could not be formatted (unbalanced braces).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path,
    [switch]$Check,
    [switch]$Staged,
    [switch]$Test,
    [switch]$Stdin
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ExcludeFile = Join-Path $PSScriptRoot 'ahkfmt-exclude.list'
$TestDir = Join-Path $PSScriptRoot 'ahkfmt-tests'
$IndentUnit = '    '

# Analysis only works on the code part of a line: strings emptied, comment removed.
$ReString = [regex]'"(?:[^"]|"")*"'
$ReComment = [regex]'(?:^|[ \t]);.*$'
# v1 merges a line that starts with "," or an operator (except ++ and --) into the previous one.
$ReContinuation = [regex]'^(?:,|&&|\|\||(?:and|or)\b|\?|\.(?!\.)|:(?!:)|\+(?!\+)|-(?!-)|\*|/|<|>|=|!=|~=|&|\||\^)'
$ReHotkey = [regex]'^[^\s,;]\S*?(?:\s+&\s+\S+?)?(?:\s+up)?::(.*)$'
$ReLabel = [regex]'^(?!default:)[^\s,;:"''(){}\[\]%=]+:$'
$ReIfDirective = [regex]'(?i)^#If(?:WinActive|WinNotActive|WinExist|WinNotExist)?(?![\w])(.*)$'
$ReKeyword = [regex]'(?i)^(if|else|loop|for|while|try|catch|finally|switch|until)(?![\w#@$])(?!\s*(?::=|\.=|\+=|-=|=))\s*(.*)$'
$ReLegacyIf = [regex]'(?i)^If(?:Not)?(?:Equal|Exist|InString|Greater|GreaterOrEqual|Less|LessOrEqual|WinActive|WinExist|WinNotActive|WinNotExist|MsgBox)\b'
$ReClass = [regex]'(?i)^class\s+[\w.]+'
$ReFuncDef = [regex]'(?i)^(?!(?:if|while|for|loop|switch|catch|until|return)\()[\w#@$]+\(.*\)\s*\{?$'
$ReCase = [regex]'(?i)^(?:case\b.*|default\s*):$'
$ReReturn = [regex]'(?i)^return\b'
$ReTrailingEscape = [regex]'`\s+$'

# ---------------------------------------------------------------- formatting

# Stack entries: T = B (brace block), S (pending single-statement body),
# C (case body), L (label/hotkey body), D (#If section); K = kind; Line = 1-based.
function New-Entry([string]$T, [string]$K, [int]$Line) {
    return @{ T = $T; K = $K; Line = $Line }
}

function Get-Top($stack) {
    if ($stack.Count -eq 0) { return $null }
    return $stack[$stack.Count - 1]
}

function Remove-Top($stack) {
    $top = $stack[$stack.Count - 1]
    $stack.RemoveAt($stack.Count - 1)
    return $top
}

# True when no block, pending body or case is open (labels, hotkeys, functions live here).
function Test-TopLevel($stack) {
    foreach ($e in $stack) { if ($e.T -eq 'B' -or $e.T -eq 'S' -or $e.T -eq 'C') { return $false } }
    return $true
}

# Closes one "{" block: drops pending bodies inside it and returns the block entry.
function Close-Block($stack, [int]$lineNo) {
    while ($stack.Count -gt 0) {
        $top = Get-Top $stack
        if ($top.T -eq 'L' -or $top.T -eq 'D') { break }
        $null = Remove-Top $stack
        if ($top.T -eq 'B') { return $top }
    }
    throw "Unexpected '}' at line $lineNo"
}

# A statement ended: pending single-statement bodies are complete. They go into
# $chain (outer to inner) so a following else/catch/finally/until can find its partner.
function Complete-Statement($stack, $chain) {
    $popped = New-Object System.Collections.Generic.List[hashtable]
    while ($stack.Count -gt 0 -and (Get-Top $stack).T -eq 'S') { $popped.Add((Remove-Top $stack)) }
    for ($k = $popped.Count - 1; $k -ge 0; $k--) { $chain.Add($popped[$k]) }
}

function Get-HeaderKind([string]$codeText) {
    $m = $ReKeyword.Match($codeText)
    if ($m.Success) {
        $kw = $m.Groups[1].Value.ToLowerInvariant()
        if ($kw -in 'if', 'loop', 'for', 'while', 'try', 'switch') { return $kw }
    }
    if ($ReLegacyIf.IsMatch($codeText)) { return 'if' }
    return $null
}

# Opens the body of a header: a block when the logical line ends with "{",
# otherwise a pending single-statement body. try may have its statement inline.
function Open-Body($stack, $chain, [string]$kind, [string]$rest, [bool]$opensBlock, [int]$lineNo) {
    if ($opensBlock) {
        $stack.Add((New-Entry 'B' $kind $lineNo))
        return $false
    }
    if (($kind -eq 'try' -or $kind -eq 'else' -or $kind -eq 'finally') -and $rest -ne '') {
        Complete-Statement $stack $chain
        return $false
    }
    $stack.Add((New-Entry 'S' $kind $lineNo))
    return $true
}

function Get-LineBody([string]$line) {
    $body = $line.TrimStart()
    # A backtick before trailing whitespace escapes it; keep that whitespace.
    if ($ReTrailingEscape.IsMatch($body)) { return $body }
    return $body.TrimEnd()
}

# Returns @{ Lines = formatted lines; Roles = role per line }.
function Format-AhkLines([string[]]$Lines) {
    $n = $Lines.Count
    $trim = New-Object string[] $n
    $code = New-Object string[] $n
    $role = New-Object string[] $n

    # Pass 1: role of every physical line.
    $inBlockComment = $false
    $inSection = $false
    for ($i = 0; $i -lt $n; $i++) {
        $t = $Lines[$i].Trim()
        $trim[$i] = $t
        if ($inBlockComment) {
            $role[$i] = 'verbatim'
            if ($t.StartsWith('*/') -or $t.EndsWith('*/')) { $inBlockComment = $false }
            continue
        }
        if ($inSection) {
            $role[$i] = 'section'
            if ($t.StartsWith(')')) { $inSection = $false }
            continue
        }
        if ($t.Length -eq 0) { $role[$i] = 'blank'; continue }
        if ($t.StartsWith('/*')) {
            $role[$i] = 'verbatim'
            if (-not ($t.Length -ge 4 -and $t.EndsWith('*/'))) { $inBlockComment = $true }
            continue
        }
        if ($t.StartsWith(';')) { $role[$i] = 'comment'; continue }
        if ($t.StartsWith('(') -and -not $t.Contains(')')) {
            $role[$i] = 'section'
            $inSection = $true
            continue
        }
        $c = $ReComment.Replace($ReString.Replace($t, '""'), '').Trim()
        $code[$i] = $c
        if ($ReHotkey.IsMatch($c)) { $role[$i] = 'stmt' }
        elseif ($ReContinuation.IsMatch($c)) { $role[$i] = 'cont' }
        else { $role[$i] = 'stmt' }
    }

    # Pass 2: walk logical lines and track the block structure.
    $out = New-Object string[] $n
    $stack = New-Object System.Collections.Generic.List[hashtable]
    $chain = New-Object System.Collections.Generic.List[hashtable]
    $logical = 0
    $pendingBodyAt = -10      # logical line that opened a pending body (for Allman "{")
    $pendingDefAt = -10       # logical line of a class/function header without "{"
    $pendingDefKind = ''

    $i = 0
    while ($i -lt $n) {
        $r = $role[$i]
        if ($r -eq 'blank') { $out[$i] = ''; $i++; continue }
        if ($r -eq 'verbatim' -or $r -eq 'section') { $out[$i] = $Lines[$i]; $i++; continue }
        if ($r -eq 'comment') { $out[$i] = ($IndentUnit * $stack.Count) + (Get-LineBody $Lines[$i]); $i++; continue }

        # Extent of the logical line: continuation lines, continuation sections and
        # the comments between them.
        $end = $i
        $j = $i + 1
        while ($j -lt $n) {
            $rj = $role[$j]
            if ($rj -eq 'cont' -or $rj -eq 'section') { $end = $j; $j++; continue }
            if ($rj -eq 'comment' -or $rj -eq 'blank') {
                $k = $j
                while ($k -lt $n -and ($role[$k] -eq 'comment' -or $role[$k] -eq 'blank')) { $k++ }
                if ($k -lt $n -and ($role[$k] -eq 'cont' -or $role[$k] -eq 'section')) { $end = $k; $j = $k + 1; continue }
            }
            break
        }
        $last = $code[$i]
        $full = $code[$i]
        for ($k = $i + 1; $k -le $end; $k++) {
            if ($role[$k] -eq 'cont') { $last = $code[$k]; $full += ' ' + $code[$k] }
        }
        $opensBlock = $last.EndsWith('{')
        $logical++
        $lineNo = $i + 1

        $c = $code[$i]
        $indent = -1

        # Leading "}" close blocks.
        $closers = 0
        while ($c.StartsWith('}')) { $c = $c.Substring(1).TrimStart(); $closers++ }
        if ($closers -gt 0) {
            $closed = $null
            for ($k = 0; $k -lt $closers; $k++) { $closed = Close-Block $stack $lineNo }
            $indent = $stack.Count
            $chain.Clear()
            Complete-Statement $stack $chain
            $chain.Add($closed)
        }

        $m = $ReKeyword.Match($c)
        $kw = ''
        $rest = ''
        if ($m.Success) { $kw = $m.Groups[1].Value.ToLowerInvariant(); $rest = $m.Groups[2].Value.Trim() }
        $top = Get-Top $stack
        $topLevel = Test-TopLevel $stack

        if ($c -eq '') {
            # only closing braces
        }
        elseif ($kw -in 'else', 'catch', 'finally', 'until') {
            # Attach to the statement AHK pairs it with and reopen the bodies around it.
            switch ($kw) {
                'else' { $partners = @('if') }
                'catch' { $partners = @('try') }
                'finally' { $partners = @('try', 'catch') }
                'until' { $partners = @('loop') }
            }
            $pos = -1
            for ($k = $chain.Count - 1; $k -ge 0; $k--) {
                if ($partners -contains $chain[$k].K) { $pos = $k; break }
            }
            for ($k = 0; $k -lt $pos; $k++) { $stack.Add($chain[$k]) }
            if ($indent -lt 0) { $indent = $stack.Count }
            $chain.Clear()

            if ($kw -eq 'until') {
                Complete-Statement $stack $chain
            }
            elseif ($kw -eq 'catch') {
                if (Open-Body $stack $chain 'catch' '' $opensBlock $lineNo) { $pendingBodyAt = $logical }
            }
            elseif ($rest -eq '' -or $rest -eq '{') {
                if (Open-Body $stack $chain $kw '' $opensBlock $lineNo) { $pendingBodyAt = $logical }
            }
            else {
                # "else if ...", "else Loop ...", or an inline statement.
                $kind = Get-HeaderKind $rest
                if ($kind) {
                    $m2 = $ReKeyword.Match($rest)
                    $rest2 = ''
                    if ($m2.Success) { $rest2 = $m2.Groups[2].Value.Trim() }
                    if ($kind -ne 'try') { $rest2 = '' }
                    if ($rest2 -eq '{') { $rest2 = '' }
                    if (Open-Body $stack $chain $kind $rest2 $opensBlock $lineNo) { $pendingBodyAt = $logical }
                }
                else {
                    Complete-Statement $stack $chain
                }
            }
        }
        elseif ($topLevel -and $ReLabel.IsMatch($c)) {
            if ($top -and $top.T -eq 'L') { $null = Remove-Top $stack }
            $indent = $stack.Count
            $stack.Add((New-Entry 'L' 'label' $lineNo))
            $chain.Clear()
        }
        elseif ($ReLabel.IsMatch($c)) {
            # Label inside a function: no extra indentation for the code after it.
            $indent = $stack.Count
            $chain.Clear()
        }
        elseif ($topLevel -and $ReHotkey.IsMatch($c)) {
            if ($top -and $top.T -eq 'L') { $null = Remove-Top $stack }
            $indent = $stack.Count
            if ($ReHotkey.Match($c).Groups[1].Value.Trim() -eq '') {
                $stack.Add((New-Entry 'L' 'hotkey' $lineNo))
            }
            $chain.Clear()
        }
        elseif ($topLevel -and $ReIfDirective.IsMatch($c)) {
            if ($top -and $top.T -eq 'L') { $null = Remove-Top $stack }
            $top = Get-Top $stack
            if ($top -and $top.T -eq 'D') { $null = Remove-Top $stack }
            $indent = $stack.Count
            if ($ReIfDirective.Match($c).Groups[1].Value.Trim() -ne '') {
                $stack.Add((New-Entry 'D' 'if' $lineNo))
            }
            $chain.Clear()
        }
        elseif ($top -and $top.T -eq 'L' -and $ReReturn.IsMatch($c)) {
            # The return that ends a label or hotkey body.
            $null = Remove-Top $stack
            $indent = $stack.Count
            $chain.Clear()
        }
        elseif (($topLevel -or ($top -and $top.T -eq 'B' -and $top.K -eq 'class')) -and $ReClass.IsMatch($c)) {
            if ($top -and $top.T -eq 'L') { $null = Remove-Top $stack }
            $indent = $stack.Count
            if ($opensBlock) { $stack.Add((New-Entry 'B' 'class' $lineNo)) }
            else { $pendingDefAt = $logical; $pendingDefKind = 'class' }
            $chain.Clear()
        }
        elseif (($topLevel -or ($top -and $top.T -eq 'B' -and $top.K -eq 'class')) -and $ReFuncDef.IsMatch($full) -and
            ($opensBlock -or (Test-NextCodeIsBrace $role $code ($end + 1)))) {
            if ($top -and $top.T -eq 'L') { $null = Remove-Top $stack }
            $indent = $stack.Count
            if ($opensBlock) { $stack.Add((New-Entry 'B' 'func' $lineNo)) }
            else { $pendingDefAt = $logical; $pendingDefKind = 'func' }
            $chain.Clear()
        }
        elseif ($kind = Get-HeaderKind $c) {
            if ($indent -lt 0) { $indent = $stack.Count }
            $chain.Clear()
            $inline = ''
            if ($kind -eq 'try' -and $rest -ne '{') { $inline = $rest }
            if (Open-Body $stack $chain $kind $inline $opensBlock $lineNo) { $pendingBodyAt = $logical }
        }
        elseif ($c -eq '{') {
            if ($top -and $top.T -eq 'S' -and $pendingBodyAt -eq $logical - 1) {
                # Allman style: the brace belongs to the header above it.
                $indent = $stack.Count - 1
                $top.T = 'B'
            }
            else {
                $indent = $stack.Count
                $kind = 'block'
                if ($pendingDefAt -eq $logical - 1) { $kind = $pendingDefKind }
                $stack.Add((New-Entry 'B' $kind $lineNo))
            }
            $chain.Clear()
        }
        elseif ($ReCase.IsMatch($c) -and $top -and ($top.T -eq 'C' -or ($top.T -eq 'B' -and $top.K -eq 'switch'))) {
            if ($top.T -eq 'C') { $null = Remove-Top $stack }
            $indent = $stack.Count
            $stack.Add((New-Entry 'C' 'case' $lineNo))
            $chain.Clear()
        }
        elseif ($opensBlock -and $top -and $top.T -eq 'B' -and ($top.K -eq 'class' -or $top.K -eq 'prop')) {
            # Property definition or its get/set block.
            $indent = $stack.Count
            $stack.Add((New-Entry 'B' 'prop' $lineNo))
            $chain.Clear()
        }
        else {
            if ($indent -lt 0) { $indent = $stack.Count; $chain.Clear() }
            Complete-Statement $stack $chain
        }

        # Write the logical line.
        $out[$i] = ($IndentUnit * $indent) + (Get-LineBody $Lines[$i])
        $contPad = $IndentUnit * ($indent + 1)
        for ($k = $i + 1; $k -le $end; $k++) {
            switch ($role[$k]) {
                'blank' { $out[$k] = '' }
                'section' { $out[$k] = $Lines[$k] }
                default { $out[$k] = $contPad + (Get-LineBody $Lines[$k]) }
            }
        }
        $i = $end + 1
    }

    Complete-Statement $stack $chain
    foreach ($e in $stack) {
        if ($e.T -eq 'B') { throw "Missing '}' for the block opened at line $($e.Line)" }
    }

    # Safety net: nothing but surrounding whitespace may change.
    for ($k = 0; $k -lt $n; $k++) {
        if ($out[$k].Trim() -cne $Lines[$k].Trim()) { throw "Internal error: line $($k + 1) would change beyond whitespace" }
    }
    return @{ Lines = $out; Roles = $role }
}

function Test-NextCodeIsBrace($role, $code, [int]$from) {
    for ($k = $from; $k -lt $role.Count; $k++) {
        if ($role[$k] -eq 'blank' -or $role[$k] -eq 'comment') { continue }
        return ($role[$k] -eq 'stmt' -and $code[$k] -eq '{')
    }
    return $false
}

# ---------------------------------------------------------------- files

function Read-AhkText([byte[]]$bytes) {
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $offset = 0
    if ($bom) { $offset = 3 }
    $text = (New-Object System.Text.UTF8Encoding $false).GetString($bytes, $offset, $bytes.Length - $offset)
    $crlf = $text.Contains("`r`n")
    $text = $text.Replace("`r`n", "`n")
    if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
    return @{ Bom = $bom; Crlf = $crlf; Lines = $text.Split("`n") }
}

function Get-AhkBytes($file, [string[]]$lines) {
    $newline = "`n"
    if ($file.Crlf) { $newline = "`r`n" }
    $text = [string]::Join($newline, $lines) + $newline
    $encoding = New-Object System.Text.UTF8Encoding $file.Bom
    return [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($text))
}

function Invoke-Git([string[]]$arguments) {
    $previous = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    try {
        $output = & git -C $RepoRoot @arguments
        if ($LASTEXITCODE -ne 0) { throw "git $($arguments -join ' ') failed" }
        return $output
    }
    finally { [Console]::OutputEncoding = $previous }
}

function Get-Excludes {
    if (-not (Test-Path $ExcludeFile)) { return @() }
    return @(Get-Content $ExcludeFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
}

function Test-Excluded([string]$relative, $excludes) {
    foreach ($pattern in $excludes) { if ($relative -like $pattern) { return $true } }
    return $false
}

function Get-RelativePath([string]$fullPath) {
    $full = [IO.Path]::GetFullPath($fullPath)
    if ($full.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $full = $full.Substring($RepoRoot.Length).TrimStart('\', '/')
    }
    return $full.Replace('\', '/')
}

function Get-TargetFiles {
    $excludes = Get-Excludes
    if ($Staged) {
        $names = Invoke-Git @('diff', '--cached', '--name-only', '--diff-filter=ACMR', '--', '*.ahk')
        return @($names | Where-Object { $_ -and -not (Test-Excluded $_ $excludes) })
    }
    if (-not $Path) {
        $names = Invoke-Git @('ls-files', '--', '*.ahk')
        return @($names | Where-Object { $_ -and -not (Test-Excluded $_ $excludes) })
    }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Path) {
        $item = Get-Item -LiteralPath $p
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -Recurse -Filter *.ahk -File | ForEach-Object {
                $relative = Get-RelativePath $_.FullName
                if (-not (Test-Excluded $relative $excludes)) { $result.Add($relative) }
            }
        }
        else {
            $result.Add((Get-RelativePath $item.FullName))
        }
    }
    return $result.ToArray()
}

function Get-FirstDifference([string[]]$a, [string[]]$b) {
    for ($k = 0; $k -lt [Math]::Min($a.Count, $b.Count); $k++) { if ($a[$k] -cne $b[$k]) { return $k + 1 } }
    return [Math]::Min($a.Count, $b.Count) + 1
}

# ---------------------------------------------------------------- tests

# Each test file is formatted correctly already. It must stay unchanged, and the
# same file with all indentation removed must come back identical.
function Invoke-SelfTest {
    $failed = 0
    $files = @(Get-ChildItem -LiteralPath $TestDir -Filter *.ahk -File)
    foreach ($f in $files) {
        $expected = (Read-AhkText ([IO.File]::ReadAllBytes($f.FullName))).Lines
        $result = Format-AhkLines $expected
        $flat = New-Object string[] $expected.Count
        for ($k = 0; $k -lt $expected.Count; $k++) {
            if ($result.Roles[$k] -eq 'verbatim' -or $result.Roles[$k] -eq 'section') { $flat[$k] = $expected[$k] }
            else { $flat[$k] = $expected[$k].TrimStart() }
        }
        $rebuilt = (Format-AhkLines $flat).Lines
        $problems = @()
        $line = Get-FirstDifference $expected $result.Lines
        if ($line -le $expected.Count) { $problems += "changes a formatted file at line $line" }
        $line = Get-FirstDifference $expected $rebuilt
        if ($line -le $expected.Count) { $problems += "line $line expected '$($expected[$line - 1])' got '$($rebuilt[$line - 1])'" }
        if ($problems) { $failed++; Write-Host "FAIL $($f.Name): $($problems -join '; ')" }
        else { Write-Host "ok   $($f.Name)" }
    }
    Write-Host "$($files.Count - $failed) of $($files.Count) tests passed"
    if ($failed) { exit 1 }
    exit 0
}

# ---------------------------------------------------------------- main

if ($Test) { Invoke-SelfTest }

if ($Stdin) {
    # Raw bytes in and out, so the console code page never touches the text.
    $buffer = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($buffer)
    $bytes = $buffer.ToArray()
    $result = $bytes
    $excluded = $Path -and (Test-Excluded (Get-RelativePath $Path[0]) (Get-Excludes))
    if (-not $excluded -and $bytes.Length -gt 0) {
        try {
            $file = Read-AhkText $bytes
            $result = Get-AhkBytes $file (Format-AhkLines $file.Lines).Lines
        }
        catch {
            [Console]::Error.WriteLine("Format-Ahk: left unchanged: $($_.Exception.Message)")
        }
    }
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($result, 0, $result.Length)
    $stdout.Flush()
    exit 0
}

$needsFormat = 0
$errors = 0
$formatted = 0
foreach ($relative in Get-TargetFiles) {
    $fullPath = $relative
    if (-not [IO.Path]::IsPathRooted($relative)) { $fullPath = Join-Path $RepoRoot $relative }
    try {
        if ($Staged -and $Check) {
            $content = Invoke-Git @('show', ":$relative")
            $file = @{ Bom = $false; Crlf = $false; Lines = @($content | ForEach-Object { $_ }) }
            if ($file.Lines.Count -gt 0 -and $file.Lines[0].StartsWith([char]0xFEFF)) { $file.Lines[0] = $file.Lines[0].Substring(1) }
            if ($file.Lines.Count -eq 0) { continue }
        }
        else {
            $file = Read-AhkText ([IO.File]::ReadAllBytes($fullPath))
        }
        $lines = (Format-AhkLines $file.Lines).Lines
        $line = Get-FirstDifference $file.Lines $lines
        $changed = $line -le $file.Lines.Count
        if (-not ($Staged -and $Check)) {
            $newBytes = [Convert]::ToBase64String((Get-AhkBytes $file $lines))
            $changed = $changed -or ($newBytes -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($fullPath)))
        }
        if (-not $changed) { continue }
        if ($Check) {
            $needsFormat++
            Write-Host "Needs formatting: $relative (line $line)"
        }
        else {
            [IO.File]::WriteAllBytes($fullPath, (Get-AhkBytes $file $lines))
            $formatted++
            Write-Host "Formatted: $relative"
        }
    }
    catch {
        $errors++
        Write-Host "Skipped: ${relative}: $($_.Exception.Message)"
    }
}

if ($Check -and $needsFormat) {
    $hint = '.\Helper\Format-Ahk.ps1'
    if ($Staged) { $hint += ' -Staged' }
    Write-Host "$needsFormat file(s) need formatting. Run $hint and add the changes."
}
elseif (-not $Check) {
    Write-Host "$formatted file(s) formatted."
}
if ($errors) { exit 2 }
if ($Check -and $needsFormat) { exit 1 }
exit 0
