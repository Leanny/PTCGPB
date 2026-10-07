; Continuation lines, object literals, sections, comments and braces in text.
global packInfo := {"isVerified": false, "CardSlot": [], "TypeCount": {}}

class RarityBorder {
    static Anchors := { 4: [ {x: 57, y: 181}, {x: 142, y: 181} ]
        , 5: [ {x: 17, y: 176}, {x: 100, y: 176} ]
        , 6: [ {x: 17, y: 176}, {x: 100, y: 176} ] }

    __New(name) {
        this.Name := name
        this.Info := {"total": 0, "perInstance": {}, "source": "raw"}
    }

    Size[] {
        get {
            return this.Anchors.Count()
        }
    }

    class Nested {
        Hello() {
            return "{ not a block"
        }
    }
}

LongCall(first
    , second := ""
    , third := "") {
    text := "a; b" . first ; trailing comment with }
        . second
        ; comment between continuation lines
        . third
    if (first = "x"
        || second = "y")
        text .= "!"
    MsgBox,
    (LTrim
        This text is kept exactly,
                including   its own indentation.
    )
    /*
    Block comments are kept too.
        if (x) {
    */
    Send, {Enter}
    Send, {{}
    SendRaw, }
    return text
}

Allman()
{
    return 1
}
