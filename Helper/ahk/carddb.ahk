;===============================================================================
; carddb.ahk - AutoHotkey v1 fallback for Helper\carddb.exe
;===============================================================================
; Command-line compatible port of the bot-facing subcommands of carddb.exe, for
; systems where antivirus software quarantines the Rust binary:
;
;   AutoHotkey.exe carddb.ahk --root <dir> <subcommand> [options]
;
; Ported:      merge-card-db, merge-metadata, ensure-metadata, schedule-accounts,
;              balance-xmls, extract-metadata, clear-flag, clear-pull-history,
;              import-history, import-registry, import-collection,
;              format-account, append-pull, snapshot-accounts,
;              repair-accounts-from-snapshot
; Not ported:  serve, build-dashboard-index, ensure-dashboard-index,
;              rebuild-dashboard-db, sync-dashboard-db, checkpoint-dashboard-db
;              (the PowerShell dashboard server already covers the dashboard
;              without carddb.exe). They exit with code 1.
;
; Exit codes, stdout output, progress files, carddb_error.txt and
; carddb_balance.log match the Rust helper. Account files are written in the
; same serde_json layout, so both implementations can work on the same data.
;
; Speed: account files are split into lazy top-level values, so commands that
; only need "metadata" do not parse the pull history. A file that is not in the
; usual pretty-printed layout falls back to a full parse.
;===============================================================================

#NoEnv
#NoTrayIcon
#SingleInstance Off
#MaxMem 4095
SetBatchLines, -1
ListLines, Off
FileEncoding, UTF-8-RAW
OnError("CardDb_OnUnhandledError")

#Include %A_ScriptDir%\lib\Json.ahk
#Include %A_ScriptDir%\lib\Common.ahk

global CD_ROOT := "."

CardDb_Main()
ExitApp, 0

;===============================================================================
; Entry point
;===============================================================================

CardDb_Main() {
    args := []
    for _, arg in A_Args
        args.Push(arg)

    CD_ROOT := Path_Full(CardDb_RootArg(args))
    try {
        cli := CardDb_ParseCli(args)
    } catch e {
        text := "carddb argument parsing failed:`nerror: " . e.Message . "`n"
        CD_WriteError(text)
        CD_Log(RTrim(text, "`n"))
        StdErr(text)
        ExitApp, 2
    }

    CD_ROOT := Path_Full(cli.root)
    File_Delete(CD_SavedDir() . "\carddb_error.txt")
    CD_Log("carddb run started (ahk)")
    try {
        CardDb_Run(cli)
    } catch e {
        text := e.Message . "`n"
        CD_WriteError(text)
        CD_Log("carddb run failed: " . Trim(text, " `t`r`n"))
        StdErr(text)
        ExitApp, 1
    }
    CD_Log("carddb run completed")
}

CardDb_OnUnhandledError(e) {
    text := "carddb panic: " . (IsObject(e) ? e.Message . " (line " . e.Line . ")" : e) . "`n"
    CD_WriteError(text)
    CD_Log(RTrim(text, "`n"))
    StdErr(text)
    ExitApp, 1
}

CardDb_RootArg(args) {
    Loop % args.Length() {
        if (args[A_Index] == "--root" && A_Index < args.Length())
            return args[A_Index + 1]
        if (SubStr(args[A_Index], 1, 7) == "--root=")
            return SubStr(args[A_Index], 8)
    }
    return "."
}

CardDb_ParseCli(args) {
    root := "."
    i := 1
    n := args.Length()
    while (i <= n && SubStr(args[i], 1, 2) == "--") {
        if (args[i] == "--root") {
            if (i = n)
                throw Exception("a value is required for '--root' but none was supplied")
            root := args[i + 1]
            i += 2
        } else if (SubStr(args[i], 1, 7) == "--root=") {
            root := SubStr(args[i], 8)
            i += 1
        } else {
            throw Exception("unexpected argument '" . args[i] . "' found")
        }
    }
    if (i > n)
        throw Exception("'carddb' requires a subcommand but one was not provided")

    command := args[i]
    scheduleFlags := "wonderpick-for-event-missions claim-daily-mission claim-special-missions receive-gift ocr-shinedust s4t-enabled spend-hourglass force-inject"
    specs := {}
    specs["merge-card-db"] := {}
    specs["merge-metadata"] := {}
    specs["ensure-metadata"] := {}
    specs["schedule-accounts"] := {values: "instance delete-method sort-method inject-wonderpick-min-packs"
        , flags: scheduleFlags . " force-clear-used", required: "instance delete-method sort-method"}
    specs["balance-xmls"] := {values: "instances delete-method sort-method inject-wonderpick-min-packs"
        , flags: scheduleFlags, required: "instances delete-method sort-method"}
    specs["extract-metadata"] := {values: "device-account instance file-name key output", required: "output"}
    specs["clear-flag"] := {values: "flag", required: "flag"}
    specs["clear-pull-history"] := {}
    specs["import-history"] := {values: "device-account input", flags: "in-depth", required: "device-account input"}
    specs["import-registry"] := {values: "device-account input instance name into", required: "device-account input instance"}
    specs["import-collection"] := {values: "device-account input instance name into", required: "device-account input instance"}
    specs["format-account"] := {values: "device-account", required: "device-account"}
    specs["append-pull"] := {values: "device-account timestamp pack cards cards-file", required: "device-account timestamp pack"}
    specs["snapshot-accounts"] := {}
    specs["repair-accounts-from-snapshot"] := {}
    unsupported := "build-dashboard-index ensure-dashboard-index rebuild-dashboard-db sync-dashboard-db checkpoint-dashboard-db serve"

    if (!specs.HasKey(command)) {
        if (InStr(" " . unsupported . " ", " " . command . " ", true))
            return {root: root, command: command, unsupported: true}
        throw Exception("unrecognized subcommand '" . command . "'")
    }
    spec := specs[command]
    cli := Cli_Parse(args, i + 1, spec)
    if (cli.pos.Length())
        throw Exception("unexpected argument '" . cli.pos[1] . "' found")
    Cli_Require(cli, spec.required)
    cli.root := root
    cli.command := command

    if (cli.opts.HasKey("inject_wonderpick_min_packs")) {
        v := cli.opts.inject_wonderpick_min_packs
        if (!RegExMatch(v, "^[+-]?\d+$") || v + 0 < 70 || v + 0 > 999)
            throw Exception("invalid value '" . v . "' for '--inject-wonderpick-min-packs <INJECT_WONDERPICK_MIN_PACKS>': " . v . " is not in 70..=999")
        cli.opts.inject_wonderpick_min_packs := v + 0
    } else {
        cli.opts.inject_wonderpick_min_packs := 96
    }
    if (cli.opts.HasKey("instances")) {
        v := cli.opts.instances
        if (!RegExMatch(v, "^\+?\d+$"))
            throw Exception("invalid value '" . v . "' for '--instances <INSTANCES>': invalid digit found in string")
        cli.opts.instances := v + 0
    }
    if (command = "import-registry" || command = "import-collection") {
        if (cli.opts.HasKey("name") && cli.opts.HasKey("into"))
            throw Exception("the argument '--name <NAME>' cannot be used with '--into <INTO>'")
    }
    if (command = "append-pull") {
        hasCards := cli.opts.HasKey("cards"), hasFile := cli.opts.HasKey("cards_file")
        if (hasCards && hasFile)
            throw Exception("the argument '--cards <CARDS>' cannot be used with '--cards-file <CARDS_FILE>'")
        if (!hasCards && !hasFile)
            throw Exception("the following required arguments were not provided: --cards <CARDS>")
    }
    return cli
}

