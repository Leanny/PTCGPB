GetHourglassSpendTarget() {
    global botConfig

    count := botConfig.get("spendHourglassPackCount") + 0
    return count > 0 ? count : 999999
}

GetHourglassSpendRemaining() {
    global session

    remaining := GetHourglassSpendTarget() - (session.get("hourglassSpendOpened") + 0)
    return remaining > 0 ? remaining : 0
}

HourglassTenPackOpeningEnabled() {
    global botConfig

    return botConfig.get("hourglassTenPackOpening") = 1
}

InitHourglassSpendSession() {
    global session

    session.set("hourglassSpendOpened", 0)
    session.set("hourglassSpendPacksBefore", session.get("packsThisRun") + 0)
}

RecordHourglassPacksOpened() {
    global session

    packsNow := session.get("packsThisRun") + 0
    packsBefore := session.get("hourglassSpendPacksBefore") + 0
    if (packsNow > packsBefore) {
        session.set("hourglassSpendOpened", (session.get("hourglassSpendOpened") + 0) + (packsNow - packsBefore))
        session.set("hourglassSpendPacksBefore", packsNow)
    }
}

CanContinueHourglassSpend() {
    global session

    if (session.get("cantOpenMorePacks"))
        return false
    if (GetHourglassSpendRemaining() <= 0)
        return false
    return CanContinuePackOpening()
}

CanContinueHourglassSpendWonderpick() {
    global botConfig, session

    if (session.get("cantOpenMorePacks"))
        return false
    if (GetHourglassSpendRemaining() <= 0)
        return false
    return (session.get("friendIDs") || botConfig.get("FriendID") != "" || session.get("accountOpenPacks") < session.get("maxAccountPackNum"))
}

CanContinuePackOpening() {
    global botConfig, session
    return !session.get("cantOpenMorePacks") && (session.get("friendIDs") || botConfig.get("FriendID") != "" || session.get("accountOpenPacks") < session.get("maxAccountPackNum"))
}

ResetTenPackFallbackState() {
    global session

    if (FindOrLoseImage("Pack_NotEnoughItemsForOpenPack", 0, 0)) {
        adbInputEvent("111")
        Delay(1)
    }
    session.set("cantOpenMorePacks", 0)
}

OpenHourglassTenPackBatch(isFirstBatch := false) {
    global session

    if (GetHourglassSpendRemaining() < 10)
        return false

    if (isFirstBatch) {
        GoToMain()
        session.set("cantOpenMorePacks", 0)
        SelectPack("HGPack10")
        if (session.get("cantOpenMorePacks"))
            return false
        session.set("expectedPackOpenCount", 10)
        PackOpening(true)
        session.set("expectedPackOpenCount", 1)
        RecordHourglassPacksOpened()
        return true
    }

    session.set("expectedPackOpenCount", 10)
    HourglassOpening(true, true, true)
    session.set("expectedPackOpenCount", 1)
    RecordHourglassPacksOpened()
    return true
}

OpenHourglassSinglePack(isFirstSingle := false) {
    global session

    if (GetHourglassSpendRemaining() <= 0)
        return false

    if (isFirstSingle) {
        GoToMain()
        SelectPack("HGPack")
        if (session.get("cantOpenMorePacks"))
            return false
        PackOpening()
        RecordHourglassPacksOpened()
        return true
    }

    HourglassOpening(true)
    RecordHourglassPacksOpened()
    return true
}

SpendAllHourglassInject13P_SinglesOnly() {
    global session

    if (!CanContinueHourglassSpend())
        return

    OpenHourglassSinglePack(true)
    if (!CanContinueHourglassSpend())
        return

    while (CanContinueHourglassSpend())
        OpenHourglassSinglePack(false)
}

SpendAllHourglassInject13P() {
    global botConfig, session

    InitHourglassSpendSession()
    tenPack := HourglassTenPackOpeningEnabled()

    if (!tenPack) {
        GoToMain()
        session.set("cantOpenMorePacks", 0)
        SpendAllHourglassInject13P_SinglesOnly()
        return
    }

    GoToMain()
    session.set("cantOpenMorePacks", 0)
    firstSingleNeeded := true

    if (GetHourglassSpendRemaining() >= 10) {
        OpenHourglassTenPackBatch(true)
        firstSingleNeeded := false
    }

    while (CanContinueHourglassSpend()) {
        if (HourglassTenPackOpeningEnabled() && GetHourglassSpendRemaining() >= 10) {
            OpenHourglassTenPackBatch(false)
            firstSingleNeeded := false
        } else {
            OpenHourglassSinglePack(firstSingleNeeded)
            firstSingleNeeded := false
        }
    }

    if (!session.get("cantOpenMorePacks"))
        return

    ResetTenPackFallbackState()

    if (!CanContinueHourglassSpend())
        return

    firstSingleNeeded := true
    while (CanContinueHourglassSpend()) {
        OpenHourglassSinglePack(firstSingleNeeded)
        firstSingleNeeded := false
    }
}

SpendAllHourglass() {
    global botConfig, session

    if (botConfig.get("deleteMethod") = "Inject 13P+") {
        SpendAllHourglassInject13P()
        return
    }

    InitHourglassSpendSession()
    GoToMain()

    SelectPack("HGPack")
    if(session.get("cantOpenMorePacks"))
        return

    PackOpening()
    RecordHourglassPacksOpened()
    if(session.get("cantOpenMorePacks") || !CanContinueHourglassSpendWonderpick())
        return

    while (CanContinueHourglassSpendWonderpick()) {
        if(session.get("packMethod")) {
            session.set("friendsAdded", PackMethod_RenewFriends())
            if (!PackMethod_ConsumeStayOnPackScreen()) {
                GoToMain()
                SelectPack("HGPack")
            }
            if(session.get("cantOpenMorePacks"))
                break
            PackOpening()
            RecordHourglassPacksOpened()
        } else {
            HourglassOpening(true)
            RecordHourglassPacksOpened()
        }

        if(session.get("cantOpenMorePacks") || !CanContinueHourglassSpendWonderpick())
            break
    }
}
