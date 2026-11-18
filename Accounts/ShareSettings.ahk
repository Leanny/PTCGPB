;===============================================================================
; ShareSettings.ahk - Collection-profile listing for the Collection Share
;   settings in PTCGPB.ahk. Self-contained: PTCGPB.ahk does not include
;   HistoryImport.ahk, so Collection_ListProfiles() is not available there.
;===============================================================================

ShareSettings_ProfilesDir() {
    return getScriptBaseFolder() . "\Accounts\Cards\collections"
}

ShareSettings_ListProfiles() {
    profiles := []
    dir := ShareSettings_ProfilesDir()
    if (!FileExist(dir))
        return profiles

    Loop, Files, % dir . "\*.json", F
    {
        fileKey := RegExReplace(A_LoopFileName, "\.json$", "")
        displayName := fileKey
        FileRead, jsonText, % A_LoopFileFullPath
        if (RegExMatch(jsonText, "i)""displayName""\s*:\s*""([^""]+)""", match))
            displayName := match1
        profiles.Push({ key: fileKey, displayName: displayName, path: A_LoopFileFullPath })
    }
    return profiles
}

;-------------------------------------------------------------------------------
; ShareSettings_MainIndex - Map a Main script name to its 1-based index
;   "Main" -> 1, "Main2" -> 2, "Main3" -> 3, ...
;-------------------------------------------------------------------------------
ShareSettings_MainIndex(scriptName) {
    if (scriptName = "Main")
        return 1
    if (RegExMatch(scriptName, "i)^Main(\d+)$", m))
        return m1 + 0
    return 0
}

;-------------------------------------------------------------------------------
; ShareSettings_MainCount - Number of configured Main instances (minimum 1)
;-------------------------------------------------------------------------------
ShareSettings_MainCount() {
    global botConfig
    count := botConfig.get("Mains") + 0
    if (count < 1)
        count := 1
    return count
}

;-------------------------------------------------------------------------------
; ShareSettings_MainConfig - Per-Main share settings.
;   Reads shareMain<N>Enabled/Collection/FriendCode/Sort from [Extra].
;-------------------------------------------------------------------------------
ShareSettings_MainConfig(index) {
    global botConfig
    cfg := { enabled: "", collection: "", friendCode: "", sort: "expansion", expansion: "" }
    cfg.enabled := botConfig.get("shareMain" . index . "Enabled")
    cfg.collection := botConfig.get("shareMain" . index . "Collection")
    cfg.friendCode := botConfig.get("shareMain" . index . "FriendCode")
    cfg.sort := botConfig.get("shareMain" . index . "Sort")
    if (cfg.sort != "rarity")
        cfg.sort := "expansion"
    cfg.expansion := botConfig.get("shareMain" . index . "Expansion")
    if (!RegExMatch(cfg.expansion, "^[A-Z][0-9][ab]?$"))
        cfg.expansion := ""
    return cfg
}

;-------------------------------------------------------------------------------
; ShareSettings_ListExpansions - Expansion picker entries from Helper\en_US.json
;   Returns [{code, name}] ordered by expansion index, SP entries excluded.
;   "C1" etc are included: the coordinator normalizes a pick equal to the
;   current latest back to Latest.
;-------------------------------------------------------------------------------
ShareSettings_ListExpansions() {
    exps := []
    path := getScriptBaseFolder() . "\Helper\en_US.json"
    if (!FileExist(path))
        return exps
    FileRead, txt, %path%
    Loop, 60 {
        idx := A_Index
        if (!RegExMatch(txt, """EXPANSION_NAME_" . idx . """\s*:\s*""([^""]+)""", mc))
            continue
        if (SubStr(mc1, 1, 2) = "SP")
            continue
        if (!RegExMatch(txt, """EXPANSION_NAME_LONG_" . idx . """\s*:\s*""([^""]+)""", ml))
            continue
        exps.Push({code: mc1, name: StrReplace(ml1, "\u2019", "'")})
    }
    return exps
}

;-------------------------------------------------------------------------------
; ShareExpansionLatestCode - Highest-index non-SP expansion code, i.e. the one
;   the card screen already shows without opening "View Other Booster Packs".
;-------------------------------------------------------------------------------
ShareExpansionLatestCode() {
    exps := ShareSettings_ListExpansions()
    return exps.Length() ? exps[exps.Length()].code : ""
}

;-------------------------------------------------------------------------------
; ShareSettings_AnyEnabled - True when at least one Main has share enabled
;-------------------------------------------------------------------------------
ShareSettings_AnyEnabled() {
    Loop, % ShareSettings_MainCount() {
        if (ShareSettings_MainConfig(A_Index).enabled)
            return true
    }
    return false
}
