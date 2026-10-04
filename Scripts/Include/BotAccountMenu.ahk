; In-game account deletion and injected god pack finalization

FinalizeInjectedGodPackAccount(testing := True) {
    global botConfig, session, DeadCheck

    if (!session.get("injectMethod") || !session.get("loadedAccount"))
        return

    if(testing) {
        session.get("missionDoneList")["accountHasPackInTesting"] := 1
    }
    setMetaData()
    IniWrite, 0, % session.get("scriptIniFile"), UserSettings, DeadCheck

    if (botConfig.get("deleteMethod") = "Inject 13P+" || botConfig.get("deleteMethod") = "Inject Wonderpick 96P+") {
        MarkAccountAsUsed()
        session.set("loadedAccount", false)
    }
}

menuDelete() {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig, session

    Delay(1)
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop
    {
        Delay(2)
        adbClick_wbb(245, 518)
        if(FindImageAndClick("Menu_InventoryIconInMenu", , , , , 1, failSafeTime)) ;wait for settings menu
            break
        Delay(2)
        adbClick_wbb(50, 100)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Settings`n(" . failSafeTime . " seconds)")
    }
    Delay(1)
    FindImageAndClick("Menu_SettingButtonInMenu", 140, 440, , 2000) ;wait for other menu
    Delay(1)
    FindImageAndClick("Menu_RemoveAccountNintendoButtonInMenu", 79, 256, , 1000) ;wait for account menu
    Delay(1)

    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        session.set("failSafe", A_TickCount)
        failSafeTime := 0
        Loop {
            clickButton := FindOrLoseImage("Common_UnknownButton2", 0, failSafeTime, 40)
            if(!clickButton) {
                ; fix https://discord.com/channels/1330305075393986703/1354775917288882267/1355090394307887135
                clickImage := FindOrLoseImage("Menu_DeleteConfimButtonStep1", 0, failSafeTime, 60)
                if(clickImage) {
                    StringSplit, pos, clickImage, `,  ; Split at ", "
                    adbClick_wbb(pos1, pos2)
                }
                else {
                    adbClick_wbb(198, 480)
                    Delay(2)
                    adbClick_wbb(230, 506)
                }
                Delay(1)
                failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
                CreateStatusMessage("Waiting to click delete`n(" . failSafeTime . "/45 seconds)")
            }
            else {
                break
            }
            Delay(1)
        }
        StringSplit, pos, clickButton, `,  ; Split at ", "
        adbClick_wbb(pos1, pos2)
        break
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting to click delete`n(" . failSafeTime . "/45 seconds)")
    }

    Sleep, 2500
}

menuDeleteStart() {
    prof := Prof_Scope(A_ThisFunc)
    global botConfig, session

    if(session.get("keepAccount")) {
        return session.get("keepAccount")
    }
    if(session.get("friended")) {
        FindImageAndClick("Common_SpeedModMenuButton", 18, 109, , 2000)
        if(session.get("setSpeed") = 3)
            FindImageAndClick(GetSpeedModNeedle(3), GetSpeedModClickX(3), GetSpeedModClickY(3))
        else
            FindImageAndClick(GetSpeedModNeedle(2), GetSpeedModClickX(2), GetSpeedModClickY(2))
        Delay(1)
        adbClick_wbb(51, 297)
        Delay(1)
    }
    session.set("failSafe", A_TickCount)
    failSafeTime := 0
    Loop {
        if(!session.get("friended"))
            break
        adbClick_wbb(255, 83)
        if(FindOrLoseImage("Create_CountryComboBoxButton", 0, failSafeTime)) { ;if at country continue
            break
        }
        else if(FindOrLoseImage("Menu_AgreementIconInIntroMenu", 0, failSafeTime)) { ; if the clicks in the top right open up the game settings menu then continue to delete account
            Delay(1)
            FindImageAndClick("Menu_RemoveAccountNintendoButtonInMenu", 79, 256, , 1000) ;wait for account menu
            Delay(1)
            session.set("failSafe", A_TickCount)
            failSafeTime := 0
            Loop {
                clickButton := FindOrLoseImage("Common_ColorChangeButton", 0, failSafeTime, 80)
                if(!clickButton) {
                    clickImage := FindOrLoseImage("Menu_DeleteConfimButtonStep1", 0, failSafeTime, 60)
                    if(clickImage) {
                        StringSplit, pos, clickImage, `,  ; Split at ", "
                        adbClick_wbb(pos1, pos2)
                    }
                    else {
                        adbClick_wbb(230, 506)
                    }
                    Delay(1)
                    failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
                    CreateStatusMessage("Waiting to click delete`n(" . failSafeTime . "/45 seconds)")
                }
                else {
                    break
                }
                Delay(1)
            }
            StringSplit, pos, clickButton, `,  ; Split at ", "
            adbClick_wbb(pos1, pos2)
            break
            failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
            CreateStatusMessage("Waiting to click delete`n(" . failSafeTime . "/45 seconds)")
        }
        CreateStatusMessage("Looking for Country/Menu")
        Delay(1)
        failSafeTime := (A_TickCount - session.get("failSafe")) // 1000
        CreateStatusMessage("Waiting for Country/Menu`n(" . failSafeTime . "/45 seconds)")
    }
    if(session.get("loadedAccount")) {
        ;    FileDelete, % session.get("loadedAccount")
    }
}
