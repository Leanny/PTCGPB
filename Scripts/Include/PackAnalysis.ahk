;-------------------------------------------------------------------------------
; AnalyzeBorderBitmap - Classify the rarity of every card slot from one frame
;
; Pure function: no capturing, clicking or waiting. AnalysisBorder() captures
; the frame; the detection tests replay recorded frames through this.
; Requires rarityCheckers (RarityBorder.ahk) to be populated by the caller.
;-------------------------------------------------------------------------------
AnalyzeBorderBitmap(pBitmap, totalCardsInPack) {
    global rarityCheckers

    packInfo := {"isVerified": false, "CardSlot": [], "TypeCount": {}}

    Loop, % totalCardsInPack {
        cardIndex := A_Index
        if(packInfo["CardSlot"][cardIndex] != "")
            continue

        cardRarityName := ""
        for index, Checker in rarityCheckers {
            cardRarityName := Checker.RarityName

            isFound := Checker.Search(pBitmap, totalCardsInPack, cardIndex)
            if (isFound) {
                if(packInfo["TypeCount"][cardRarityName] = "")
                    packInfo["TypeCount"][cardRarityName] := 0

                packInfo["CardSlot"][cardIndex] := cardRarityName
                packInfo["TypeCount"][cardRarityName] := (packInfo["TypeCount"].HasKey(cardRarityName) ? packInfo["TypeCount"][cardRarityName] : 0) + 1
                break
            }
        }
    }

    For idx, Checker in rarityCheckers {
        rarityName := Checker.RarityName
        if(!packInfo["TypeCount"].HasKey(rarityName) || packInfo["TypeCount"][rarityName] == "")
            packInfo["TypeCount"][rarityName] := 0
    }

    packInfo["isVerified"] := true
    return packInfo
}
