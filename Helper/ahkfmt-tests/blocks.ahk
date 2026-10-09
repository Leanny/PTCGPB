; Braces, braceless bodies and else/catch/finally/until pairing.
Braces(x) {
    if (x > 1) {
        x -= 1
    } else if (x = 1) {
        x := 0
    } else {
        x := 1
    }

    if (x)
    {
        Loop, 3
        {
            x += A_Index
        }
    }
    return x
}

Braceless(a, b) {
    if a
        if b
            x := 1
        else
            x := 2
    else
        x := 3

    if a
        Loop, 3
            x += A_Index
    else if b
        x := 4
    else x := 5

    for key, value in {1: 2}
        while (value > 0)
            value--
    return x
}

ElseAfterBlock(a, b) {
    if a
        if b {
            x := 1
        }
        else
            x := 2
    return x
}

Errors() {
    try
        Risky()
    catch e
        LogIt(e)

    try {
        Risky()
    } catch e {
        LogIt(e)
    } finally {
        Done()
    }

    try Risky()
    catch
        return

    Loop {
        x++
    } Until x > 3

    Loop
        x++
    Until x > 6
    return x
}

LegacyIf(var) {
    IfExist, %var%
        FileDelete, %var%
    else
        MsgBox, Not found
    if var = abc
        MsgBox, abc
    return
}

Risky() {
}
LogIt(e) {
}
Done() {
}
