;===============================================================================
; Json.ahk - JSON support for the AHK v1 fallback helpers
;===============================================================================
; Mirrors serde_json (with the "preserve_order" feature) closely enough that
; files written here are byte-identical to the ones the Rust helpers write:
;   - JObj keeps insertion order and case-sensitive keys (plain AHK objects are
;     case-insensitive and sorted, which would silently corrupt account data).
;   - JObj.Delete() is a swap-remove, exactly like serde_json's Map::remove.
;   - Json_Dump(..., true) reproduces serde_json's to_string_pretty layout.
;
; Value model:
;   object -> JObj instance          array  -> plain AHK array ([])
;   string -> AHK string             integer -> AHK pure number
;   float / huge number -> JNum (keeps the original text)
;   true / false / null -> J_True() / J_False() / J_Null() sentinels
;   JRaw   -> not yet parsed JSON text (lazy top-level values of account files);
;             JObj.Get() parses it on first access.
;
; AHK v1 cannot tell "5" from 5 by looking at the value, so numbers are detected
; with ObjGetCapacity: a field that holds a pure number has no string buffer.
; Anything stored as a JSON number must therefore be a real number (x + 0).
; Careful: in AHK v1 "return var" and "return 0" hand back a *string*, while
; "return x + 0", "return obj.prop" and "return Func()" keep a number. Functions
; that may pass numbers through therefore return expressions (see J_N).
;===============================================================================

class JObj {
    __New() {
        this._k := []
        this._v := {}
    }

    ; Returns the value for key k (parsing a lazy JRaw value on first access).
    Get(k, default := "") {
        e := JObj_Enc(k)
        if (!this._v.HasKey(e))
            return default
        v := this._v[e]
        if (IsObject(v) && v.__Class = "JRaw")
            this._v[e] := Json_Parse(v.raw)
        return this._v[e]
    }

    ; Returns the stored value without resolving lazy JRaw values.
    Peek(k, default := "") {
        e := JObj_Enc(k)
        if (!this._v.HasKey(e))
            return default
        return this._v[e]
    }

    Has(k) {
        return this._v.HasKey(JObj_Enc(k))
    }

    ; Insert or replace. Replacing keeps the key's position (IndexMap::insert).
    Set(k, v) {
        e := JObj_Enc(k)
        if (!this._v.HasKey(e))
            this._k.Push(k)
        this._v[e] := v
        return v
    }

    ; Swap-remove like serde_json's Map::remove: the last key takes the removed
    ; key's position.
    Delete(k) {
        e := JObj_Enc(k)
        if (!this._v.HasKey(e))
            return false
        this._v.Delete(e)
        n := this._k.Length()
        Loop, %n% {
            if (JObj_Enc(this._k[A_Index]) == e) {
                last := this._k.Pop()
                if (A_Index < n)
                    this._k[A_Index] := last
                break
            }
        }
        return true
    }

    ; Order-preserving removal (IndexMap::retain semantics).
    DeleteOrdered(k) {
        e := JObj_Enc(k)
        if (!this._v.HasKey(e))
            return false
        this._v.Delete(e)
        Loop % this._k.Length() {
            if (JObj_Enc(this._k[A_Index]) == e) {
                this._k.RemoveAt(A_Index)
                break
            }
        }
        return true
    }

    ; Keys in order. Returns a copy so callers may modify the object while looping.
    Keys() {
        return this._k.Clone()
    }

    Count() {
        return this._k.Length()
    }

    Clear() {
        this._k := []
        this._v := {}
    }
}

class JRaw {
    __New(raw) {
        this.raw := raw
    }
}

class JNum {
    __New(raw) {
        this.raw := raw
    }
}

class JLit {
    __New(name) {
        this.n := name
    }
}

J_True() {
    static v := new JLit("true")
    return v
}

J_False() {
    static v := new JLit("false")
    return v
}

J_Null() {
    static v := new JLit("null")
    return v
}

; Returns x as a pure number (see the note at the top of this file).
J_N(x) {
    return x + 0
}

; Returns v unchanged, keeping pure numbers numeric.
J_Pass(v) {
    if (!IsObject(v) && ObjGetCapacity([v], 1) = "")
        return v + 0
    return v
}

