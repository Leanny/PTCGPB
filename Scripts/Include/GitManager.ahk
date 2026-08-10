IsGitRepo(path) {
    tmpFile := A_Temp . "\ptcgpb_git_check.txt"
    RunWait, %ComSpec% /c git -C "%path%" rev-parse --git-dir > "%tmpFile%" 2>&1,, Hide
    FileRead, output, %tmpFile%
    return (Trim(output) != "" && !RegExMatch(output, "not a git repository"))
}

; Build the shared backup path list from botConfig category checkboxes.
BuildBackupPaths(cfg) {
    paths := []
    if (GetBackupFlag(cfg, "backupAccountsXml", 1))
        paths.Push({path: "Accounts/Saved", suffix: ".xml"})
    if (GetBackupFlag(cfg, "backupAccountsJson", 1))
        paths.Push({path: "Accounts/Cards/accounts", suffix: ".json"})
    if (GetBackupFlag(cfg, "backupSettingsIni", 1))
        paths.Push({path: "Settings.ini"})
    if (GetBackupFlag(cfg, "backupShowcaseIds", 1))
        paths.Push({path: "showcase_ids.txt"})
    if (GetBackupFlag(cfg, "backupManualVipIds", 1))
        paths.Push({path: "manual_vip_ids.txt"})
    if (GetBackupFlag(cfg, "backupFriendsGPTested", 1))
        paths.Push({path: "FriendsGPTested_*.txt"})
    if (GetBackupFlag(cfg, "backupSpecialEvents", 1)) {
        paths.Push({path: "SpecialEvents/Events", suffix: ".sevt"})
        paths.Push({path: "SpecialEvents/PastEvents", suffix: ".sevt"})
    }
    return paths
}

; True if at least one backup category checkbox is enabled.
BackupCategoriesSelected(cfg) {
    return (GetBackupFlag(cfg, "backupAccountsXml", 1)
        || GetBackupFlag(cfg, "backupAccountsJson", 1)
        || GetBackupFlag(cfg, "backupSettingsIni", 1)
        || GetBackupFlag(cfg, "backupShowcaseIds", 1)
        || GetBackupFlag(cfg, "backupManualVipIds", 1)
        || GetBackupFlag(cfg, "backupFriendsGPTested", 1)
        || GetBackupFlag(cfg, "backupSpecialEvents", 1))
}

; Read a 0/1 backup flag without botConfig.get treating "0" as empty (AHK v1).
GetBackupFlag(cfg, name, defaultVal := 1) {
    if (cfg.botConfigs["ToolsAndSystem"].HasKey(name)) {
        v := cfg.botConfigs["ToolsAndSystem"][name]
        if (v = "" || v = "0" || v = 0)
            return 0
        return 1
    }
    if (cfg.botConfigs["UserSettings"].HasKey(name)) {
        v := cfg.botConfigs["UserSettings"][name]
        if (v = "" || v = "0" || v = 0)
            return 0
        return 1
    }
    return defaultVal
}

; Write a 0/1 backup flag into ToolsAndSystem (bypass Trim(0)->"" in BotConfig.set).
SetBackupFlag(cfg, name, value) {
    cfg.botConfigs["ToolsAndSystem"][name] := value ? 1 : 0
}

; Ensure a directory exists; returns true if path is a directory afterwards.
EnsureDirExists(dirPath) {
    if (dirPath = "")
        return false
    if (!FileExist(dirPath))
        FileCreateDir, %dirPath%
    return InStr(FileExist(dirPath), "D")
}

