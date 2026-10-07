; Auto-execute section, labels, hotkeys and #If sections.
#NoEnv
SetBatchLines, -1
Gosub, Start
return

Start:
    if (A_IsAdmin)
        return
    Gui, Add, Text,, Hello
return

ButtonOK:
GuiClose:
    Gui, Destroy
    ExitApp
return

~+F7::
    if (WinExist("A"))
        WinClose
return
~+F8::Reload

#IfWinActive, Some Window
    F5::Refresh()
#IfWinActive

; A label body that ends without return before a function.
Fallthrough:
    MsgBox, fall through

Refresh() {
    global counter
    counter++
    if (counter > 3)
        Goto, Done

    counter := 0
    Done:
    return counter
}

Reload() {
    Reload
}