J_Bool(b) {
    return b ? J_True() : J_False()
}

; Case-sensitive storage key. AHK object keys are case-insensitive, so keys with
; capitals get a case mask appended. Chr(2)/Chr(1) keep the encoded key away
; from AHK's own object members ("base", integer keys, ...).
JObj_Enc(k) {
    if (RegExMatch(k, "S)[A-Z]"))
        return Chr(2) . k . Chr(1) . RegExReplace(RegExReplace(k, "S)[^A-Z]", "0"), "S)[A-Z]", "1")
    return Chr(2) . k
}

; "object", "array", "string", "number", "true", "false", "null" or "raw"
J_Type(v) {
    if (IsObject(v)) {
        c := v.__Class
        if (c = "JObj")
            return "object"
        if (c = "JRaw")
            return "raw"
        if (c = "JLit")
            return v.n
        if (c = "JNum")
            return "number"
        return "array"
    }
    return (ObjGetCapacity([v], 1) = "") ? "number" : "string"
}

J_IsObj(v) {
    return IsObject(v) && v.__Class = "JObj"
}

J_IsArr(v) {
    return IsObject(v) && v.__Class = ""
}

J_IsStr(v) {
    return !IsObject(v) && ObjGetCapacity([v], 1) != ""
}

; Value::as_str().unwrap_or(default)
J_Str(v, default := "") {
    return J_IsStr(v) ? v : default
}

; Value::as_i64() - only integer JSON numbers (never strings or floats).
J_IsInt(v) {
    return !IsObject(v) && ObjGetCapacity([v], 1) = ""
}

J_Int(v, default := "") {
    if (J_IsInt(v))
        return v + 0
    return J_Pass(default)
}

; Value::as_bool().unwrap_or(false)
J_IsTrue(v) {
    return IsObject(v) && v.__Class = "JLit" && v.n = "true"
}

; Rust "value.as_i64().or_else(|| value.as_str().and_then(|s| s.parse().ok()))"
J_IntOrParsed(v, ByRef out) {
    if (J_IsInt(v)) {
        out := v
        return true
    }
    if (J_IsStr(v) && RegExMatch(v, "^[+-]?\d{1,18}$")) {
        out := v + 0
        return true
    }
    return false
}

