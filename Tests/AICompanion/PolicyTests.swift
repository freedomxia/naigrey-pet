import Foundation
func runPolicyTests() throws {
    let now = Date(), p = AIProvider.codex
    var usage = AIUsage(provider:p,accountID:"a",status:.ok,source:"fixture",sourceAt:now,observedAt:now,windows:[AILimit(id:"primary",label:"5h",usedFraction:1)])
    let alert = AIAlert(id:"1",provider:p,title:"t",body:"b",priority:0,createdAt:now,expiresAt:now.addingTimeInterval(60),windowID:"primary",kind:"threshold-0",accountID:"a")
    precondition(AIReminderPolicy.relevant(alert,readings:[p:usage],sessions:[],now:now))
    usage.windows[0].usedFraction = 0.5
    precondition(!AIReminderPolicy.relevant(alert,readings:[p:usage],sessions:[],now:now))
    usage.windows[0].usedFraction = 1; usage.accountID = "other"
    precondition(!AIReminderPolicy.relevant(alert,readings:[p:usage],sessions:[],now:now))
    usage.accountID = "a"; usage.status = .stale
    precondition(!AIReminderPolicy.relevant(alert,readings:[p:usage],sessions:[],now:now))
    let waiting = AIAlert(id:"2",provider:p,title:"t",body:"b",priority:0,createdAt:now,expiresAt:now.addingTimeInterval(60),sessionID:"s",kind:"waiting")
    var session = AISession(id:"s",provider:p,name:"fixture",state:"waiting",evidence:"explicit",updatedAt:now)
    precondition(AIReminderPolicy.relevant(waiting,readings:[:],sessions:[session],now:now))
    session.state = "busy"
    precondition(!AIReminderPolicy.relevant(waiting,readings:[:],sessions:[session],now:now))
    precondition(!AIReminderPolicy.relevant(waiting,readings:[:],sessions:[],now:now))
}