CardDb_Run(cli) {
    if (cli.unsupported)
        throw Exception("'" . cli.command . "' is not available in the AutoHotkey fallback; it needs Helper\carddb.exe")

    o := cli.opts, f := cli.flags
    cmd := cli.command
    if (cmd = "merge-card-db")
        return CD_MergeCardDb()
    if (cmd = "merge-metadata")
        return CD_MergeMetadata()
    if (cmd = "ensure-metadata")
        return CD_EnsureMetadata()
    if (cmd = "schedule-accounts" || cmd = "balance-xmls") {
        options := {instance: (cmd = "schedule-accounts") ? o.instance : ""
            , delete_method: o.delete_method, sort_method: o.sort_method
            , inject_wonderpick_min_packs: o.inject_wonderpick_min_packs}
        for _, name in StrSplit("wonderpick_for_event_missions claim_daily_mission claim_special_missions receive_gift ocr_shinedust s4t_enabled spend_hourglass force_inject force_clear_used", " ")
            options[name] := f.HasKey(name) ? true : false
        if (cmd = "schedule-accounts")
            return CD_ScheduleAccounts(options)
        options.force_clear_used := false
        return CD_BalanceXmls(o.instances, options)
    }
    if (cmd = "extract-metadata")
        return CD_ExtractMetadata(o.HasKey("device_account") ? o.device_account : "", o.HasKey("instance") ? o.instance : ""
            , o.HasKey("file_name") ? o.file_name : "", o.HasKey("key") ? o.key : "", o.output
            , o.HasKey("device_account"), o.HasKey("instance"), o.HasKey("file_name"), o.HasKey("key"))
    if (cmd = "clear-flag")
        return CD_ClearFlag(o.flag)
    if (cmd = "clear-pull-history")
        return CD_ClearPullHistory()
    if (cmd = "import-history")
        return CD_ImportHistory(o.device_account, CD_ArgPath(o.input), f.HasKey("in_depth"))
    if (cmd = "import-registry" || cmd = "import-collection")
        return CD_ImportCollection(o.device_account, CD_ArgPath(o.input), o.instance
            , o.HasKey("name") ? o.name : "", o.HasKey("into") ? o.into : "", o.HasKey("name"), o.HasKey("into"))
    if (cmd = "format-account")
        return CD_FormatAccount(o.device_account)
    if (cmd = "append-pull") {
        if (o.HasKey("cards_file")) {
            path := CD_ArgPath(o.cards_file)
            try cardsText := File_ReadUtf8(path)
            catch
                throw Exception("Could not read cards file """ . path . """")
        } else {
            cardsText := o.cards
        }
        return CD_AppendPull(o.device_account, o.timestamp, o.pack, cardsText)
    }
    if (cmd = "snapshot-accounts")
        return CD_SnapshotAccounts()
    if (cmd = "repair-accounts-from-snapshot")
        return CD_RepairAccountsFromSnapshot()
}

; Relative paths in arguments resolve against the working directory (Rust).
CD_ArgPath(path) {
    return Path_Full(path)
}

;===============================================================================
; Paths, logging, progress
;===============================================================================

CD_CardsDir() {
    return CD_ROOT . "\Accounts\Cards"
}

CD_AccountDir() {
    return CD_CardsDir() . "\accounts"
}

CD_CollectionsDir() {
    return CD_CardsDir() . "\collections"
}

CD_SavedDir() {
    return CD_ROOT . "\Accounts\Saved"
}

CD_CacheDir() {
    return CD_CardsDir() . "\database_cache"
}

CD_SafeFileName(value) {
    return RegExReplace(value, "[\\/:*?""<>|]", "_")
}

CD_AccountPath(accountKey) {
    return CD_AccountDir() . "\" . CD_SafeFileName(accountKey) . ".json"
}

CD_CollectionPath(collectionKey) {
    return CD_CollectionsDir() . "\" . CD_SafeFileName(collectionKey) . ".json"
}

CD_LegacyMetadataPath() {
    return CD_CardsDir() . "\metadata.json"
}

CD_CardmapPath() {
    return CD_ROOT . "\Helper\cardmap.json"
}

CD_WriteError(text) {
    try {
        Dir_Create(CD_SavedDir())
        File_WriteUtf8(CD_SavedDir() . "\carddb_error.txt", text)
    }
}

CD_Log(message) {
    try {
        Dir_Create(CD_SavedDir())
        stamp := Ts_Format(A_Now, "yyyy-MM-dd HH:mm:ss") . "." . A_MSec
        File_AppendUtf8(CD_SavedDir() . "\carddb_balance.log", "[" . stamp . "] " . message . "`n")
    }
}

CD_WriteProgress(fileName, percent, message) {
    Dir_Create(CD_SavedDir())
    File_WriteUtf8(CD_SavedDir() . "\" . fileName, Min(percent, 100) . "|" . message . "`n")
}

CD_MigrationProgress(percent, message) {
    CD_WriteProgress("metadata_migration_progress.txt", percent, message)
}

CD_BalanceProgress(percent, message) {
    CD_WriteProgress("balance_progress.txt", percent, message)
}

CD_ClearFlagProgress(percent, message) {
    CD_WriteProgress("clear_flag_progress.txt", percent, message)
}

; Rust path display ({:?}) used in log messages.
CD_Q(path) {
    return """" . StrReplace(path, "\", "\\") . """"
}

;===============================================================================
; Account documents
;===============================================================================

; Reads an account JSON file. Returns a JObj (top-level values lazy when the
; file has the usual pretty layout), a parsed non-object value, or "" when the
; file is corrupted (empty, zero-filled, truncated or invalid JSON).
CD_ReadJsonFile(path, ByRef corrupted) {
    corrupted := false
    f := FileOpen(path, "r")
    if (!IsObject(f))
        throw Exception("Could not read " . CD_Q(path))
    size := f.Length
    if (size = 0) {
        f.Close()
        corrupted := true
        return ""
    }
    sample := Min(size, 4096)
    VarSetCapacity(buf, sample, 0)
    f.RawRead(buf, sample)
    f.Close()
    allZero := true
    Loop, %sample% {
        if (NumGet(buf, A_Index - 1, "UChar") != 0) {
            allZero := false
            break
        }
    }
    if (allZero) {
        corrupted := true
        return ""
    }

    text := File_ReadUtf8(path)
    doc := Json_ParseTopLazy(text)
    if (IsObject(doc))
        return doc
    try {
        return Json_Parse(text)
    } catch {
        corrupted := true
        return ""
    }
}

CD_IsAccountJsonCorrupted(path) {
    CD_ReadJsonFile(path, corrupted)
    return corrupted
}

CD_NewEmptyDoc(deviceAccount) {
    doc := new JObj
    doc.Set("deviceAccount", deviceAccount)
    doc.Set("metadata", new JObj)
    doc.Set("pulls", [])
    doc.Set("registeredCards", [])
    doc.Set("tradedCards", new JObj)
    doc.Set("sharedCards", new JObj)
    return doc
}

; load_account_document
CD_LoadAccountDocument(path, deviceAccount) {
    if (!File_Exists(path))
        return CD_NewEmptyDoc(deviceAccount)
    doc := CD_ReadJsonFile(path, corrupted)
    if (corrupted)
        return CD_NewEmptyDoc(deviceAccount)
    if (!J_IsObj(doc))
        doc := new JObj
    if (!doc.Has("deviceAccount"))
        doc.Set("deviceAccount", deviceAccount)
    if (!doc.Has("metadata"))
        doc.Set("metadata", new JObj)
    if (!doc.Has("pulls"))
        doc.Set("pulls", [])
    if (!doc.Has("registeredCards"))
        doc.Set("registeredCards", [])
    if (!doc.Has("tradedCards"))
        doc.Set("tradedCards", new JObj)
    if (!doc.Has("sharedCards"))
        doc.Set("sharedCards", new JObj)
    CD_HoistCardMarks(doc)
    return doc
}

CD_WriteAccountDocument(deviceAccount, doc) {
    path := CD_AccountPath(deviceAccount)
    Dir_Create(Path_Dir(path))
    text := Json_Dump(doc, true) . "`n"
    File_WriteAtomic(path, text, Path_WithExt(path, "json.tmp"))
}

; True when the value is not an object or an empty object.
CD_CardMarksEmpty(v) {
    if (IsObject(v) && v.__Class = "JRaw")
        return !RegExMatch(v.raw, "^\{") || RegExMatch(v.raw, "^\{\s*\}$")
    return !J_IsObj(v) || v.Count() = 0
}

; hoist_card_marks_from_metadata
CD_HoistCardMarks(doc) {
    metadata := doc.Get("metadata")
    if (!J_IsObj(metadata))
        return
    moved := []
    for _, key in ["tradedCards", "sharedCards"] {
        if (metadata.Has(key)) {
            legacy := metadata.Get(key)
            metadata.Delete(key)
            moved.Push([key, legacy])
        }
    }
    for _, pair in moved {
        rootEmpty := !doc.Has(pair[1]) || CD_CardMarksEmpty(doc.Peek(pair[1]))
        if (rootEmpty && !CD_CardMarksEmpty(pair[2]))
            doc.Set(pair[1], pair[2])
    }
}

; Rust: value.get("metadata").cloned().unwrap_or({}) from a whole-file parse.
; Returns false when the file cannot be read or parsed.
CD_LoadAccountFileMetadata(path, ByRef metadata) {
    try {
        doc := CD_ReadJsonFile(path, corrupted)
    } catch {
        return false
    }
    if (corrupted)
        return false
    metadata := J_IsObj(doc) ? doc.Get("metadata", new JObj) : new JObj
    return true
}

; Appends pulls to doc["pulls"]. Splices into the raw pretty text when the
; array is still unparsed, so long pull histories are not parsed and re-dumped.
CD_DocAppendPulls(doc, pulls) {
    cur := doc.Peek("pulls")
    if (IsObject(cur) && cur.__Class = "JRaw") {
        raw := cur.raw
        items := ""
        for i, pull in pulls
            items .= (i > 1 ? ",`n" : "") . "    " . Json_Dump(pull, true, "    ")
        if (RegExMatch(raw, "^\[\s*\]$")) {
            doc.Set("pulls", new JRaw(pulls.Length() ? "[`n" . items . "`n  ]" : "[]"))
            return
        }
        if (SubStr(raw, 1, 2) == "[`n" && SubStr(raw, -3) == "`n  ]") {
            if (pulls.Length())
                doc.Set("pulls", new JRaw(SubStr(raw, 1, StrLen(raw) - 4) . ",`n" . items . "`n  ]"))
            return
        }
        if (SubStr(raw, 1, 1) != "[") {
            doc.Set("pulls", [])
        }
    }
    arr := doc.Get("pulls")
    if (!J_IsArr(arr)) {
        arr := []
        doc.Set("pulls", arr)
    }
    for _, pull in pulls
        arr.Push(pull)
}

;===============================================================================
; Account metadata helpers (compact/merge/normalize)
;===============================================================================

CD_ValueIsZeroish(v) {
    t := J_Type(v)
    if (t = "string")
        return v = "" || v == "0"
    if (t = "number")
        return J_IsInt(v) && v = 0
    if (t = "raw")
        return v.raw == """""" || v.raw == """0""" || v.raw == "0"
    return false
}

; value.as_bool().unwrap_or(false) || value.as_i64().unwrap_or(0) != 0
CD_ValueTruthy(v) {
    return J_IsTrue(v) || (J_IsInt(v) && v != 0)
}

CD_NewFlag(value, setAt, validUntil) {
    flag := new JObj
    flag.Set("value", value + 0)
    flag.Set("setAt", "" . setAt)
    flag.Set("validUntil", "" . validUntil)
    return flag
}

CD_NormalizeCreatedAt(v, ByRef out) {
    t := J_Type(v)
    if (t = "string")
        raw := S_Trim(v)
    else if (t = "number")
        raw := IsObject(v) ? v.raw : "" . v
    else {
        if (!J_Meaningful(v))
            return false
        out := J_Clone(v)
        return true
    }
    if (raw = "" || raw == "0")
        return false
    if (StrLen(raw) = 14 && S_IsDigits(raw)) {
        out := raw
        return true
    }
    len := StrLen(raw)
    if (len >= 9 && len <= 12 && S_IsDigits(raw)) {
        ts := Ts_FromUnix(raw + 0)
        if (ts != "") {
            out := ts
            return true
        }
    }
    out := raw
    return true
}

CD_ShinedustMeaningful(v) {
    if (!J_IsObj(v))
        return J_Meaningful(v)
    current := J_Int(v.Get("value"), -1)
    updated := J_Str(v.Get("lastUpdatedAt"), "0")
    return current != -1 || !S_Eq(updated, "0")
}

CD_FlagMeaningful(v) {
    if (!J_IsObj(v))
        return J_Meaningful(v)
    value := v.Get("value")
    return J_Int(value, 0) != 0 || J_IsTrue(value)
        || J_Str(v.Get("setAt"), "") != "" || J_Str(v.Get("validUntil"), "") != ""
}

CD_AddDaysStamp(ts, days) {
    if (!Ts_IsValid(ts))
        return ""
    utc := Ts_LocalToUtc(ts)
    if (utc = "")
        return ""
    return Ts_UtcToLocal(Ts_Add(utc, days, "Days"))
}

; normalize_legacy_last_modified
CD_NormalizeLegacyLastModified(obj, fallbackModified) {
    legacy := ""
    if (obj.Has("lastModified")) {
        legacy := J_Str(obj.Get("lastModified"), "")
        obj.Delete("lastModified")
    }
    if (legacy = "")
        legacy := fallbackModified
    if (legacy = "")
        return

    lpp := obj.Get("lastPackPulled")
    if (!obj.Has("lastPackPulled") || CD_ValueIsZeroish(lpp) || S_Eq(J_Str(lpp, "x"), ""))
        obj.Set("lastPackPulled", legacy)

    flags := obj.Get("flags")
    if (!J_IsObj(flags))
        return
    tFlag := flags.Get("T")
    if (!J_IsObj(tFlag))
        return
    if (tFlag.Has("value") && CD_ValueTruthy(tFlag.Get("value"))) {
        validUntil := CD_AddDaysStamp(legacy, 5)
        if (validUntil != "")
            tFlag.Set("validUntil", validUntil)
    }
}

CD_CompactFlagForWrite(flag) {
    if (!J_IsObj(flag))
        return
    if (flag.Has("value")) {
        value := flag.Get("value")
        if (!J_IsTrue(value) && J_Int(value, 0) = 0)
            flag.Delete("value")
    }
    if (flag.Has("setAt") && S_Eq(J_Str(flag.Get("setAt"), "x"), ""))
        flag.Delete("setAt")
    if (flag.Has("validUntil") && S_Eq(J_Str(flag.Get("validUntil"), "x"), ""))
        flag.Delete("validUntil")
}

; compact_account_for_write
CD_CompactAccountForWrite(obj) {
    if (!J_IsObj(obj))
        return
    obj.Delete("deviceAccount")
    CD_NormalizeLegacyLastModified(obj, "")

    fileName := J_Str(obj.Get("fileName"), "")
    if (J_Str(obj.Get("instance"), "") = "")
        obj.Delete("instance")
    if (fileName = "")
        obj.Delete("fileName")

    if (obj.Has("packCount") && J_IntOrParsed(obj.Get("packCount"), pc) && pc = 0)
        obj.Delete("packCount")

    if (obj.Has("createdAt")) {
        if (CD_NormalizeCreatedAt(obj.Get("createdAt"), created))
            obj.Set("createdAt", created)
        else
            obj.Delete("createdAt")
    }

    for _, key in ["lastPackPulled", "lastLoggedIn"] {
        if (obj.Has(key)) {
            v := obj.Get(key)
            if (CD_ValueIsZeroish(v) || S_Eq(J_Str(v, "x"), ""))
                obj.Delete(key)
        }
    }

    if (obj.Has("shinedust") && !CD_ShinedustMeaningful(obj.Get("shinedust")))
        obj.Delete("shinedust")

    if (obj.Has("flags")) {
        flags := obj.Get("flags")
        if (J_IsObj(flags)) {
            for _, k in flags.Keys()
                if (!CD_FlagMeaningful(flags.Get(k)))
                    flags.DeleteOrdered(k)
            for _, k in flags.Keys()
                CD_CompactFlagForWrite(flags.Get(k))
        }
        if (!J_IsObj(flags) || flags.Count() = 0)
            obj.Delete("flags")
    }
}

; merge_flags
CD_MergeFlags(base, patchFlags) {
    if (!J_IsObj(patchFlags))
        return
    if (!base.Has("flags"))
        base.Set("flags", new JObj)
    flags := base.Get("flags")
    if (!J_IsObj(flags)) {
        flags := new JObj
        base.Set("flags", flags)
    }
    for _, name in patchFlags.Keys() {
        patchFlag := patchFlags.Get(name)
        if (CD_FlagMeaningful(patchFlag))
            flags.Set(name, J_Clone(patchFlag))
        else if (!flags.Has(name))
            flags.Set(name, CD_NewFlag(0, "", ""))
    }
}

; merge_account. Returns the (possibly replaced) base object.
CD_MergeAccount(base, patch) {
    if (!J_IsObj(base))
        base := new JObj
    if (!J_IsObj(patch))
        return base
    legacyModified := J_Str(patch.Get("lastModified"), "")
    for _, key in patch.Keys() {
        value := patch.Get(key)
        if (key == "flags") {
            CD_MergeFlags(base, value)
        } else if (key == "shinedust") {
            if (CD_ShinedustMeaningful(value))
                base.Set(key, J_Clone(value))
        } else if (key == "lastPackPulled" || key == "lastLoggedIn") {
            if (!CD_ValueIsZeroish(value))
                base.Set(key, J_Clone(value))
        } else if (key == "lastModified") {
            if (!CD_ValueIsZeroish(value) && (!base.Has("lastPackPulled") || CD_ValueIsZeroish(base.Get("lastPackPulled"))))
                base.Set("lastPackPulled", J_Clone(value))
        } else if (key == "packCount") {
            if (!CD_ValueIsZeroish(value))
                base.Set(key, J_Clone(value))
        } else if (key == "createdAt") {
            if (CD_NormalizeCreatedAt(value, created))
                base.Set(key, created)
        } else if (J_Meaningful(value)) {
            base.Set(key, J_Clone(value))
        }
    }
    CD_NormalizeLegacyLastModified(base, legacyModified)
    return base
}

; account_key
CD_AccountKey(inputKey, account) {
    if (J_IsObj(account)) {
        device := J_Str(account.Get("deviceAccount"), "")
        if (device != "")
            return device
    }
    if (S_StartsWith(inputKey, "deviceAccount:"))
        return SubStr(inputKey, 15)
    return inputKey
}

CD_NewStore() {
    store := new JObj
    store.Set("accounts", new JObj)
    return store
}

; ensure_store + normalize_store_keys
CD_EnsureStore(value) {
    if (!J_IsObj(value))
        value := new JObj
    if (!J_IsObj(value.Get("accounts")))
        value.Set("accounts", new JObj)
    old := value.Get("accounts")
    accounts := new JObj
    for _, key in old.Keys() {
        account := old.Get(key)
        newKey := CD_AccountKey(key, account)
        if (J_IsObj(account))
            account.Delete("deviceAccount")
        if (accounts.Has(newKey))
            accounts.Set(newKey, CD_MergeAccount(accounts.Get(newKey), account))
        else
            accounts.Set(newKey, account)
    }
    value.Set("accounts", accounts)
    return value
}

CD_LoadStore(path) {
    if (!File_Exists(path) || File_Size(path) = 0)
        return CD_NewStore()
    text := File_ReadUtf8(path)
    try value := Json_Parse(text)
    catch e
        throw Exception("Could not parse " . CD_Q(path) . ": " . e.Message)
    return CD_EnsureStore(value)
}

; field_str / field_i64 / flag helpers on account metadata
CD_FieldStr(account, field) {
    return J_IsObj(account) ? J_Str(account.Get(field), "") : ""
}

CD_FieldI64(account, field, ByRef out) {
    return J_IsObj(account) && J_IntOrParsed(account.Get(field), out)
}

CD_Flag(account, name) {
    if (!J_IsObj(account))
        return ""
    flags := account.Get("flags")
    return J_IsObj(flags) ? flags.Get(name) : ""
}

CD_FlagValue(account, name) {
    flag := CD_Flag(account, name)
    return J_IsObj(flag) && flag.Has("value") && CD_ValueTruthy(flag.Get("value"))
}

CD_FlagStr(account, name, field) {
    flag := CD_Flag(account, name)
    return J_IsObj(flag) ? J_Str(flag.Get(field), "") : ""
}

;===============================================================================
; New accounts from XML files
;===============================================================================

CD_InitialPackCount(fileName) {
    if (RegExMatch(fileName, "^(\d+)P", m) && StrLen(LTrim(m1, "0")) <= 18)
        return m1 + 0
    return J_N(0)
}

CD_InitialCreatedAt(fileName) {
    p := InStr(fileName, "P_", true)
    if (p && RegExMatch(SubStr(fileName, p + 2, 14), "^[0-9]{14}$", m))
        return m
    return "0"
}

CD_FilenameFlags(fileName) {
    result := {}
    open := InStr(fileName, "(", true, 0)
    if (!open)
        return result
    close := InStr(fileName, ")", true, open + 1)
    if (!close)
        return result
    for _, ch in StrSplit(SubStr(fileName, open + 1, close - open - 1))
        if (ch != "" && InStr("BXTRWH", ch, true))
            result[ch] := true
    return result
}

CD_ExtractDeviceAccountFromXml(path) {
    try text := File_ReadUtf8(path)
    catch
        return ""
    tag := "<string name=""deviceAccount"">"
    start := InStr(text, tag, true)
    if (!start)
        return ""
    valueStart := start + StrLen(tag)
    valueEnd := InStr(text, "</string>", true, valueStart)
    if (!valueEnd)
        return ""
    return SubStr(text, valueStart, valueEnd - valueStart)
}

; new_account
CD_NewAccount(instance, fileName, filePath) {
    found := CD_FilenameFlags(fileName)
    now := A_Now
    modified := File_ModifiedLocal(filePath)
    account := new JObj
    account.Set("instance", "" . instance)
    account.Set("fileName", "" . fileName)
    account.Set("packCount", CD_InitialPackCount(fileName) + 0)
    account.Set("createdAt", CD_InitialCreatedAt(fileName))
    account.Set("lastPackPulled", "" . modified)
    account.Set("lastLoggedIn", "0")
    shinedust := new JObj
    shinedust.Set("value", -1)
    shinedust.Set("lastUpdatedAt", "0")
    account.Set("shinedust", shinedust)
    flags := new JObj
    for _, name in ["B", "X", "T", "R", "W", "H"] {
        if (found.HasKey(name))
            flags.Set(name, CD_NewFlag(1, now, (name == "T") ? CD_AddDaysStamp(modified, 5) : ""))
        else
            flags.Set(name, CD_NewFlag(0, "", ""))
    }
    flags.Set("SH", CD_NewFlag(0, "", ""))
    flags.Set("FI", CD_NewFlag(0, "", ""))
    account.Set("flags", flags)
    return account
}

;===============================================================================
; merge-card-db (legacy Card_Database.csv import)
;===============================================================================

CD_MergeCardDb() {
    CD_Log("merge_card_db entered")
    CD_MigrateLegacyCardDatabase()
    CD_Log("merge_card_db completed")
}

CD_ParseCsvLine(line) {
    fields := []
    field := ""
    inQuotes := false
    chars := StrSplit(line)
    n := chars.Length()
    i := 1
    while (i <= n) {
        ch := chars[i]
        if (ch == """" && inQuotes && i < n && chars[i + 1] == """") {
            field .= """"
            i += 2
            continue
        }
        if (ch == """")
            inQuotes := !inQuotes
        else if (ch == "," && !inQuotes) {
            fields.Push(field)
            field := ""
        } else
            field .= ch
        i += 1
    }
    fields.Push(field)
    return fields
}

CD_IsValidCardId(cardId) {
    return RegExMatch(cardId, "^[A-Za-z0-9_-]{1,64}$")
}

CD_CardIdsFromField(text, sep) {
    out := []
    for _, part in StrSplit(text, sep) {
        part := S_Trim(part)
        if (CD_IsValidCardId(part))
            out.Push(part)
    }
    return out
}

CD_CountNonEmptyParts(text, sep) {
    count := 0
    for _, part in StrSplit(text, sep)
        if (S_Trim(part) != "")
            count += 1
    return count
}

; Groups cards by pack (BTreeMap order) into pull objects.
CD_PullsByPack(timestamp, cards, cardmap) {
    groups := new JObj
    for _, card in cards {
        pack := cardmap.HasKey("k" . card) ? cardmap["k" . card] : "unknown"
        if (!groups.Has(pack))
            groups.Set(pack, [])
        groups.Get(pack).Push(card)
    }
    packs := Arr_Sort(groups.Keys(), Func("Cmp_Ordinal"))
    pulls := []
    for _, pack in packs {
        pull := new JObj
        pull.Set("timestamp", timestamp)
        pull.Set("pack", pack)
        pull.Set("cards", groups.Get(pack))
        pulls.Push(pull)
    }
    return pulls
}

; pulls_from_fields. Returns "" when the row has no pulls.
CD_PullsFromFields(fields, cardmap) {
    if (fields.Length() < 4)
        return ""
    timestamp := LTrim(S_Trim(fields[1]), Chr(0xFEFF))
    if (timestamp = "Timestamp" || timestamp = "")
        return ""
    normalized := CD_NormalizePullTimestamp(timestamp)
    if (normalized != "")
        timestamp := normalized
    device := S_Trim(fields[2])
    if (device = "")
        return ""
    cards := CD_CardIdsFromField(fields[4], "|")
    if (!cards.Length())
        return ""
    if (CD_CountNonEmptyParts(fields[3], ",") > 1) {
        if (!IsObject(cardmap))
            return ""
        return {device: device, pulls: CD_PullsByPack(timestamp, cards, cardmap)}
    }
    pull := new JObj
    pull.Set("timestamp", timestamp)
    pull.Set("pack", S_Trim(fields[3]))
    pull.Set("cards", cards)
    return {device: device, pulls: [pull]}
}

CD_ImportCardRows(ByRef csvText) {
    imported := 0
    cardmap := ""
    docs := new JObj
    order := []
    Loop, Parse, csvText, `n
    {
        line := RTrim(A_LoopField, "`r")
        if (S_Trim(line) = "")
            continue
        fields := CD_ParseCsvLine(line)
        if (fields.Length() >= 3 && CD_CountNonEmptyParts(fields[3], ",") > 1) {
            cards := (fields.Length() >= 4) ? CD_CardIdsFromField(fields[4], "|") : []
            needs := !IsObject(cardmap)
            if (!needs)
                for _, card in cards
                    if (!cardmap.HasKey("k" . card))
                        needs := true
            if (needs) {
                CD_Log("import_card_rows loading cardmap for multi-pack CSV rows")
                cardmap := CD_LoadCardmapForCards(cards)
            }
        }
        rows := CD_PullsFromFields(fields, cardmap)
        if (!IsObject(rows))
            continue
        if (!docs.Has(rows.device)) {
            docs.Set(rows.device, CD_LoadAccountDocument(CD_AccountPath(rows.device), rows.device))
            order.Push(rows.device)
        }
        CD_DocAppendPulls(docs.Get(rows.device), rows.pulls)
        imported += rows.pulls.Length()
    }
    for _, device in order
        CD_WriteAccountDocument(device, docs.Get(device))
    CD_Log("import_card_rows completed; imported=" . imported)
}

CD_MigrateLegacyCardDatabase() {
    dbPath := CD_CardsDir() . "\Card_Database.csv"
    if (!File_Exists(dbPath) || File_Size(dbPath) = 0) {
        CD_Log("migrate_legacy_card_database skipped; missing_or_empty=" . CD_Q(dbPath))
        return
    }
    CD_Log("migrate_legacy_card_database importing " . CD_Q(dbPath) . "; bytes=" . File_Size(dbPath))
    try content := File_ReadUtf8(dbPath)
    catch
        throw Exception("Could not read legacy card database " . CD_Q(dbPath))
    CD_ImportCardRows(content)
    migrated := CD_CardsDir() . "\Card_Database.csv.migrated_" . A_Now
    try File_Rename(dbPath, migrated)
    catch
        throw Exception("Could not archive legacy card database to " . CD_Q(migrated))
    CD_Log("migrate_legacy_card_database archived to " . CD_Q(migrated))
}

;===============================================================================
; cardmap.json (card id -> expansion)
;===============================================================================

CD_EnsureCardmap() {
    path := CD_CardmapPath()
    if (File_Exists(path) && File_Size(path) > 0)
        return path
    CD_DownloadCardmap(path, false)
    return path
}

CD_DownloadCardmap(path, force) {
    CardMap_Download(path, force)
    CD_Log("downloaded cardmap.json to " . CD_Q(path))
}

; Returns an AHK object "k<cardId>" -> expansion id.
CD_ParseCardmap(path) {
    static cache := {}
    File_Stat(path, nanos, size)
    cacheKey := path . "|" . nanos . "|" . size
    if (cache.HasKey(cacheKey))
        return cache[cacheKey]

    try text := File_ReadUtf8(path)
    catch
        throw Exception("Could not read " . CD_Q(path))
    map := {}
    count := 0
    pos := 1
    fields := ["ExpansionID", "expansionID", "expansionId", "ExpansionId", "pack", "Pack"]
    while (pos := RegExMatch(text, "S)""([^""\\]+)""\s*:\s*\{([^{}]*)\}", m, pos)) {
        pos += StrLen(m)
        count += 1
        expansion := ""
        for _, field in fields {
            expansion := CardMap_BodyStr(m2, field)
            if (expansion != "")
                break
        }
        if (expansion = "")
            continue
        map["k" . m1] := expansion
        for _, field in ["CardID", "cardID", "cardId", "id", "ID"] {
            id := CardMap_BodyStr(m2, field)
            if (id != "")
                map["k" . id] := expansion
        }
    }
    if (!count) {
        ; Not the flat {"id": {...}} layout - do the generic (slow) walk.
        try value := Json_Parse(text)
        catch
            throw Exception("Could not parse cardmap.json at " . CD_Q(path))
        CD_CollectCardmapEntries(map, value)
    }
    cache := {}
    cache[cacheKey] := map
    return map
}

CD_InsertCardmapEntry(map, key, value) {
    if (J_IsStr(value)) {
        if (value != "" && key != "")
            map["k" . key] := value
        return
    }
    if (!J_IsObj(value))
        return
    expansion := ""
    for _, field in ["ExpansionID", "expansionID", "expansionId", "ExpansionId", "pack", "Pack"] {
        expansion := J_Str(value.Get(field), "")
        if (expansion != "")
            break
    }
    if (expansion = "")
        return
    if (key != "")
        map["k" . key] := expansion
    for _, field in ["CardID", "cardID", "cardId", "id", "ID"] {
        id := J_Str(value.Get(field), "")
        if (id != "")
            map["k" . id] := expansion
    }
}

CD_CollectCardmapEntries(map, value) {
    if (J_IsObj(value)) {
        for _, key in value.Keys() {
            entry := value.Get(key)
            CD_InsertCardmapEntry(map, key, entry)
            if (J_IsArr(entry))
                CD_CollectCardmapEntries(map, entry)
        }
    } else if (J_IsArr(value)) {
        for _, entry in value {
            CD_InsertCardmapEntry(map, "", entry)
            CD_CollectCardmapEntries(map, entry)
        }
    }
}

; load_cardmap_for_cards
CD_LoadCardmapForCards(cards) {
    path := CD_EnsureCardmap()
    map := CD_ParseCardmap(path)
    missing := false
    for _, card in cards
        if (!map.HasKey("k" . card))
            missing := true
    if (missing && !CardMap_IsFresh(path)) {
        CD_Log("cardmap missing requested card id; refreshing stale cardmap.json")
        CD_DownloadCardmap(path, true)
        map := CD_ParseCardmap(path)
    }
    return map
}

;===============================================================================
; ensure-metadata / merge-metadata
;===============================================================================

CD_AccountFilesExist() {
    dir := CD_AccountDir()
    if (!File_IsDir(dir))
        return false
    Loop, Files, %dir%\*, F
        if (Path_Ext(A_LoopFileName) = "json")
            return true
    return false
}

CD_WalkXmlFiles(dir, out) {
    if (!File_IsDir(dir))
        return
    for _, path in Dir_List(dir, "FD") {
        if (File_IsDir(path))
            CD_WalkXmlFiles(path, out)
        else if (Path_Ext(path) = "xml")
            out.Push(path)
    }
}

CD_ArchiveLegacyMetadata(path) {
    if (!File_Exists(path))
        return
    File_Rename(path, Path_Dir(path) . "\metadata.json.migrated_" . A_Now)
}

CD_ScanSavedXmlsIntoStore(store) {
    accounts := store.Get("accounts")
    xmls := []
    CD_WalkXmlFiles(CD_SavedDir(), xmls)
    for _, path in xmls {
        fileName := Path_Name(path)
        instance := Path_Name(Path_Dir(path))
        if (instance = "tmp")
            continue
        device := CD_ExtractDeviceAccountFromXml(path)
        key := (device = "") ? "legacy:" . instance . "/" . fileName : device

        patch := CD_NewAccount(instance, fileName, path)
        existed := accounts.Has(key)
        if (!existed)
            accounts.Set(key, new JObj)
        base := accounts.Get(key)
        hasPack := CD_FieldI64(base, "packCount", existingPack) && existingPack > 0
        hasCreated := J_IsObj(base) && base.Has("createdAt") && CD_NormalizeCreatedAt(base.Get("createdAt"), existingCreated)
        existingLast := J_IsObj(base) ? base.Get("lastPackPulled") : ""
        hasLast := J_IsObj(base) && base.Has("lastPackPulled") && !CD_ValueIsZeroish(existingLast)
        if (hasLast)
            existingLast := J_Clone(existingLast)

        base := CD_MergeAccount(base, patch)
        accounts.Set(key, base)
        if (existed) {
            if (hasPack)
                base.Set("packCount", existingPack + 0)
            else
                base.Set("packCount", CD_InitialPackCount(fileName) + 0)
            base.Set("createdAt", hasCreated ? existingCreated : CD_InitialCreatedAt(fileName))
            if (hasLast)
                base.Set("lastPackPulled", existingLast)
        }
        base.Set("instance", instance)
        base.Set("fileName", fileName)
        base.Delete("deviceAccount")
    }
}

; write_account_metadata
CD_WriteAccountMetadata(deviceAccount, metadata) {
    doc := CD_LoadAccountDocument(CD_AccountPath(deviceAccount), deviceAccount)
    metadata := J_Clone(metadata)
    CD_CompactAccountForWrite(metadata)
    doc.Set("metadata", metadata)
    CD_WriteAccountDocument(deviceAccount, doc)
}

CD_WriteAccountFilesFromStore(store) {
    accounts := store.Get("accounts")
    if (!J_IsObj(accounts))
        return
    for _, key in accounts.Keys() {
        if (S_StartsWith(key, "legacy:"))
            continue
        CD_WriteAccountMetadata(key, accounts.Get(key))
    }
}

; ensure_metadata. Returns the legacy store (empty when account files exist).
CD_EnsureMetadata() {
    hadAccountFiles := CD_AccountFilesExist()
    metadataPath := CD_LegacyMetadataPath()
    legacyMetadataExists := File_Exists(metadataPath) && File_Size(metadataPath) > 0
    legacyDb := CD_CardsDir() . "\Card_Database.csv"
    legacyDbExists := File_Exists(legacyDb) && File_Size(legacyDb) > 0
    showProgress := !hadAccountFiles || legacyMetadataExists || legacyDbExists

    if (showProgress)
        CD_MigrationProgress(1, "Preparing account data migration")
    if (showProgress && legacyDbExists)
        CD_MigrationProgress(15, "Importing legacy card database")
    CD_MergeCardDb()

    if (CD_AccountFilesExist()) {
        if (legacyMetadataExists) {
            if (showProgress)
                CD_MigrationProgress(90, "Archiving legacy metadata")
            CD_ArchiveLegacyMetadata(metadataPath)
        }
        if (showProgress)
            CD_MigrationProgress(100, "Account data migration complete")
        return CD_NewStore()
    }

    if (File_Exists(metadataPath) && File_Size(metadataPath) > 0) {
        if (showProgress)
            CD_MigrationProgress(35, "Reading legacy metadata")
        store := CD_LoadStore(metadataPath)
    } else {
        store := CD_NewStore()
    }

    if (showProgress)
        CD_MigrationProgress(55, "Scanning saved XML files")
    CD_ScanSavedXmlsIntoStore(store)
    if (showProgress)
        CD_MigrationProgress(80, "Writing account files")
    CD_WriteAccountFilesFromStore(store)
    if (showProgress)
        CD_MigrationProgress(95, "Archiving legacy metadata")
    CD_ArchiveLegacyMetadata(metadataPath)
    if (showProgress)
        CD_MigrationProgress(100, "Account data migration complete")
    return store
}

CD_MergeMetadata() {
    store := CD_EnsureMetadata()
    CD_WriteAccountFilesFromStore(store)
}

;===============================================================================
; Scheduling (schedule-accounts)
;===============================================================================

; parse_local + hours_since
CD_HoursSince(ts) {
    if (ts = "" || ts == "0" || !Ts_IsValid(ts))
        return 999999
    utc := Ts_LocalToUtc(ts)
    if (utc = "")
        return 999999
    return Ts_TruncDiv(Ts_Diff(A_NowUTC, utc), 3600)
}

CD_DaysSince(ts) {
    return Ts_TruncDiv(CD_HoursSince(ts), 24)
}

CD_RenameAccountEligible(account) {
    createdAt := CD_FieldStr(account, "createdAt")
    if (createdAt != "0" && createdAt != "" && CD_DaysSince(createdAt) < 31)
        return false
    lastRenamed := CD_FieldStr(account, "lastRenamedAt")
    if (lastRenamed != "0" && lastRenamed != "" && CD_DaysSince(lastRenamed) < 31)
        return false
    return true
}

CD_CurrentDailyResetUtc() {
    now := A_NowUTC
    reset := SubStr(now, 1, 8) . "060000"
    if (S_Cmp(now, reset) < 0)
        reset := Ts_Add(reset, -1, "Days")
    return reset
}

CD_WasAfterDailyReset(ts) {
    if (ts = "" || ts == "0" || !Ts_IsValid(ts))
        return false
    utc := Ts_LocalToUtc(ts)
    return utc != "" && S_Cmp(utc, CD_CurrentDailyResetUtc()) >= 0
}

CD_FlagIsExpired(account, name, hoursValid) {
    if (!CD_FlagValue(account, name))
        return true
    validUntil := CD_FlagStr(account, name, "validUntil")
    if (validUntil != "")
        return S_Cmp(A_Now, validUntil) >= 0
    setAt := CD_FlagStr(account, name, "setAt")
    if (setAt = "")
        return false
    return CD_HoursSince(setAt) >= hoursValid
}

CD_TFlagBlocks(account) {
    return CD_FlagValue(account, "T") && !CD_FlagIsExpired(account, "T", 5 * 24)
}

CD_ShinedustUpdatedAt(account) {
    shinedust := J_IsObj(account) ? account.Get("shinedust") : ""
    return J_IsObj(shinedust) ? J_Str(shinedust.Get("lastUpdatedAt"), "0") : "0"
}

CD_SpecialEventGameDayKey(ts, expiryTime) {
    if (ts = "" || ts == "0") {
        utc := A_NowUTC
    } else {
        if (!Ts_IsValid(ts))
            return ""
        utc := Ts_LocalToUtc(ts)
        if (utc = "")
            return ""
    }
    cutoff := (StrLen(expiryTime) = 6) ? expiryTime : "055959"
    if (S_Cmp(SubStr(utc, 9, 6), cutoff) >= 0)
        return SubStr(Ts_Add(SubStr(utc, 1, 8), 1, "Days"), 1, 8)
    return SubStr(utc, 1, 8)
}

CD_SpecialEventIsSameGameDay(lastClaimAt, expiryTime) {
    if (lastClaimAt = "" || lastClaimAt == "0")
        return false
    a := CD_SpecialEventGameDayKey(lastClaimAt, expiryTime)
    b := CD_SpecialEventGameDayKey("", expiryTime)
    return a != "" && S_Eq(a, b)
}

CD_SpecialEventProgress(account, eventName) {
    events := J_IsObj(account) ? account.Get("specialEvents") : ""
    return J_IsObj(events) ? events.Get(eventName) : ""
}

CD_NeedsSpecialMissionClaim(account, activeEvents) {
    for _, event in activeEvents {
        progress := CD_SpecialEventProgress(account, event.name)
        count := 0
        lastClaim := ""
        if (J_IsObj(progress)) {
            if (!J_IntOrParsed(progress.Get("claimCount"), count))
                count := 0
            lastClaim := J_Str(progress.Get("lastClaimAt"), "")
        }
        if (count < event.claim_steps && !CD_SpecialEventIsSameGameDay(lastClaim, event.expiry_time))
            return true
    }
    return false
}

CD_ParseSpecialEventFile(path) {
    try content := File_ReadUtf8(path)
    catch
        return ""
    inTarget := false
    name := "", expiryDate := "", expiryTime := "", claimSteps := "", maxClaims := ""
    Loop, Parse, content, `n
    {
        line := LTrim(S_Trim(RTrim(A_LoopField, "`r")), Chr(0xFEFF))
        if (SubStr(line, 1, 1) = "[" && SubStr(line, 0) = "]") {
            inTarget := (SubStr(line, 2, -1) = "TargetInfo")
            continue
        }
        if (!inTarget || line = "" || SubStr(line, 1, 1) = ";")
            continue
        p := InStr(line, "=")
        if (!p)
            continue
        key := S_Trim(SubStr(line, 1, p - 1))
        value := S_Trim(SubStr(line, p + 1))
        if (key = "EventName")
            name := value
        else if (key = "ExpiryDate")
            expiryDate := value
        else if (key = "ExpiryTime")
            expiryTime := value
        else if (key = "ClaimSteps")
            claimSteps := RegExMatch(value, "^[+-]?\d{1,18}$") ? value + 0 : ""
        else if (key = "MaxClaims")
            maxClaims := RegExMatch(value, "^[+-]?\d{1,18}$") ? value + 0 : ""
    }
    if (name = "" || StrLen(expiryDate) != 8 || StrLen(expiryTime) != 6)
        return ""
    expiry := expiryDate . expiryTime
    if (!Ts_IsValid(expiry))
        return ""
    if (S_Cmp(A_NowUTC, Ts_Add(expiry, -5, "Minutes")) > 0)
        return ""
    steps := (claimSteps != "") ? claimSteps : maxClaims
    if (steps = "" || steps < 1)
        steps := 1
    return {name: name, claim_steps: steps, expiry_time: expiryTime}
}

CD_ActiveSpecialEvents() {
    events := []
    for _, path in Dir_ListExt(CD_ROOT . "\SpecialEvents\Events", "sevt") {
        event := CD_ParseSpecialEventFile(path)
        if (IsObject(event))
            events.Push(event)
    }
    return events
}

CD_InjectRewardsEligible(account, options, activeEvents) {
    doShinedust := options.ocr_shinedust && options.s4t_enabled
    if (!options.wonderpick_for_event_missions && !options.claim_daily_mission
        && !options.claim_special_missions && !options.receive_gift && !doShinedust)
        return !CD_WasAfterDailyReset(CD_FieldStr(account, "lastLoggedIn"))

    return (options.wonderpick_for_event_missions && CD_FlagIsExpired(account, "W", 24))
        || (options.claim_daily_mission && !CD_WasAfterDailyReset(CD_FieldStr(account, "lastLoggedIn")))
        || (options.claim_special_missions && CD_NeedsSpecialMissionClaim(account, activeEvents))
        || (options.receive_gift && !CD_FlagValue(account, "R"))
        || (doShinedust && CD_HoursSince(CD_ShinedustUpdatedAt(account)) >= 24)
}

CD_InjectPackEligible(account, options) {
    method := options.delete_method
    if ((S_Eq(method, "Inject 13P+") || S_Eq(method, "Inject Wonderpick 96P+")) && CD_TFlagBlocks(account))
        return false
    if (S_Eq(method, "Inject 13P+") && options.spend_hourglass)
        return CD_FlagIsExpired(account, "SH", 24)
    lastPack := CD_FieldStr(account, "lastPackPulled")
    if (lastPack == "0" || lastPack = "")
        return true
    return CD_HoursSince(lastPack) >= 24
}

CD_Eligible(account, options, activeEvents) {
    if (options.force_inject && !CD_FlagValue(account, "FI"))
        return true
    method := options.delete_method
    if (S_Eq(method, "Create Bots (13P)"))
        return true
    if (S_Eq(method, "Rename Account"))
        return CD_RenameAccountEligible(account)
    if (S_Eq(method, "Inject Rewards"))
        return CD_InjectRewardsEligible(account, options, activeEvents)
    if (S_Eq(method, "Inject 13P+") || S_Eq(method, "Inject Wonderpick 96P+"))
        return CD_InjectPackEligible(account, options)
    return true
}

CD_PackCountAllowed(method, metadataAccount, resolvedPackCount, minPacks) {
    if (S_Eq(method, "Inject Wonderpick 96P+")) {
        if (IsObject(metadataAccount) && CD_FieldI64(metadataAccount, "packCount", pc) && pc > 0)
            return pc >= minPacks
        return true
    }
    maxPacks := S_Eq(method, "Inject Missions") ? 38 : 9999
    return resolvedPackCount >= 0 && resolvedPackCount <= maxPacks
}

CD_CleanupUsedAccountBackups(saveDir, keep := "") {
    if (!File_IsDir(saveDir))
        return
    for _, path in Dir_List(saveDir, "FD") {
        name := Path_Name(path)
        if (!S_StartsWith(name, "used_accounts_backup_") || !S_EndsWith(name, ".txt"))
            continue
        if (keep != "" && path = keep)
            continue
        try Path_Remove(path)
    }
}

; clean_used_accounts. Returns {used: JObj set, backup: path}.
CD_CleanUsedAccounts(saveDir, forceClear) {
    usedPath := saveDir . "\used_accounts.txt"
    if (forceClear) {
        backup := ""
        if (File_Exists(usedPath)) {
            backup := saveDir . "\used_accounts_backup_" . A_Now . ".txt"
            FileCopy, %usedPath%, %backup%, 1
            if (ErrorLevel)
                throw Exception("Could not copy " . CD_Q(usedPath))
            FileDelete, %usedPath%
        }
        CD_CleanupUsedAccountBackups(saveDir, backup)
        return {used: new JObj, backup: backup}
    }

    CD_CleanupUsedAccountBackups(saveDir)
    used := new JObj
    if (!File_Exists(usedPath))
        return {used: used, backup: ""}

    text := File_ReadUtf8(usedPath)
    cutoffUtc := Ts_Add(A_NowUTC, -24, "Hours")
    kept := ""
    Loop, Parse, text, `n
    {
        line := RTrim(A_LoopField, "`r")
        parts := StrSplit(line, "|")
        fileName := parts[1]
        timestamp := (parts.Length() >= 2) ? parts[2] : ""
        if (!File_Exists(saveDir . "\" . fileName))
            continue
        if (!Ts_IsValid(timestamp))
            continue
        utc := Ts_LocalToUtc(timestamp)
        if (utc != "" && S_Cmp(utc, cutoffUtc) > 0) {
            used.Set(fileName, true)
            kept .= line . "`n"
        }
    }
    File_WriteUtf8(usedPath, kept)
    return {used: used, backup: ""}
}

CD_RemoveUsedAccountsBackup(state) {
    if (state.backup != "")
        File_Delete(state.backup)
}

CD_AccountsForInstance(store, instance) {
    byFile := new JObj, byDevice := new JObj
    accounts := store.Get("accounts")
    if (J_IsObj(accounts)) {
        for _, key in accounts.Keys() {
            account := accounts.Get(key)
            if (!S_Eq(CD_FieldStr(account, "instance"), instance))
                continue
            fileName := CD_FieldStr(account, "fileName")
            if (fileName != "")
                byFile.Set(fileName, account)
            if (!S_StartsWith(key, "legacy:"))
                byDevice.Set(key, account)
        }
    }
    return {byFile: byFile, byDevice: byDevice}
}

CD_MetadataForXml(lookup, fileName, device) {
    if (device != "" && lookup.byDevice.Has(device))
        return lookup.byDevice.Get(device)
    if (lookup.byFile.Has(fileName))
        return lookup.byFile.Get(fileName)
    return ""
}

CD_UsedAccountMatches(used, fileName, device) {
    if (used.Has(fileName))
        return true
    if (device = "")
        return false
    plain := device . ".xml"
    prefixed := "_" . device . ".xml"
    for _, entry in used.Keys()
        if (S_Eq(entry, device) || S_Eq(entry, plain) || S_EndsWith(entry, prefixed))
            return true
    return false
}

Cmp_CandidateModifiedAsc(a, b) {
    return S_Cmp(a.sort_time, b.sort_time)
}

Cmp_CandidateModifiedDesc(a, b) {
    return S_Cmp(b.sort_time, a.sort_time)
}

Cmp_CandidatePacksAsc(a, b) {
    if (a.pack_count != b.pack_count)
        return (a.pack_count < b.pack_count) ? -1 : 1
    return S_Cmp(a.sort_time, b.sort_time)
}

Cmp_CandidatePacksDesc(a, b) {
    if (a.pack_count != b.pack_count)
        return (a.pack_count > b.pack_count) ? -1 : 1
    return S_Cmp(a.sort_time, b.sort_time)
}

Cmp_CandidateLastLoginAsc(a, b) {
    c := S_Cmp(a.last_login, b.last_login)
    return c ? c : S_Cmp(a.sort_time, b.sort_time)
}

CD_SortCandidates(candidates, sortMethod) {
    if (S_Eq(sortMethod, "ModifiedDesc"))
        fn := "Cmp_CandidateModifiedDesc"
    else if (S_Eq(sortMethod, "PacksAsc"))
        fn := "Cmp_CandidatePacksAsc"
    else if (S_Eq(sortMethod, "PacksDesc"))
        fn := "Cmp_CandidatePacksDesc"
    else if (S_Eq(sortMethod, "LastLoginAsc"))
        fn := "Cmp_CandidateLastLoginAsc"
    else
        fn := "Cmp_CandidateModifiedAsc"
    return Arr_Sort(candidates, Func(fn))
}

; Lazily loaded repair archive (device account -> archived account document).
class CD_RepairLookup {
    __New() {
        this.loaded := false
        this.archive := ""
    }

    Get(device) {
        if (S_Trim(device) = "")
            return ""
        if (!this.loaded) {
            this.loaded := true
            try this.archive := CD_LoadRepairArchive()
            catch
                this.archive := ""
        }
        if (!IsObject(this.archive))
            return ""
        return this.archive.GetDoc(device)
    }
}

CD_MetadataFromAccountDocument(doc) {
    metadata := J_IsObj(doc) ? doc.Get("metadata") : ""
    return J_IsObj(metadata) ? J_Clone(metadata) : new JObj
}

; account_metadata_for_schedule
CD_AccountMetadataForSchedule(instance, fileName, xmlPath, device, repair) {
    metadata := ""
    found := false
    if (device != "") {
        path := CD_AccountPath(device)
        if (File_Exists(path)) {
            found := CD_LoadAccountFileMetadata(path, metadata)
            if (!found) {
                archived := repair.Get(device)
                metadata := IsObject(archived) ? CD_MetadataFromAccountDocument(archived) : CD_NewAccount(instance, fileName, xmlPath)
                found := true
            }
        }
    }
    if (!found)
        metadata := CD_NewAccount(instance, fileName, xmlPath)
    if (J_IsObj(metadata)) {
        if (J_Str(metadata.Get("instance"), "") = "")
            metadata.Set("instance", instance)
        if (J_Str(metadata.Get("fileName"), "") = "")
            metadata.Set("fileName", fileName)
    }
    return metadata
}

CD_LoadStoreForInstanceSchedule(instance, xmlInfo) {
    store := CD_NewStore()
    accounts := store.Get("accounts")
    repair := new CD_RepairLookup
    for _, info in xmlInfo {
        metadata := CD_AccountMetadataForSchedule(instance, info.fileName, info.path, info.device, repair)
        key := (info.device != "") ? info.device : "legacy:" . instance . "/" . info.fileName
        accounts.Set(key, metadata)
    }
    return CD_EnsureStore(store)
}

; XML files of a save directory with their device accounts (read_dir order).
CD_ListInstanceXmls(saveDir) {
    out := []
    for _, path in Dir_ListExt(saveDir, "xml")
        out.Push({path: path, fileName: Path_Name(path), device: CD_ExtractDeviceAccountFromXml(path)})
    return out
}

CD_ScheduleAccounts(options) {
    instance := options.instance
    saveDir := CD_SavedDir() . "\" . instance
    xmlInfo := CD_ListInstanceXmls(saveDir)
    store := CD_LoadStoreForInstanceSchedule(instance, xmlInfo)
    activeEvents := CD_ActiveSpecialEvents()
    Dir_Create(saveDir)

    listPath := saveDir . "\list.txt"
    currentPath := saveDir . "\list_current.txt"
    lastGeneratedPath := saveDir . "\list_last_generated.txt"
    usedState := CD_CleanUsedAccounts(saveDir, options.force_clear_used)
    lookup := CD_AccountsForInstance(store, instance)
    candidates := []
    for _, info in xmlInfo {
        if (!File_Exists(info.path))
            continue
        if (!options.force_inject && !S_Eq(options.delete_method, "Rename Account")
            && CD_UsedAccountMatches(usedState.used, info.fileName, info.device))
            continue

        metadataAccount := CD_MetadataForXml(lookup, info.fileName, info.device)
        account := IsObject(metadataAccount) ? metadataAccount : CD_NewAccount(instance, info.fileName, info.path)
        if (!CD_Eligible(account, options, activeEvents))
            continue

        if (!CD_FieldI64(account, "packCount", packCount))
            packCount := CD_InitialPackCount(info.fileName)
        if ((!options.force_inject || CD_FlagValue(account, "FI"))
            && !CD_PackCountAllowed(options.delete_method, metadataAccount, packCount, options.inject_wonderpick_min_packs))
            continue

        sortTime := CD_FieldStr(account, "lastPackPulled")
        if (sortTime = "")
            sortTime := File_ModifiedLocal(info.path)
        lastLogin := CD_FieldStr(account, "lastLoggedIn")
        if (lastLogin = "")
            lastLogin := "0"
        candidates.Push({file_name: info.fileName, sort_time: sortTime, last_login: lastLogin, pack_count: packCount})
    }

    CD_SortCandidates(candidates, options.sort_method)
    list := ""
    for _, c in candidates
        list .= c.file_name . "`r`n"
    File_WriteUtf8(listPath, list)
    File_WriteUtf8(currentPath, list)
    File_WriteUtf8(lastGeneratedPath, A_Now)
    StdOut(candidates.Length())
    CD_RemoveUsedAccountsBackup(usedState)
}

;===============================================================================
; balance-xmls
;===============================================================================

CD_CountEligibleForAllInstances(store, instances, options) {
    total := 0
    activeEvents := CD_ActiveSpecialEvents()
    Loop, %instances% {
        instanceName := "" . A_Index
        saveDir := CD_SavedDir() . "\" . instanceName
        if (!File_IsDir(saveDir))
            continue
        usedState := CD_CleanUsedAccounts(saveDir, false)
        lookup := CD_AccountsForInstance(store, instanceName)
        for _, path in Dir_ListExt(saveDir, "xml") {
            fileName := Path_Name(path)
            device := CD_ExtractDeviceAccountFromXml(path)
            if (!options.force_inject && !S_Eq(options.delete_method, "Rename Account")
                && CD_UsedAccountMatches(usedState.used, fileName, device))
                continue
            metadataAccount := CD_MetadataForXml(lookup, fileName, device)
            account := IsObject(metadataAccount) ? metadataAccount : CD_NewAccount(instanceName, fileName, path)
            if (!CD_Eligible(account, options, activeEvents))
                continue
            if (!CD_FieldI64(account, "packCount", packCount))
                packCount := CD_InitialPackCount(fileName)
            if ((options.force_inject && !CD_FlagValue(account, "FI"))
                || CD_PackCountAllowed(options.delete_method, metadataAccount, packCount, options.inject_wonderpick_min_packs))
                total += 1
        }
    }
    return total
}

; move_replace
CD_MoveReplace(from, to) {
    try Path_Remove(to)
    catch e
        throw Exception("Could not prepare destination " . CD_Q(to) . ": " . e.Message)
    Dir_Create(Path_Dir(to))
    try File_Rename(from, to)
    catch e
        throw Exception("Could not move " . CD_Q(from) . " to " . CD_Q(to) . ": " . e.Message)
}

CD_StripBalanceStagingPrefix(fileName) {
    current := fileName
    while (StrLen(current) > 9) {
        p := InStr(current, "_", true)
        if (!p)
            break
        prefix := SubStr(current, 1, p - 1)
        rest := SubStr(current, p + 1)
        if (StrLen(prefix) != 8 || !S_IsDigits(prefix) || rest = "")
            break
        current := rest
    }
    return current
}

CD_CollectXmlsForBalance(saveDir, stagingDir, out) {
    if (!File_IsDir(saveDir))
        return
    Dir_Create(stagingDir)
    CD_Log("collect_xmls_for_balance started; save_dir=" . CD_Q(saveDir) . "; staging_dir=" . CD_Q(stagingDir))
    stack := [saveDir]
    counter := 0
    while (stack.Length()) {
        dir := stack.Pop()
        CD_Log("collect_xmls_for_balance scanning " . CD_Q(dir))
        for _, path in Dir_List(dir, "FD") {
            if (File_IsDir(path)) {
                if (!Path_IsWithin(path, stagingDir))
                    stack.Push(path)
                continue
            }
            if (Path_Ext(path) != "xml")
                continue
            if (Path_IsWithin(path, stagingDir))
                continue
            fileName := CD_StripBalanceStagingPrefix(Path_Name(path))
            counter += 1
            stagingPath := stagingDir . "\" . Format("{:08}", counter) . "_" . fileName
            try CD_MoveReplace(path, stagingPath)
            catch e
                throw Exception("Failed while staging XML #" . counter . ": source=" . CD_Q(path) . ", staging=" . CD_Q(stagingPath) . ": " . e.Message)
            out.Push({fileName: fileName, path: stagingPath})
        }
    }
    CD_Log("collect_xmls_for_balance completed; staged=" . counter)
}

; unique_balance_file_names
CD_UniqueBalanceFileNames(xmls) {
    reserved := {}
    for _, x in xmls
        reserved["k" . S_Lower(x.fileName)] := true
    emitted := {}
    out := []
    for _, x in xmls {
        lower := "k" . S_Lower(x.fileName)
        if (!emitted.HasKey(lower)) {
            emitted[lower] := true
            out.Push({original: x.fileName, fileName: x.fileName, path: x.path})
            continue
        }
        stem := Path_Stem(x.fileName)
        ext := Path_Ext(x.fileName)
        suffix := 2
        Loop {
            candidate := stem . "_" . suffix . (ext != "" ? "." . ext : "")
            ck := "k" . S_Lower(candidate)
            if (!reserved.HasKey(ck)) {
                reserved[ck] := true
                emitted[ck] := true
                out.Push({original: x.fileName, fileName: candidate, path: x.path})
                break
            }
            suffix += 1
        }
    }
    return out
}

CD_PackCountsByFile(store) {
    result := new JObj
    accounts := store.Get("accounts")
    if (!J_IsObj(accounts))
        return result
    for _, key in accounts.Keys() {
        account := accounts.Get(key)
        fileName := CD_FieldStr(account, "fileName")
        if (fileName = "")
            continue
        if (!CD_FieldI64(account, "packCount", pc))
            pc := CD_InitialPackCount(fileName)
        result.Set(fileName, pc)
    }
    return result
}

CD_LoadAccountFilesForXmls(xmls) {
    repair := new CD_RepairLookup
    store := CD_NewStore()
    accounts := store.Get("accounts")
    seen := new JObj
    for _, x in xmls {
        device := CD_ExtractDeviceAccountFromXml(x.path)
        if (device = "" || seen.Has(device))
            continue
        seen.Set(device, true)
        path := CD_AccountPath(device)
        metadata := ""
        if (!(File_Exists(path) && CD_LoadAccountFileMetadata(path, metadata))) {
            archived := repair.Get(device)
            metadata := IsObject(archived) ? CD_MetadataFromAccountDocument(archived) : CD_NewAccount("", x.fileName, x.path)
        }
        accounts.Set(device, metadata)
    }
    return CD_EnsureStore(store)
}

; update_metadata_instance
CD_UpdateMetadataInstance(store, fileName, instance, filePath) {
    device := CD_ExtractDeviceAccountFromXml(filePath)
    accounts := store.Get("accounts")
    key := device
    if (key = "") {
        for _, k in accounts.Keys() {
            if (S_Eq(CD_FieldStr(accounts.Get(k), "fileName"), fileName)) {
                key := k
                break
            }
        }
        if (key = "")
            key := "legacy:" . instance . "/" . fileName
    }
    if (accounts.Has(key)) {
        account := accounts.Get(key)
        accounts.Delete(key)
    } else {
        account := CD_NewAccount("" . instance, fileName, filePath)
    }
    hasCreated := J_IsObj(account) && account.Has("createdAt") && CD_NormalizeCreatedAt(account.Get("createdAt"), created)
    if (J_IsObj(account)) {
        account.Delete("deviceAccount")
        account.Set("instance", "" . instance)
        account.Set("fileName", fileName)
        if (!account.Has("packCount"))
            account.Set("packCount", CD_InitialPackCount(fileName) + 0)
        account.Set("createdAt", hasCreated ? created : CD_InitialCreatedAt(fileName))
    }
    accounts.Set(CD_AccountKey(key, account), account)
}

Cmp_BalanceFiles(a, b) {
    if (a.packCount != b.packCount)
        return (a.packCount > b.packCount) ? -1 : 1
    return S_Cmp(a.fileName, b.fileName)
}

CD_BalanceXmls(instances, options) {
    CD_Log("balance_xmls entered; instances=" . instances . "; delete_method=" . options.delete_method . "; sort_method=" . options.sort_method)
    if (instances = 0) {
        CD_Log("balance_xmls skipped because instances=0")
        return
    }

    CD_BalanceProgress(1, "Preparing XML balance")
    saveDir := CD_SavedDir()
    tmpDir := saveDir . "\tmp"
    stagingDir := tmpDir . "\balance_" . A_Now
    CD_Log("balance_xmls preparing directories; save_dir=" . CD_Q(saveDir) . "; tmp_dir=" . CD_Q(tmpDir) . "; staging_dir=" . CD_Q(stagingDir))
    Dir_Create(saveDir)
    Dir_Create(tmpDir)

    CD_BalanceProgress(5, "Importing staged card rows")
    CD_Log("balance_xmls merging card database")
    try CD_MergeCardDb()
    catch e
        throw Exception("Failed while importing staged card rows: " . e.Message)

    Loop, %instances% {
        instanceDir := saveDir . "\" . A_Index
        Dir_Create(instanceDir)
        File_Delete(instanceDir . "\list.txt")
        File_Delete(instanceDir . "\list_current.txt")
    }

    CD_BalanceProgress(20, "Collecting XML files")
    xmls := []
    try CD_CollectXmlsForBalance(saveDir, stagingDir, xmls)
    catch e
        throw Exception("Failed while collecting XML files for balance: " . e.Message)
    CD_Log("balance_xmls collected " . xmls.Length() . " XML files")

    CD_BalanceProgress(28, "Reading metadata for balanced XMLs")
    if (CD_AccountFilesExist() && !File_Exists(CD_LegacyMetadataPath())) {
        CD_Log("balance_xmls loading per-account metadata files")
        try store := CD_LoadAccountFilesForXmls(xmls)
        catch e
            throw Exception("Failed while loading account metadata for XMLs: " . e.Message)
    } else {
        CD_Log("balance_xmls ensuring account metadata")
        try store := CD_EnsureMetadata()
        catch e
            throw Exception("Failed while ensuring account metadata: " . e.Message)
    }
    packCounts := CD_PackCountsByFile(store)

    CD_BalanceProgress(35, "Resolving duplicate XML filenames")
    files := []
    for _, x in CD_UniqueBalanceFileNames(xmls) {
        pc := packCounts.Has(x.original) ? packCounts.Get(x.original) : CD_InitialPackCount(x.original)
        files.Push({packCount: pc, fileName: x.fileName, path: x.path})
    }
    Arr_Sort(files, Func("Cmp_BalanceFiles"))

    CD_BalanceProgress(50, "Distributing XML files")
    totalFiles := Max(files.Length(), 1)
    instance := 1
    for index0, f in files {
        index := index0 - 1
        dest := saveDir . "\" . instance . "\" . f.fileName
        try CD_MoveReplace(f.path, dest)
        catch e
            throw Exception("Failed while distributing XML index=" . index . ", file_name=" . f.fileName . ", source=" . CD_Q(f.path) . ", destination=" . CD_Q(dest) . ": " . e.Message)
        CD_UpdateMetadataInstance(store, f.fileName, instance, dest)
        if (Mod(index, 50) = 0)
            CD_BalanceProgress(50 + ((index + 1) * 30) // totalFiles, "Distributing XML files")
        instance += 1
        if (instance > instances)
            instance := 1
    }

    CD_BalanceProgress(82, "Writing account metadata")
    CD_Log("balance_xmls writing account metadata files")
    try CD_WriteAccountFilesFromStore(store)
    catch e
        throw Exception("Failed while writing account metadata: " . e.Message)

    CD_BalanceProgress(92, "Counting eligible XML files")
    CD_Log("balance_xmls counting eligible XML files")
    try eligibleNow := CD_CountEligibleForAllInstances(store, instances, options)
    catch e
        throw Exception("Failed while counting eligible XML files: " . e.Message)

    File_WriteUtf8(saveDir . "\balance_result.txt", eligibleNow . "`n")
    try Path_Remove(stagingDir)
    CD_BalanceProgress(100, "XML balance complete")
    CD_Log("balance_xmls completed; eligible_now=" . eligibleNow)
    StdOut(eligibleNow)
}

;===============================================================================
; extract-metadata
;===============================================================================

CD_FindAccount(store, device, instance, fileName, key, hasDevice, hasInstance, hasFile, hasKey) {
    accounts := store.Get("accounts")
    if (!J_IsObj(accounts))
        return ""
    if (hasKey && accounts.Has(key))
        return {key: key, account: accounts.Get(key)}
    if (hasDevice) {
        if (accounts.Has(device))
            return {key: device, account: accounts.Get(device)}
        if (accounts.Has("deviceAccount:" . device))
            return {key: device, account: accounts.Get("deviceAccount:" . device)}
    }
    for _, candidateKey in accounts.Keys() {
        account := accounts.Get(candidateKey)
        keyDevice := S_StartsWith(candidateKey, "deviceAccount:") ? SubStr(candidateKey, 15) : candidateKey
        candidateDevice := J_IsObj(account) ? J_Str(account.Get("deviceAccount"), keyDevice) : keyDevice
        if (hasDevice && S_Eq(candidateDevice, device))
            return {key: CD_AccountKey(candidateKey, account), account: account}
        if (hasInstance && hasFile && J_IsObj(account)) {
            ci := account.Get("instance"), cf := account.Get("fileName")
            if (J_IsStr(ci) && J_IsStr(cf) && S_Eq(ci, instance) && S_Eq(cf, fileName))
                return {key: CD_AccountKey(candidateKey, account), account: account}
        }
    }
    return ""
}

; write_store
CD_WriteStore(path, store) {
    Dir_Create(Path_Dir(path))
    output := CD_EnsureStore(J_Clone(store))
    accounts := output.Get("accounts")
    for _, key in accounts.Keys()
        CD_CompactAccountForWrite(accounts.Get(key))
    text := Json_Dump(output, true) . "`n"
    File_WriteAtomic(path, text, Path_WithExt(path, "json.tmp"))
}

CD_ExtractMetadata(device, instance, fileName, key, output, hasDevice, hasInstance, hasFile, hasKey) {
    store := CD_EnsureMetadata()
    out := CD_NewStore()
    found := CD_FindAccount(store, device, instance, fileName, key, hasDevice, hasInstance, hasFile, hasKey)
    if (IsObject(found))
        out.Get("accounts").Set(found.key, J_Clone(found.account))
    CD_WriteStore(CD_ArgPath(output), out)
}

;===============================================================================
; clear-flag / clear-pull-history
;===============================================================================

CD_SortedAccountJsonPaths() {
    paths := Dir_ListExt(CD_AccountDir(), "json")
    names := []
    for _, path in paths
        names.Push(path)
    return Arr_Sort(names, Func("Cmp_Ordinal"))
}

CD_ClearFlag(flag) {
    dir := CD_AccountDir()
    changed := 0
    if (File_IsDir(dir)) {
        CD_ClearFlagProgress(1, "Preparing reset")
        paths := CD_SortedAccountJsonPaths()
        total := Max(paths.Length(), 1)
        CD_ClearFlagProgress(5, "Scanning account files")
        for i, path in paths {
            index := i - 1
            fallback := Path_Stem(path)
            doc := CD_LoadAccountDocument(path, fallback)
            metadata := doc.Get("metadata")
            if (J_IsObj(metadata)) {
                accountChanged := false
                flags := metadata.Get("flags")
                if (J_IsObj(flags)) {
                    f := flags.Get(flag)
                    if (J_IsObj(f) && f.Has("value") && CD_ValueTruthy(f.Get("value"))) {
                        flags.Delete(flag)
                        if (flags.Count() = 0)
                            metadata.Delete("flags")
                        accountChanged := true
                    }
                }
                if (S_Eq(flag, "X") && metadata.Delete("specialEvents"))
                    accountChanged := true
                if (accountChanged) {
                    device := J_Str(doc.Get("deviceAccount"), fallback)
                    CD_WriteAccountDocument(device, doc)
                    changed += 1
                }
            }
            if (Mod(index, 50) = 0)
                CD_ClearFlagProgress(5 + ((index + 1) * 90) // total, "Resetting account status")
        }
    }
    Dir_Create(CD_SavedDir())
    File_WriteUtf8(CD_SavedDir() . "\clear_flag_result.txt", changed . "`n")
    CD_ClearFlagProgress(100, "Reset complete")
    StdOut(changed)
}

; clear_pull_history_document
CD_ClearPullHistoryDocument(doc) {
    changed := false
    metadata := doc.Get("metadata")
    if (J_IsObj(metadata)) {
        flags := metadata.Get("flags")
        if (J_IsObj(flags)) {
            if (flags.Delete("H"))
                changed := true
            if (flags.Count() = 0)
                metadata.Delete("flags")
        }
    }
    pulls := doc.Peek("pulls")
    if (IsObject(pulls) && pulls.__Class = "JRaw") {
        isArray := SubStr(pulls.raw, 1, 1) = "["
        hasEntries := isArray && !RegExMatch(pulls.raw, "^\[\s*\]$")
    } else {
        isArray := doc.Has("pulls") && J_IsArr(pulls)
        hasEntries := isArray && pulls.Length() > 0
    }
    if (hasEntries || !isArray) {
        doc.Set("pulls", [])
        changed := true
    }
    return changed
}

CD_ClearPullHistory() {
    dir := CD_AccountDir()
    changed := 0
    CD_ClearFlagProgress(1, "Preparing reset")
    if (File_IsDir(dir)) {
        paths := CD_SortedAccountJsonPaths()
        total := Max(paths.Length(), 1)
        CD_ClearFlagProgress(5, "Scanning account files")
        for i, path in paths {
            index := i - 1
            fallback := Path_Stem(path)
            doc := CD_LoadAccountDocument(path, fallback)
            if (CD_ClearPullHistoryDocument(doc)) {
                device := J_Str(doc.Get("deviceAccount"), fallback)
                CD_WriteAccountDocument(device, doc)
                changed += 1
            }
            if (Mod(index, 50) = 0)
                CD_ClearFlagProgress(5 + ((index + 1) * 90) // total, "Clearing pull history")
        }
    }
    Dir_Create(CD_SavedDir())
    File_WriteUtf8(CD_SavedDir() . "\clear_flag_result.txt", changed . "`n")
    CD_ClearFlagProgress(100, "Reset complete")
    StdOut(changed)
}

;===============================================================================
; Pull timestamps and history import
;===============================================================================

; parse_pull_timestamp -> UTC YYYYMMDDHH24MISS, "" when invalid.
CD_ParsePullTimestamp(timestamp) {
    timestamp := S_Trim(timestamp)
    if (timestamp = "" || timestamp == "0")
        return ""
    if (S_IsDigits(timestamp)) {
        if (StrLen(timestamp) = 14)
            return Ts_IsValid(timestamp) ? Ts_LocalToUtc(timestamp) : ""
        if (StrLen(LTrim(timestamp, "0")) <= 18)
            return Ts_FromUnix(timestamp + 0)
    }
    if (RegExMatch(timestamp, "^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:([Zz])|([+-])(\d{2}):(\d{2}))$", m)) {
        wall := m1 . m2 . m3 . m4 . m5 . m6
        if (!Ts_IsValid(wall))
            return ""
        if (m7 != "")
            return wall
        offset := (m9 * 60 + m10) * 60
        return Ts_Add(wall, (m8 = "+") ? -offset : offset, "Seconds")
    }
    if (RegExMatch(timestamp, "^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$", m)) {
        wall := m1 . m2 . m3 . m4 . m5 . m6
        return Ts_IsValid(wall) ? Ts_LocalToUtc(wall) : ""
    }
    return ""
}

; UTC timestamp -> local "YYYY-MM-DD HH:MM:SS"
CD_FormatPullTimestamp(utc) {
    t := Ts_UtcToLocal(utc)
    return SubStr(t, 1, 4) . "-" . SubStr(t, 5, 2) . "-" . SubStr(t, 7, 2) . " "
        . SubStr(t, 9, 2) . ":" . SubStr(t, 11, 2) . ":" . SubStr(t, 13, 2)
}

CD_NormalizePullTimestamp(timestamp) {
    utc := CD_ParsePullTimestamp(timestamp)
    return (utc != "") ? CD_FormatPullTimestamp(utc) : ""
}

; Day of a UTC timestamp with the 06:00 UTC daily reset as boundary. Depends only
; on the UTC date and hour, so results are cached per hour.
CD_HistoryDayKey(utc) {
    static cache := {}
    hour := "h" . SubStr(utc, 1, 10)
    if (!cache.HasKey(hour)) {
        t := Ts_Add(utc, -6, "Hours")
        cache[hour] := SubStr(t, 1, 4) . "-" . SubStr(t, 5, 2) . "-" . SubStr(t, 7, 2)
    }
    return cache[hour]
}

; Day keys (and, for in-depth imports, "day|card" occurrence counts) of the
; existing pulls. Reads the unparsed pull text with regexes when possible, so
; long histories are not turned into objects. Pull objects only hold strings
; and a flat "cards" array; anything else falls back to the parsed objects.
CD_ScanPullHistory(doc, wantCards) {
    static reString := """((?:[^""\\]|\\.)*)"""
    result := {days: {}, counts: {}}
    raw := doc.Peek("pulls")
    if (IsObject(raw) && raw.__Class = "JRaw") {
        text := raw.raw
        StrReplace(text, "{", "", opens)
        pos := 1
        found := 0
        while (pos := RegExMatch(text, "S)\{([^{}]*)\}", m, pos)) {
            pos += StrLen(m)
            found += 1
            if (!RegExMatch(m1, "S)""timestamp""\s*:\s*(""[^""\\]*+(?:\\.[^""\\]*+)*+"")", ts))
                continue
            utc := CD_ParsePullTimestamp(Json__Unescape(ts1))
            if (utc = "")
                continue
            day := CD_HistoryDayKey(utc)
            result.days[day] := true
            if (!wantCards || !RegExMatch(m1, "S)""cards""\s*:\s*\[([^\[\]]*)\]", cards))
                continue
            p := 1
            while (p := RegExMatch(cards1, "S)" . reString, c, p)) {
                p += StrLen(c)
                k := day . "|" . Json__Unescape(c)
                result.counts[k] := (result.counts.HasKey(k) ? result.counts[k] : 0) + 1
            }
        }
        if (found = opens)
            return result
        result := {days: {}, counts: {}}
    }
    result.days := CD_PullHistoryDayKeys(doc)
    if (wantCards)
        result.counts := CD_PullHistoryCardCounts(doc)
    return result
}

CD_PullHistoryDayKeys(doc) {
    keys := {}
    pulls := doc.Get("pulls")
    if (!J_IsArr(pulls))
        return keys
    for _, pull in pulls {
        if (!J_IsObj(pull))
            continue
        if (!J_IsStr(pull.Get("timestamp")))
            continue
        utc := CD_ParsePullTimestamp(pull.Get("timestamp"))
        if (utc != "")
            keys[CD_HistoryDayKey(utc)] := true
    }
    return keys
}

CD_PullHistoryCardCounts(doc) {
    counts := {}
    pulls := doc.Get("pulls")
    if (!J_IsArr(pulls))
        return counts
    for _, pull in pulls {
        if (!J_IsObj(pull) || !J_IsStr(pull.Get("timestamp")))
            continue
        utc := CD_ParsePullTimestamp(pull.Get("timestamp"))
        if (utc = "")
            continue
        day := CD_HistoryDayKey(utc)
        cards := pull.Get("cards")
        if (!J_IsArr(cards))
            continue
        for _, card in cards {
            if (!J_IsStr(card))
                continue
            k := day . "|" . card
            counts[k] := (counts.HasKey(k) ? counts[k] : 0) + 1
        }
    }
    return counts
}

CD_MissingHistoryPulls(historyDay, pulls, remaining) {
    out := []
    for _, pull in pulls {
        missing := []
        cards := pull.Get("cards")
        if (J_IsArr(cards)) {
            for _, card in cards {
                if (!J_IsStr(card))
                    continue
                k := historyDay . "|" . card
                if (remaining.HasKey(k) && remaining[k] > 0)
                    remaining[k] := remaining[k] - 1
                else
                    missing.Push(card)
            }
        }
        if (missing.Length()) {
            pull.Set("cards", missing)
            out.Push(pull)
        }
    }
    return out
}

CD_CardIdsFromHistory(ByRef text) {
    out := []
    Loop, Parse, text, `n
    {
        line := LTrim(S_Trim(RTrim(A_LoopField, "`r")), Chr(0xFEFF))
        p := InStr(line, "|")
        if (!p)
            continue
        for _, card in CD_CardIdsFromField(SubStr(line, p + 1), ",")
            out.Push(card)
    }
    return out
}

; history_pulls_from_line -> {utc, pulls} or ""
CD_HistoryPullsFromLine(line, cardmap) {
    line := LTrim(S_Trim(line), Chr(0xFEFF))
    if (line = "")
        return ""
    p := InStr(line, "|")
    if (!p)
        return ""
    timestamp := S_Trim(SubStr(line, 1, p - 1))
    if (timestamp = "")
        return ""
    utc := CD_ParsePullTimestamp(timestamp)
    if (utc = "")
        return ""
    cards := CD_CardIdsFromField(SubStr(line, p + 1), ",")
    if (!cards.Length())
        return ""
    return {utc: utc, pulls: CD_PullsByPack(CD_FormatPullTimestamp(utc), cards, cardmap)}
}

; set_doc_flag
CD_SetDocFlag(doc, flag) {
    if (!J_IsObj(doc.Get("metadata")))
        doc.Set("metadata", new JObj)
    metadata := doc.Get("metadata")
    if (!J_IsObj(metadata.Get("flags")))
        metadata.Set("flags", new JObj)
    metadata.Get("flags").Set(flag, CD_NewFlag(1, A_Now, ""))
}

CD_ImportHistory(device, input, inDepth) {
    if (S_Trim(device) = "")
        return
    path := CD_AccountPath(device)
    doc := CD_LoadAccountDocument(path, device)
    pulls := doc.Peek("pulls")
    if (IsObject(pulls) && pulls.__Class = "JRaw") {
        if (SubStr(pulls.raw, 1, 1) != "[")
            doc.Set("pulls", [])
    } else if (!J_IsArr(pulls)) {
        doc.Set("pulls", [])
    }
    scan := CD_ScanPullHistory(doc, inDepth)
    existingDays := scan.days
    remaining := scan.counts
    ; New pulls are spliced into the existing pull text instead of re-dumping it.
    pullsArr := []
    if (File_Exists(input)) {
        try text := File_ReadUtf8(input)
        catch
            throw Exception("Could not read history file " . CD_Q(input))
        cardmap := CD_LoadCardmapForCards(CD_CardIdsFromHistory(text))
        Loop, Parse, text, `n
        {
            entry := CD_HistoryPullsFromLine(RTrim(A_LoopField, "`r"), cardmap)
            if (!IsObject(entry))
                continue
            day := CD_HistoryDayKey(entry.utc)
            if (inDepth) {
                for _, pull in CD_MissingHistoryPulls(day, entry.pulls, remaining)
                    pullsArr.Push(pull)
                continue
            }
            if (existingDays.HasKey(day))
                continue
            for _, pull in entry.pulls
                pullsArr.Push(pull)
            existingDays[day] := true
        }
    }
    CD_DocAppendPulls(doc, pullsArr)
    CD_SetDocFlag(doc, "H")
    CD_WriteAccountDocument(device, doc)
}

;===============================================================================
; import-collection / import-registry
;===============================================================================

CD_LoadCollectionDocument(path, collectionKey, displayName) {
    if (File_Exists(path)) {
        text := File_ReadUtf8(path)
        try value := Json_Parse(text)
        catch e
            throw Exception("Could not parse " . CD_Q(path) . ": " . e.Message)
        if (!J_IsObj(value))
            value := new JObj
        if (!value.Has("collectionId"))
            value.Set("collectionId", collectionKey)
        if (!value.Has("displayName"))
            value.Set("displayName", displayName)
        if (!value.Has("metadata"))
            value.Set("metadata", new JObj)
        if (!value.Has("registeredCards"))
            value.Set("registeredCards", [])
        return value
    }
    doc := new JObj
    doc.Set("collectionId", collectionKey)
    doc.Set("displayName", displayName)
    doc.Set("deviceAccount", "")
    doc.Set("metadata", new JObj)
    doc.Set("registeredCards", [])
    return doc
}

CD_ImportCollection(device, input, instance, name, into, hasName, hasInto) {
    if (S_Trim(device) = "")
        throw Exception("device-account is required.")
    if (hasName && !hasInto) {
        displayName := S_Trim(name)
        if (displayName = "")
            throw Exception("Collection name cannot be empty.")
        collectionKey := CD_SafeFileName(displayName)
        if (collectionKey = "")
            throw Exception("Collection name is not valid for a file name.")
    } else if (hasInto && !hasName) {
        collectionKey := (S_Trim(into) = "") ? "" : CD_SafeFileName(S_Trim(into))
        if (collectionKey = "")
            throw Exception("Collection target is not valid.")
        path := CD_CollectionPath(collectionKey)
        if (!File_Exists(path))
            throw Exception("Collection file does not exist: " . path)
        existing := CD_LoadCollectionDocument(path, collectionKey, into)
        displayName := S_Trim(J_Str(existing.Get("displayName"), ""))
        if (displayName = "")
            displayName := collectionKey
    } else if (hasName && hasInto) {
        throw Exception("Use either --name or --into, not both.")
    } else {
        throw Exception("Provide --name for a new collection or --into for an existing one.")
    }

    collectionPath := CD_CollectionPath(collectionKey)
    if (hasName && File_Exists(collectionPath))
        throw Exception("A collection file already exists: " . collectionPath)

    doc := CD_LoadCollectionDocument(collectionPath, collectionKey, displayName)
    ids := new JObj
    if (File_Exists(input)) {
        try text := File_ReadUtf8(input)
        catch
            throw Exception("Could not read registry history file " . CD_Q(input))
        Loop, Parse, text, `n
        {
            line := LTrim(S_Trim(RTrim(A_LoopField, "`r")), Chr(0xFEFF))
            p := InStr(line, "|")
            if (line = "" || !p)
                continue
            for _, card in CD_CardIdsFromField(SubStr(line, p + 1), ",")
                ids.Set(card, true)
        }
    }
    registered := Arr_Sort(ids.Keys(), Func("Cmp_Ordinal"))

    if (!J_IsObj(doc.Get("metadata")))
        doc.Set("metadata", new JObj)
    doc.Set("collectionId", collectionKey)
    doc.Set("displayName", displayName)
    doc.Set("deviceAccount", S_Trim(device))
    metadata := doc.Get("metadata")
    if (S_Trim(instance) != "")
        metadata.Set("instance", S_Trim(instance))
    metadata.Set("registryImportedAt", A_Now)
    metadata.Set("registryCardCount", registered.Length() + 0)
    CD_SetDocFlag(doc, "R")
    doc.Set("registeredCards", registered)

    path := CD_CollectionPath(collectionKey)
    Dir_Create(Path_Dir(path))
    text := Json_Dump(doc, true) . "`n"
    File_WriteAtomic(path, text, Path_WithExt(path, "json.tmp"))
}

;===============================================================================
; format-account / append-pull
;===============================================================================

CD_FormatAccount(device) {
    if (S_Trim(device) = "")
        return
    path := CD_AccountPath(device)
    if (!File_Exists(path))
        return
    doc := CD_LoadAccountDocument(path, device)
    J_ResolveAll(doc)
    if (J_IsObj(doc)) {
        CD_HoistCardMarks(doc)
        CD_CompactAccountForWrite(doc.Get("metadata"))
    }
    CD_WriteAccountDocument(device, doc)
}

CD_AppendPull(device, timestamp, pack, cardsText) {
    if (S_Trim(device) = "")
        return
    normalized := CD_NormalizePullTimestamp(timestamp)
    pull := new JObj
    pull.Set("timestamp", (normalized != "") ? normalized : S_Trim(timestamp))
    pull.Set("pack", pack)
    pull.Set("cards", CD_CardIdsFromField(cardsText, "|"))
    doc := CD_LoadAccountDocument(CD_AccountPath(device), device)
    CD_DocAppendPulls(doc, [pull])
    CD_WriteAccountDocument(device, doc)
}

;===============================================================================
; Repair archive (snapshot-accounts / repair-accounts-from-snapshot)
;===============================================================================
; The archive holds one compact JSON document per account. Parsing it as one
; JSON value would take minutes in AHK for large account folders, so it is
; split into per-account text chunks instead. This file writes one account per
; line (still valid JSON for carddb.exe); archives written by carddb.exe are on
; a single line and are split by tracking brace depth.

CD_RepairArchivePath() {
    return CD_CacheDir() . "\archive\accounts-repair.archive.json"
}

CD_RepairArchiveMetaPath() {
    return CD_CacheDir() . "\archive\accounts-repair.archive.meta.json"
}

CD_LegacyRepairSnapshotPath() {
    return CD_CacheDir() . "\archive\accounts-data.snapshot.json"
}

class CD_Archive {
    __New() {
        this.texts := new JObj
    }

    Count() {
        return this.texts.Count()
    }

    Has(device) {
        return this.texts.Has(device)
    }

    SetText(device, text) {
        this.texts.Set(device, text)
    }

    GetText(device) {
        return this.texts.Get(device)
    }

    GetDoc(device) {
        if (!this.texts.Has(device))
            return ""
        return Json_Parse(this.texts.Get(device))
    }
}

; Device account of a compact account document chunk.
CD_ChunkDeviceAccount(ByRef chunk) {
    if (RegExMatch(chunk, "S)^\{\s*""deviceAccount""\s*:\s*(""[^""\\]*+(?:\\.[^""\\]*+)*+"")", m))
        return Json__Unescape(m1)
    ; deviceAccount is not the first key: parse just this document.
    try doc := Json_Parse(chunk)
    catch
        return ""
    return J_IsObj(doc) ? J_Str(doc.Get("deviceAccount"), "") : ""
}

; Number of "{" minus "}" outside strings.
CD_BraceBalance(ByRef segment) {
    s := RegExReplace(segment, "S)""[^""\\]*+(?:\\.[^""\\]*+)*+""")
    StrReplace(s, "{", "", opens)
    StrReplace(s, "}", "", closes)
    return opens - closes
}

; Splits the "accounts" array of an archive/snapshot payload into chunks and
; adds them (keyed by device account) to archive. Throws on malformed input.
CD_ReadArchiveChunks(path, archive) {
    text := File_ReadUtf8(path)
    if (!RegExMatch(text, "S)""accounts""\s*:\s*\[", m))
        throw Exception("Repair archive payload is missing accounts[]")
    pos := InStr(text, m, true) + StrLen(m)
    if (SubStr(text, pos, 2) == "`n{") {
        ; One compact document per line (the layout this script writes).
        Loop, Parse, % SubStr(text, pos + 1), `n
        {
            chunk := RTrim(A_LoopField, ",`r")
            if (SubStr(chunk, 1, 1) != "{")
                break
            device := CD_ChunkDeviceAccount(chunk)
            if (S_Trim(device) != "")
                archive.SetText(device, chunk)
        }
        return
    }
    Loop {
        if (!RegExMatch(text, "S)\G\s*(?:,\s*)?([{\]])", t, pos))
            throw Exception("Could not parse repair archive JSON " . CD_Q(path))
        if (t1 = "]")
            return
        start := pos + StrLen(t) - 1
        scan := start
        balance := 0
        Loop {
            end := RegExMatch(text, "S)\}(?=\s*[,\]])", e, scan)
            if (!end)
                throw Exception("Could not parse repair archive JSON " . CD_Q(path))
            balance += CD_BraceBalance(SubStr(text, scan, end + 1 - scan))
            scan := end + 1
            if (balance <= 0)
                break
        }
        chunk := SubStr(text, start, scan - start)
        device := CD_ChunkDeviceAccount(chunk)
        if (S_Trim(device) != "")
            archive.SetText(device, chunk)
        pos := scan
    }
}

CD_LoadRepairArchive() {
    archive := new CD_Archive
    path := CD_RepairArchivePath()
    if (File_Exists(path))
        CD_ReadArchiveChunks(path, archive)
    return archive
}

CD_ReadJsonObjectFile(path) {
    if (!File_Exists(path))
        return new JObj
    try value := Json_Parse(File_ReadUtf8(path))
    catch
        return new JObj
    return J_IsObj(value) ? value : new JObj
}

CD_WriteCompactJsonAtomic(path, value) {
    Dir_Create(Path_Dir(path))
    text := Json_Dump(value, false)
    File_WriteAtomic(path, text)
}

; Manifest signature over accounts/ and collections/ (name|len|mtime_ns).
CD_GatherDashboardPaths() {
    paths := []
    for _, bucket in ["accounts", "collections"] {
        dir := CD_CardsDir() . "\" . bucket
        for _, path in Dir_ListExt(dir, "json")
            paths.Push({name: bucket . "/" . Path_Name(path), path: path})
    }
    return Arr_Sort(paths, Func("Cmp_DashboardPath"))
}

Cmp_DashboardPath(a, b) {
    return S_Cmp(a.name, b.name)
}

CD_ComputeDashboardManifestSignature() {
    manifest := ""
    for _, p in CD_GatherDashboardPaths() {
        if (!File_Stat(p.path, nanos, size))
            throw Exception("Could not read " . CD_Q(p.path))
        manifest .= p.name . "|" . size . "|" . nanos . "`n"
    }
    return Sha256Hex(manifest)
}

CD_ComputeRepairScanSignature() {
    entries := []
    for _, path in Dir_ListExt(CD_AccountDir(), "json") {
        name := Path_Name(path)
        if (S_EndsWith(name, ".json.tmp"))
            continue
        entries.Push({name: name, size: File_Size(path)})
    }
    Arr_Sort(entries, Func("Cmp_RepairEntry"))
    manifest := ""
    for _, e in entries
        manifest .= e.name . "|" . e.size . "`n"
    return Sha256Hex(manifest)
}

Cmp_RepairEntry(a, b) {
    c := S_Cmp(a.name, b.name)
    if (c)
        return c
    return (a.size < b.size) ? -1 : (a.size > b.size) ? 1 : 0
}

CD_IsBlankStr(v) {
    return !J_IsStr(v) || S_Trim(v) = ""
}

CD_IsMissingOrNull(doc, key) {
    if (!doc.Has(key))
        return true
    v := doc.Peek(key)
    if (IsObject(v) && v.__Class = "JRaw")
        return v.raw == "null"
    return J_Type(v) = "null"
}

; load_dashboard_account_document -> compact JSON text of the document.
CD_LoadDashboardAccountDocument(path, sourceFileName, isCollection) {
    doc := CD_ReadJsonFile(path, corrupted)
    if (corrupted)
        throw Exception("Could not parse " . CD_Q(path))
    if (!J_IsObj(doc))
        throw Exception("Account JSON is not an object.")
    fallback := Path_Stem(path)
    if (CD_IsBlankStr(doc.Get("deviceAccount")))
        doc.Set("deviceAccount", fallback)
    if (CD_IsMissingOrNull(doc, "metadata"))
        doc.Set("metadata", new JObj)
    if (CD_IsMissingOrNull(doc, "pulls"))
        doc.Set("pulls", [])
    if (CD_IsMissingOrNull(doc, "registeredCards"))
        doc.Set("registeredCards", [])
    if (CD_IsMissingOrNull(doc, "tradedCards"))
        doc.Set("tradedCards", new JObj)
    if (CD_IsMissingOrNull(doc, "sharedCards"))
        doc.Set("sharedCards", new JObj)
    CD_HoistCardMarks(doc)
    doc.Set("sourceFileName", sourceFileName)
    if (isCollection) {
        doc.Set("sourceType", "collection")
        if (CD_IsBlankStr(doc.Get("collectionId")))
            doc.Set("collectionId", fallback)
        if (CD_IsBlankStr(doc.Get("displayName")))
            doc.Set("displayName", J_Str(doc.Get("collectionId"), fallback))
        pulls := doc.Peek("pulls")
        if (IsObject(pulls) && pulls.__Class = "JRaw") {
            if (SubStr(pulls.raw, 1, 1) = "[" && !RegExMatch(pulls.raw, "^\[\s*\]$"))
                doc.Set("pulls", [])
        } else if (J_IsArr(pulls) && pulls.Length()) {
            doc.Set("pulls", [])
        }
    }
    return Json_Dump(doc, false)
}

CD_SnapshotAccounts() {
    for _, name in ["accounts-data.cache.json", "accounts-data.cache.meta.json"]
        File_Delete(CD_CacheDir() . "\" . name)

    signature := CD_ComputeDashboardManifestSignature()
    current := new CD_Archive
    accountCount := 0, skippedCount := 0
    for _, p in CD_GatherDashboardPaths() {
        try {
            text := CD_LoadDashboardAccountDocument(p.path, p.name, S_StartsWith(p.name, "collections/"))
        } catch {
            skippedCount += 1
            continue
        }
        accountCount += 1
        device := CD_ChunkDeviceAccount(text)
        if (S_Trim(device) != "")
            current.SetText(device, text)
    }

    CD_MergeRepairArchive(current, signature)
    CD_Log("snapshot_accounts updated repair archive with " . accountCount . " accounts (" . skippedCount . " skipped)")
}

; merge_repair_archive_from_payload. current holds the documents of this run.
CD_MergeRepairArchive(current, signature) {
    metaPath := CD_RepairArchiveMetaPath()
    if (File_Exists(metaPath)) {
        oldMeta := CD_ReadJsonObjectFile(metaPath)
        if (S_Eq(J_Str(oldMeta.Get("signature"), Chr(1)), signature)) {
            CD_Log("merge_repair_archive skipped; signature unchanged")
            return
        }
    }

    archive := CD_LoadRepairArchive()
    seeded := 0
    if (archive.Count() = 0) {
        legacy := CD_LegacyRepairSnapshotPath()
        if (File_Exists(legacy)) {
            seed := new CD_Archive
            try {
                CD_ReadArchiveChunks(legacy, seed)
                for _, device in seed.texts.Keys() {
                    if (!archive.Has(device))
                        seeded += 1
                    archive.SetText(device, seed.GetText(device))
                }
            } catch e {
                CD_Log("seed_repair_archive skipped " . CD_Q(legacy) . ": " . e.Message)
            }
        }
    }

    updated := 0
    for _, device in current.texts.Keys() {
        archive.SetText(device, current.GetText(device))
        updated += 1
    }

    devices := Arr_Sort(archive.texts.Keys(), Func("Cmp_Ordinal"))
    accountCount := devices.Length()
    outPath := CD_RepairArchivePath()
    Dir_Create(Path_Dir(outPath))
    tmpPath := outPath . ".tmp"
    f := FileOpen(tmpPath, "w", "UTF-8-RAW")
    if (!IsObject(f))
        throw Exception("Could not write " . CD_Q(tmpPath))
    f.Write("{""ok"":true,""source"":""repair-archive"",""accountCount"":" . accountCount . ",""accounts"":[")
    for i, device in devices
        f.Write((i > 1 ? "," : "") . "`n" . archive.GetText(device))
    f.Write((accountCount ? "`n" : "") . "]}")
    f.Close()
    File_Rename(tmpPath, outPath)

    meta := new JObj
    meta.Set("signature", signature)
    meta.Set("accountCount", accountCount + 0)
    meta.Set("updatedFromSnapshot", updated + 0)
    meta.Set("seededFromBootstrap", seeded + 0)
    meta.Set("generatedAt", Ts_NowRfc3339Utc())
    meta.Set("generator", "carddb")
    oldMeta := CD_ReadJsonObjectFile(metaPath)
    for _, key in ["lastRepairSignature", "lastRepairCorrupted", "lastRepairAt"]
        if (oldMeta.Has(key))
            meta.Set(key, oldMeta.Get(key))
    CD_WriteCompactJsonAtomic(metaPath, meta)
    CD_Log("merge_repair_archive wrote " . accountCount . " accounts (updated=" . updated . ", seeded=" . seeded . ") to " . CD_Q(outPath))
}

CD_RepairAccountsFromSnapshot() {
    signature := CD_ComputeRepairScanSignature()
    meta := CD_ReadJsonObjectFile(CD_RepairArchiveMetaPath())
    lastCorrupted := J_Int(meta.Get("lastRepairCorrupted"), 1)
    if (S_Eq(J_Str(meta.Get("lastRepairSignature"), Chr(1)), signature) && lastCorrupted = 0) {
        summary := "repair_accounts_from_snapshot skipped; signature unchanged and last scan had 0 corrupted source=" . CD_Q(CD_RepairArchivePath())
        CD_Log(summary)
        StdOut(summary)
        return
    }

    accountsDir := CD_AccountDir()
    if (!File_IsDir(accountsDir)) {
        CD_Log("repair_accounts_from_snapshot: accounts directory missing")
        return
    }

    scanned := 0, corrupted := 0, repaired := 0, missing := 0, failed := 0
    archive := ""
    for _, path in Dir_ListExt(accountsDir, "json") {
        if (S_EndsWith(Path_Name(path), ".json.tmp"))
            continue
        scanned += 1
        if (!CD_IsAccountJsonCorrupted(path))
            continue
        corrupted += 1
        device := Path_Stem(path)
        if (device = "") {
            failed += 1
            CD_Log("repair_accounts_from_snapshot skipped corrupt file without key: " . CD_Q(path))
            continue
        }
        if (!IsObject(archive)) {
            if (File_Exists(CD_RepairArchivePath())) {
                archive := CD_LoadRepairArchive()
            } else {
                CD_Log("repair_accounts_from_snapshot: corrupt files found but no repair archive available")
                archive := new CD_Archive
            }
        }
        if (!archive.Has(device)) {
            missing += 1
            CD_Log("repair_accounts_from_snapshot could not restore " . device . ": not in repair archive")
            continue
        }
        try {
            backupDir := accountsDir . "\_repair_backup"
            Dir_Create(backupDir)
            backup := backupDir . "\" . device . "_" . Ts_Format(A_NowUTC, "yyyyMMdd_HHmmss") . ".corrupted"
            FileCopy, %path%, %backup%, 1
            if (ErrorLevel)
                throw Exception("Could not back up " . CD_Q(path) . " to " . CD_Q(backup))
        } catch e {
            CD_Log("repair_accounts_from_snapshot backup failed for " . device . ": " . e.Message)
        }
        CD_WriteAccountDocument(device, archive.GetDoc(device))
        try {
            CD_FormatAccount(device)
        } catch e {
            failed += 1
            CD_Log("repair_accounts_from_snapshot format failed for " . device . ": " . e.Message)
            continue
        }
        repaired += 1
    }

    summary := "repair_accounts_from_snapshot scanned=" . scanned . " corrupted=" . corrupted . " repaired=" . repaired
        . " missing_from_archive=" . missing . " failed=" . failed . " source=" . CD_Q(CD_RepairArchivePath())
    CD_Log(summary)
    meta := CD_ReadJsonObjectFile(CD_RepairArchiveMetaPath())
    meta.Set("lastRepairSignature", signature)
    meta.Set("lastRepairCorrupted", corrupted + 0)
    meta.Set("lastRepairAt", Ts_NowRfc3339Utc())
    CD_WriteCompactJsonAtomic(CD_RepairArchiveMetaPath(), meta)
    StdOut(summary)
}
