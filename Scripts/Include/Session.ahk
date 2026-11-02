class Session {
    sessionItems := {}

    __New(){
        this.sessionItems := {}
    }

    set(itemName, itemValue){
        this.sessionItems[itemName] := itemValue
    }

    get(itemName){
        ; Debug aid: with disableFailsafe on, the failsafe timer always reads as just reset,
        ; so "A_TickCount - session.get("failSafe")" stays 0 and no failsafe ever fires
        if(itemName = "failSafe" && this.sessionItems["disableFailsafe"])
            return A_TickCount
        return this.sessionItems[itemName]
    }
}