; serde_json "meaningful" helper used by the account merge logic.
J_Meaningful(v) {
    t := J_Type(v)
    if (t = "null")
        return false
    if (t = "string")
        return v != ""
    if (t = "array")
        return v.Length() > 0
    if (t = "object")
        return v.Count() > 0
    if (t = "raw")
        return !RegExMatch(v.raw, "^(?:\[\s*\]|\{\s*\}|""""|null)$")
    return true
}

; Deep copy.
J_Clone(v) {
    if (!IsObject(v))
        return J_Pass(v)
    c := v.__Class
    if (c = "JObj") {
        out := new JObj
        for _, k in v._k
            out.Set(k, J_Clone(v._v[JObj_Enc(k)]))
        return out
    }
    if (c = "JRaw")
        return new JRaw(v.raw)
    if (c = "JNum")
        return new JNum(v.raw)
    if (c = "JLit")
        return v
    out := []
    Loop % v.Length()
        out.Push(J_Clone(v[A_Index]))
    return out
}

; Parses every lazy JRaw value (recursively) so the next dump is canonical.
J_ResolveAll(v) {
    if (!IsObject(v))
        return J_Pass(v)
    c := v.__Class
    if (c = "JRaw")
        return J_ResolveAll(Json_Parse(v.raw))
    if (c = "JObj") {
        for _, k in v._k {
            e := JObj_Enc(k)
            v._v[e] := J_ResolveAll(v._v[e])
        }
        return v
    }
    if (c = "")
        Loop % v.Length()
            v[A_Index] := J_ResolveAll(v[A_Index])
    return v
}

;-------------------------------------------------------------------------------
; Parsing
;-------------------------------------------------------------------------------

; Parses a complete JSON text. Throws on invalid JSON or trailing garbage.
Json_Parse(ByRef text) {
    pos := 1
    if (SubStr(text, 1, 1) = Chr(0xFEFF))
        pos := 2
    v := Json__Value(text, pos)
    if (RegExMatch(text, "S)\G[ \t\r\n]*+\S", m, pos))
        throw Exception("JSON: trailing characters at position " . pos)
    return J_Pass(v)
}

Json__Value(ByRef s, ByRef pos) {
    static reTok := "S)\G[ \t\r\n]*+(?:(""[^""\\]*+(?:\\.[^""\\]*+)*+"")|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(true|false|null)|([{\[]))"
    static reKey := "S)\G[ \t\r\n]*+(""[^""\\]*+(?:\\.[^""\\]*+)*+"")[ \t\r\n]*+:"
    static reObjEnd := "S)\G[ \t\r\n]*+([,}])"
    static reArrEnd := "S)\G[ \t\r\n]*+([,\]])"
    static reEmptyObj := "S)\G[ \t\r\n]*+\}"
    static reEmptyArr := "S)\G[ \t\r\n]*+\]"

    if (!RegExMatch(s, reTok, m, pos))
        throw Exception("JSON: unexpected input at position " . pos)
    pos += StrLen(m)
    if (m1 != "")
        return Json__Unescape(m1)
    if (m2 != "")
        return Json__Number(m2)
    if (m3 != "")
        return (m3 == "true") ? J_True() : (m3 == "false") ? J_False() : J_Null()

    if (m4 = "{") {
        obj := new JObj
        if (RegExMatch(s, reEmptyObj, t, pos)) {
            pos += StrLen(t)
            return obj
        }
        Loop {
            if (!RegExMatch(s, reKey, t, pos))
                throw Exception("JSON: expected object key at position " . pos)
            pos += StrLen(t)
            key := Json__Unescape(t1)
            obj.Set(key, Json__Value(s, pos))
            if (!RegExMatch(s, reObjEnd, t, pos))
                throw Exception("JSON: expected ',' or '}' at position " . pos)
            pos += StrLen(t)
            if (t1 = "}")
                return obj
        }
    }

    arr := []
    if (RegExMatch(s, reEmptyArr, t, pos)) {
        pos += StrLen(t)
        return arr
    }
    Loop {
        arr.Push(Json__Value(s, pos))
        if (!RegExMatch(s, reArrEnd, t, pos))
            throw Exception("JSON: expected ',' or ']' at position " . pos)
        pos += StrLen(t)
        if (t1 = "]")
            return arr
    }
}

Json__Number(t) {
    if (RegExMatch(t, "[.eE]") || StrLen(LTrim(t, "-")) > 18)
        return new JNum(t)
    return t + 0
}

; Takes a quoted JSON string token and returns its value.
Json__Unescape(q) {
    s := SubStr(q, 2, -1)
    if (!InStr(s, "\"))
        return s
    out := ""
    p := 1
    while (i := InStr(s, "\", true, p)) {
        out .= SubStr(s, p, i - p)
        c := SubStr(s, i + 1, 1)
        if (c == "u") {
            out .= Chr("0x" . SubStr(s, i + 2, 4))
            p := i + 6
            continue
        }
        out .= (c == "n") ? "`n" : (c == "r") ? "`r" : (c == "t") ? "`t" : (c == "b") ? Chr(8) : (c == "f") ? Chr(12) : c
        p := i + 2
    }
    return out . SubStr(s, p)
}

; Splits a pretty-printed top-level object into lazy JRaw values without parsing
; the nested content. Account files can hold thousands of pulls, and most
; commands only need "metadata", so this avoids parsing the rest.
;
; Only accepts the exact layout serde_json's to_string_pretty writes (2-space
; indent, LF line endings), where every line starting with exactly two spaces
; and a quote is a top-level key. Returns "" when the text has another layout;
; callers then fall back to Json_Parse.
Json_ParseTopLazy(ByRef text) {
    static reKey := "S)\G\n  (""[^""\\\n]*+(?:\\.[^""\\\n]*+)*+""): "
    start := (SubStr(text, 1, 1) = Chr(0xFEFF)) ? 2 : 1
    if (SubStr(text, start, 2) == "{}")
        return RegExMatch(text, "S)^\x{FEFF}?\{\}[ \t\r\n]*$") ? new JObj : ""
    if (SubStr(text, start, 5) != "{`n  """)
        return ""
    if (!RegExMatch(text, "S)\n\}[ \t\r\n]*$", tail))
        return ""
    endPos := StrLen(text) - StrLen(tail) + 1

    obj := new JObj
    p := start + 1
    Loop {
        if (!RegExMatch(text, reKey, m, p))
            return ""
        key := Json__Unescape(m1)
        vs := p + StrLen(m)
        nx := InStr(text, "`n  """, true, vs)
        if (nx && nx < endPos) {
            if (SubStr(text, nx - 1, 1) != ",")
                return ""
            raw := SubStr(text, vs, nx - 1 - vs)
        } else {
            raw := SubStr(text, vs, endPos - vs)
            nx := 0
        }
        if (!Json__RawLooksValid(raw))
            return ""
        obj.Set(key, new JRaw(raw))
        if (!nx)
            return obj
        p := nx
    }
}