; Copy selected backup paths from srcRoot into destFolder, preserving relative paths.
; Returns true on success (including zero files copied when sources are missing).
BackupToDisk(srcRoot, destFolder, pathsList, logFile) {
    try {
        if (!EnsureDirExists(destFolder)) {
            LogError("Disk backup folder missing or invalid: " . destFolder, logFile)
            return False
        }

        srcRoot := RegExReplace(srcRoot, "\\+$")
        destFolder := RegExReplace(destFolder, "\\+$")
        copied := 0

        for i, entry in pathsList {
            normPath := StrReplace(entry.path, "/", "\")
            normPath := RegExReplace(normPath, "\\+$")
            hasSuffix := entry.HasKey("suffix") && entry.suffix != ""
            isGlob := InStr(normPath, "*")
            isDir := entry.HasKey("dir") && entry.dir
            absPath := srcRoot . "\" . normPath

            if (hasSuffix) {
                if (!InStr(FileExist(absPath), "D"))
                    continue
                entrySuffix := entry.suffix
                Loop, Files, %absPath%\*%entrySuffix%, R
                {
                    rel := SubStr(A_LoopFileFullPath, StrLen(srcRoot) + 2)
                    destFile := destFolder . "\" . rel
                    SplitPath, destFile, , destDir
                    if (!EnsureDirExists(destDir))
                        continue
                    FileCopy, %A_LoopFileFullPath%, %destFile%, 1
                    if (!ErrorLevel)
                        copied++
                }
            } else if (isGlob) {
                Loop, Files, %srcRoot%\%normPath%
                {
                    if (InStr(A_LoopFileAttrib, "D"))
                        continue
                    rel := SubStr(A_LoopFileFullPath, StrLen(srcRoot) + 2)
                    destFile := destFolder . "\" . rel
                    SplitPath, destFile, , destDir
                    if (!EnsureDirExists(destDir))
                        continue
                    FileCopy, %A_LoopFileFullPath%, %destFile%, 1
                    if (!ErrorLevel)
                        copied++
                }
            } else if (isDir) {
                if (!InStr(FileExist(absPath), "D"))
                    continue
                Loop, Files, %absPath%\*.*, R
                {
                    if (InStr(A_LoopFileAttrib, "D"))
                        continue
                    rel := SubStr(A_LoopFileFullPath, StrLen(srcRoot) + 2)
                    destFile := destFolder . "\" . rel
                    SplitPath, destFile, , destDir
                    if (!EnsureDirExists(destDir))
                        continue
                    FileCopy, %A_LoopFileFullPath%, %destFile%, 1
                    if (!ErrorLevel)
                        copied++
                }
            } else {
                if (!FileExist(absPath))
                    continue
                destFile := destFolder . "\" . normPath
                SplitPath, destFile, , destDir
                if (!EnsureDirExists(destDir))
                    continue
                FileCopy, %absPath%, %destFile%, 1
                if (!ErrorLevel)
                    copied++
            }
        }

        LogInfo("Disk backup complete. Copied " . copied . " file(s) to " . destFolder, logFile)
        return True
    } catch e {
        LogError("Disk backup error: " . e.Message, logFile)
        return False
    }
}

; =======================================================================
; == CommitAndPushGit ==
; Commit and push configured backup paths (accounts, settings, VIP/GP Test
; files, special event .sevt files, etc.).
; Commit message is path +X -Y for easier tracking.
; Uses git add -f so gitignored user-data files can still be backed up.
; Adding git_history.csv log to track commits with timestamp and message.
;
; pathsList entry formats:
;   {path: "Settings.ini"}                          ; single file
;   {path: "FriendsGPTested_*.txt"}                  ; glob
;   {path: "Accounts/Saved", suffix: ".xml"}         ; directory + suffix
;   {path: "SpecialEvents/Events", dir: true}        ; all files in directory
; =======================================================================
CommitAndPushGit(gitRoot, logFile, pathsList) {
    try {
        tmpFile := A_Temp . "\ptcgpb_git_diff.txt"
        gitHistoryFile := gitRoot . "\git_history.csv"

        ; Build git add command - skip missing single files / directories
        addPaths := ""
        for i, entry in pathsList {
            normPath := StrReplace(entry.path, "\", "/")
            normPath := RegExReplace(normPath, "/+$")
            absPath := gitRoot . "\" . StrReplace(normPath, "/", "\")

            isGlob := InStr(normPath, "*")
            isDir := entry.HasKey("dir") && entry.dir
            hasSuffix := entry.HasKey("suffix") && entry.suffix != ""

            ; Skip missing single files or directories (globs are left to git)
            if (!isGlob) {
                if (isDir || hasSuffix) {
                    if (!InStr(FileExist(absPath), "D"))
                        continue
                } else if (!FileExist(absPath)) {
                    continue
                }
            }

            if (hasSuffix)
                addPaths .= " """ . normPath . "/**/*" . entry.suffix . """"
            else if (isGlob)
                addPaths .= " """ . normPath . """"
            else if (isDir)
                addPaths .= " """ . normPath . """"
            else
                addPaths .= " """ . normPath . """"
        }

        if (addPaths = "") {
            LogInfo("No files to commit.", logFile)
            return True
        }

        ; -f: include paths that are normally gitignored (user data backups)
        RunWait, %ComSpec% /c git -C "%gitRoot%" add -f%addPaths% > "%tmpFile%" 2>&1,, Hide
        FileRead, addOutput, %tmpFile%
        LogDebug("git add output: " . addOutput, logFile)

        ; Get staged changes
        RunWait, %ComSpec% /c git -C "%gitRoot%" diff --cached --name-status > "%tmpFile%" 2>&1,, Hide
        FileRead, diffOutput, %tmpFile%
        LogDebug("git diff --cached --name-status output: " . diffOutput, logFile)

        if (diffOutput = "") {
            LogInfo("No changes to commit.", logFile)
            return True
        }

        ; Initialize per-entry counters
        added := {}
        removed := {}
        for i, entry in pathsList {
            added[i] := 0
            removed[i] := 0
        }

        Loop, Parse, diffOutput, `n, `r
        {
            line := Trim(A_LoopField)
            if (line = "")
                continue
            ; Format: STATUS<tab>PATH
            RegExMatch(line, "^([A-Z])\t(.+)$", m)
            status := m1
            filePath := StrReplace(m2, "\", "/")
            for i, entry in pathsList {
                if (!GitPathMatchesEntry(filePath, entry))
                    continue
                if (status = "A" || status = "M")
                    added[i]++
                else if (status = "D")
                    removed[i]++
            }
        }

        ; Build commit message, skip entries with no changes
        commitMsg := "Auto-commit:"
        firstPart := True
        for i, entry in pathsList {
            if (added[i] = 0 && removed[i] = 0)
                continue
            if (!firstPart)
                commitMsg .= " |"
            commitMsg .= " " . entry.path . " +" . added[i] . " -" . removed[i]
            firstPart := False
        }

        if (firstPart) {
            LogInfo("No tracked changes staged. Skipping commit.", logFile)
            return True
        }

        LogInfo("Committing: " . commitMsg, logFile)

        ; Commit
        RunWait, %ComSpec% /c git -C "%gitRoot%" commit -m "%commitMsg%" > "%tmpFile%" 2>&1,, Hide
        FileRead, commitOutput, %tmpFile%
        LogDebug("git commit output: " . commitOutput, logFile)

        try {
            ; Push
            RunWait, %ComSpec% /c git -C "%gitRoot%" push > "%tmpFile%" 2>&1,, Hide
            FileRead, pushOutput, %tmpFile%
            LogDebug("git push output: " . pushOutput, logFile)
        } catch pushError {
            LogError("Git push error: " . pushError.Message, logFile)
        }

        ; Append to git_history.csv
        if (!FileExist(gitHistoryFile))
            FileAppend, % "timestamp,message`n", %gitHistoryFile%

        FormatTime, nowStr, %A_Now%, yyyy-MM-dd HH:mm:ss
        FileAppend, % nowStr . "," . commitMsg . "`n", %gitHistoryFile%

        LogInfo("Git auto-commit complete.", logFile)
    } catch e {
        LogError("Git auto-commit error: " . e.Message, logFile)
        return False
    }
    return True
}

; Returns true if a staged file path belongs to a backup pathsList entry.
GitPathMatchesEntry(filePath, entry) {
    normPath := RegExReplace(StrReplace(entry.path, "\", "/"), "/+$")
    hasSuffix := entry.HasKey("suffix") && entry.suffix != ""
    isDir := entry.HasKey("dir") && entry.dir
    isGlob := InStr(normPath, "*")

    if (hasSuffix) {
        if (!RegExMatch(filePath, "\" . entry.suffix . "$"))
            return false
        return (filePath = normPath || SubStr(filePath, 1, StrLen(normPath) + 1) = normPath . "/")
    }
    if (isGlob) {
        regex := "^" . StrReplace(StrReplace(StrReplace(normPath, ".", "\."), "*", ".*"), "/", "\/") . "$"
        return RegExMatch(filePath, regex)
    }
    if (isDir)
        return (filePath = normPath || SubStr(filePath, 1, StrLen(normPath) + 1) = normPath . "/")
    return (filePath = normPath)
}