; Cheap structural check for one lazy top-level value of a pretty-printed file.
Json__RawLooksValid(ByRef raw) {
    first := SubStr(raw, 1, 1)
    if (first = "{" || first = "[") {
        close := (first = "{") ? "}" : "]"
        if (raw == first . close)
            return true
        return SubStr(raw, 1, 2) == first . "`n" && SubStr(raw, -3) == "`n  " . close
    }
    if (InStr(raw, "`n"))
        return false
    return RegExMatch(raw, "S)^(?:""[^""\\]*+(?:\\.[^""\\]*+)*+""|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)$")
}

; Removes all whitespace outside strings (serde_json::to_vec layout).
Json_Minify(ByRef raw) {
    return RegExReplace(raw, "S)(""[^""\\]*+(?:\\.[^""\\]*+)*+"")|[ \t\r\n]++", "$1")
}

;-------------------------------------------------------------------------------
; Serialization
;-------------------------------------------------------------------------------

; pretty=true matches serde_json::to_string_pretty, pretty=false matches
; serde_json::to_string. baseIndent is the indent of the line the value starts
; on (used when splicing a value into an existing pretty document).
Json_Dump(v, pretty := true, baseIndent := "") {
    out := ""
    Json__Dump(out, v, pretty, baseIndent)
    return out
}

Json__Dump(ByRef out, v, pretty, ind) {
    if (IsObject(v)) {
        c := v.__Class
        if (c = "JObj") {
            if (v._k.Length() = 0) {
                out .= "{}"
                return
            }
            ind2 := ind . "  "
            out .= pretty ? "{`n" : "{"
            for i, k in v._k {
                if (i > 1)
                    out .= pretty ? ",`n" : ","
                if (pretty)
                    out .= ind2
                Json__Str(out, k)
                out .= pretty ? ": " : ":"
                Json__Dump(out, v._v[JObj_Enc(k)], pretty, ind2)
            }
            out .= pretty ? "`n" . ind . "}" : "}"
            return
        }
        if (c = "JRaw") {
            out .= pretty ? v.raw : Json_Minify(v.raw)
            return
        }
        if (c = "JLit" || c = "JNum") {
            out .= (c = "JLit") ? v.n : v.raw
            return
        }
        n := v.Length()
        if (n = 0) {
            out .= "[]"
            return
        }
        ind2 := ind . "  "
        out .= pretty ? "[`n" : "["
        Loop, %n% {
            if (A_Index > 1)
                out .= pretty ? ",`n" : ","
            if (pretty)
                out .= ind2
            Json__Dump(out, v[A_Index], pretty, ind2)
        }
        out .= pretty ? "`n" . ind . "]" : "]"
        return
    }
    if (ObjGetCapacity([v], 1) = "")
        out .= v
    else
        Json__Str(out, v)
}

; serde_json string escaping: only '"', '\' and control characters.
Json__Str(ByRef out, s) {
    if (!RegExMatch(s, "S)[""\\\x01-\x1F]")) {
        out .= """" . s . """"
        return
    }
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, """", "\""")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    s := StrReplace(s, Chr(8), "\b")
    s := StrReplace(s, Chr(12), "\f")
    while (RegExMatch(s, "S)[\x01-\x1F]", ch))
        s := StrReplace(s, ch, Format("\u{:04x}", Ord(ch)))
    out .= """" . s . """"
}
