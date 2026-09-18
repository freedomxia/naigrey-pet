import AppKit
import UserNotifications

struct AISettings: Codable {
    var enabled: Set<AIProvider> = []
    var sound = false
    var notifications = false
    var motion = true
    var mutedUntil: Date? = nil
    var thresholds = [20, 10, 0]
    var mutedProviders: Set<AIProvider> = []
    var notifyEnded = true
    var notifyWaiting = true
    var notifyReset = true
    var quietStart: Int? = nil
    var quietEnd: Int? = nil
    var quietOverrideUntil: Date? = nil
}

/// No provider is touched before an explicit connection. UI callbacks always run on main.
@MainActor
final class AICompanionService {
    private(set) var settings: AISettings
    private(set) var readings: [AIProvider: AIUsage] = [:]
    private(set) var sessions: [AISession] = []
    private(set) var history: [AIAlert] = []
    private var unreadIDs: Set<String> = []
    var unread: Int { unreadIDs.count }
    private(set) var refreshing: Set<AIProvider> = []
    var onChange: (() -> Void)?
    /// Return false if the cat is being interacted with or cannot show a bubble safely.
    var present: ((AIAlert) -> Bool)?
    var canUseSystemNotification: (() -> Bool)?
    private let reader: (AIProvider) async throws -> AIUsage
    private let authorizer: () async throws -> Void
    let demo: Bool
    private let defaults: UserDefaults
    private var rules: AIEventRules
    private var sessionRules = AISessionRules()
    private var timer: Timer?
    private var tasks: [AIProvider: Task<Void, Never>] = [:]
    private var generations: [AIProvider: Int] = [:]
    private var lastAttempt: [AIProvider: Date] = [:]
    private var retryUntil: [String: Date]
    private var failures: [AIProvider: Int] = [:]
    private var sessionTask: Task<Void, Never>?
    private var sessionGeneration = 0
    private var queue: [AIAlert] = []
    private var lastPresented: TimeInterval = -.infinity
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    private var pendingResetChecks: Set<String> = []
    private var statusPanel: AIStatusPanel?

    init(defaults: UserDefaults = .standard, demo: Bool = false, reader: @escaping (AIProvider) async throws -> AIUsage = AIQuotaReader.fetch, authorizer: @escaping () async throws -> Void = AIQuotaReader.authorizeClaudeKeychain) {
        self.reader = reader; self.authorizer = authorizer
        self.defaults = defaults; self.demo = demo
        settings = Self.load(AISettings.self, "ai.settings", defaults) ?? AISettings()
        rules = Self.load(AIEventRules.self, "ai.rules", defaults) ?? AIEventRules()
        retryUntil = Self.load([String: Date].self, "ai.retry", defaults) ?? [:]
        if let saved = Self.load([AIUsage].self, "ai.cache", defaults) {
            for var value in saved where settings.enabled.contains(value.provider) && Date().timeIntervalSince(value.sourceAt) < 86400 {
                value.status = .stale; readings[value.provider] = value
            }
        }
        history = (Self.load([AIAlert].self, "ai.history", defaults) ?? []).filter { Date().timeIntervalSince($0.createdAt) < 86400 }
        rules.thresholds = settings.thresholds
        if demo {
            settings.enabled = []; readings = [:]; history = []; rules = AIEventRules()
            let now = Date()
            for p in AIProvider.allCases {
                readings[p] = AIUsage(provider:p,accountID:"demo",status:.ok,source:"演示数据 · 未连接真实账号",sourceAt:now,observedAt:now,windows:[AILimit(id:"primary",label:p == .codex ? "5 小时额度" : "当前会话",usedFraction:p == .codex ? 0.68 : 0.8,resetAt:now.addingTimeInterval(6480),periodSeconds:18000),AILimit(id:"secondary",label:"每周额度",usedFraction:0.33,resetAt:now.addingTimeInterval(280800),periodSeconds:604800)],message:nil)
            }
        }
    }
    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey:key).flatMap { try? JSONDecoder().decode(type,from:$0) }
    }
    private func save<T: Encodable>(_ value:T,_ key:String) {
        guard !demo, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data,forKey:key)
    }
    private func persist() {
        save(settings,"ai.settings"); save(rules,"ai.rules"); save(Array(readings.values),"ai.cache")
        save(history,"ai.history"); save(retryUntil,"ai.retry")
    }
    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        })
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds:3_000_000_000)
                guard let self, self.timer != nil else { return }
                self.suspended = false; self.queue = []; self.tick()
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        tick()
    }
    func stop() {
        timer?.invalidate(); timer = nil; suspend()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        AIQuotaReader.forgetClaudeAuthorization()
        persist()
    }
    private func suspend() {
        suspended = true; tasks.values.forEach { $0.cancel() }; tasks = [:]; refreshing = []
        for p in AIProvider.allCases { generations[p,default:0] += 1 }
        sessionGeneration += 1; sessionTask?.cancel(); sessionTask = nil; sessions = []; sessionRules = AISessionRules(); AISessionReader.clearCache()
    }
    func previewReminder() {
        let now = Date()
        let event = AIAlert(id:"demo-preview",provider:.codex,title:"演示 · Codex",body:"剩余 20%，58 分钟后重置。",priority:1,createdAt:now,expiresAt:now.addingTimeInterval(6))
        _ = present?(event)
    }
    func showPanel() {
        if statusPanel == nil { statusPanel = AIStatusPanel(service:self) }
        unreadIDs = []; statusPanel?.showWindow(nil); statusPanel?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        changed()
    }
    func connect(_ p:AIProvider) {
        guard !demo else { return }
        if settings.enabled.contains(p) { refresh(p,manual:true); return }
        settings.enabled.insert(p); readings[p] = nil; rules.forget(p); lastAttempt[p] = nil
        persist(); changed()
        if p == .claude {
            guard tasks[p] == nil else { return }
            let generation = generations[p,default:0]; refreshing.insert(p)
            tasks[p] = Task { [weak self] in
                do { try await self?.authorizer() }
                catch { /* fetch provides the actionable no-secret status */ }
                guard let self, !Task.isCancelled, self.generations[p,default:0] == generation, self.settings.enabled.contains(p) else { return }
                self.tasks[p] = nil; self.refreshing.remove(p); self.refresh(p,manual:true)
            }
        } else { refresh(p,manual:true) }
    }
    func disconnect(_ p:AIProvider) {
        if p == .claude { AIQuotaReader.forgetClaudeAuthorization() }
        generations[p,default:0] += 1; tasks.removeValue(forKey:p)?.cancel(); refreshing.remove(p)
        sessionGeneration += 1; sessionTask?.cancel(); sessionTask = nil
        settings.enabled.remove(p); readings[p] = nil; rules.forget(p); lastAttempt[p] = nil
        sessions.removeAll { $0.provider == p }; queue.removeAll { $0.provider == p }; history.removeAll { $0.provider == p }
        unreadIDs.formIntersection(Set(history.map(\.id)))
        sessionRules = AISessionRules(); AISessionReader.clearCache(); persist(); changed()
    }
    func updateSettings(_ update:(inout AISettings)->Void) {
        update(&settings); rules.thresholds = settings.thresholds
        if isMuted { queue = [] }
        persist(); changed()
    }
    func enableNotifications(_ enabled:Bool) {
        if !enabled { updateSettings { $0.notifications = false }; return }
        guard !demo else { return }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { [weak self] granted,_ in
            Task { @MainActor in self?.updateSettings { $0.notifications = granted } }
        }
    }
    var isMuted:Bool {
        if settings.mutedUntil.map({ $0 > Date() }) ?? false { return true }
        if settings.quietOverrideUntil.map({ $0 > Date() }) ?? false { return false }
        if let start = settings.quietStart, let end = settings.quietEnd, start != end {
            let c = Calendar.current.dateComponents([.hour,.minute],from:Date())
            let minute = (c.hour ?? 0)*60+(c.minute ?? 0)
            return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
        }
        return false
    }
    func refreshAll() { for p in settings.enabled { refresh(p,manual:true) } }
    func refresh(_ p:AIProvider,manual:Bool = false) {
        let now = Date()
        guard !demo, !suspended, settings.enabled.contains(p), tasks[p] == nil,
              retryUntil[p.rawValue].map({$0 <= now}) ?? true,
              lastAttempt[p].map({now.timeIntervalSince($0) >= 15}) ?? true else { return }
        if !manual, let status = readings[p]?.status, [.needsAuth,.accessDenied,.unsupported].contains(status) { return }
        lastAttempt[p] = now; refreshing.insert(p); changed()
        let generation = generations[p,default:0]
        tasks[p] = Task { [weak self] in
            do {
                guard let reader = self?.reader else { return }
                let value = try await reader(p)
                guard let self, !Task.isCancelled, self.generations[p,default:0] == generation, self.settings.enabled.contains(p) else { return }
                if let old = self.readings[p], old.accountID != value.accountID {
                    self.queue.removeAll { $0.provider == p }; self.history.removeAll { $0.provider == p }
                    self.unreadIDs.formIntersection(Set(self.history.map(\.id)))
                }
                self.readings[p] = value; self.failures[p] = 0; self.retryUntil[p.rawValue] = nil
                var core = value; core.windows.removeAll { $0.isExtra || $0.unlimited }
                let events = self.rules.observe(core,now:Date())
                self.accept(events)
            } catch {
                guard let self, !Task.isCancelled, self.generations[p,default:0] == generation, self.settings.enabled.contains(p) else { return }
                let failure = error as? AIProviderError
                let status = failure?.status ?? .error
                let message = failure?.message ?? "暂时无法读取，请稍后刷新。"
                var previous = self.readings[p] ?? AIUsage(provider:p,accountID:"",status:status,source:"",sourceAt:.distantPast,observedAt:now,windows:[],message:nil)
                previous.status = status; previous.message = message; previous.observedAt = Date()
                self.readings[p] = previous
                self.failures[p,default:0] += 1
                let delay = max(failure?.retryAfter ?? 0, min(900,60 * pow(2,Double(min(4,self.failures[p,default:1]-1)))))
                self.retryUntil[p.rawValue] = Date().addingTimeInterval(delay)
            }
            guard let self, self.generations[p,default:0] == generation else { return }
            self.tasks[p] = nil; self.refreshing.remove(p); self.persist(); self.changed()
        }
    }
    private func tick() {
        guard !suspended else { return }
        let now = Date()
        if !demo {
            for p in settings.enabled {
                if var v = readings[p], now.timeIntervalSince(v.sourceAt) > 900, v.status == .ok { v.status = .stale; readings[p] = v }
                let interval:TimeInterval = sessions.contains(where:{$0.state == "busy"}) ? 60 : 300
                if lastAttempt[p].map({now.timeIntervalSince($0) >= interval}) ?? true { refresh(p) }
                if let v = readings[p], v.status == .ok {
                    for w in v.windows {
                        if let reset = w.resetAt, reset <= now {
                            let key = "\(p.rawValue).\(w.id).\(reset.timeIntervalSince1970)"
                            if !pendingResetChecks.contains(key) {
                                refresh(p)
                                if tasks[p] != nil { pendingResetChecks = pendingResetChecks.filter { !$0.hasPrefix("\(p.rawValue).\(w.id).") }; pendingResetChecks.insert(key) }
                            }
                        }
                    }
                }
            }
            if sessionTask == nil, !settings.enabled.isEmpty {
                let enabled = settings.enabled, generation = sessionGeneration
                sessionTask = Task { [weak self] in
                    let found = await Task.detached(priority:.utility) { AISessionReader.read(enabled:enabled) }.value
                    guard let self, !Task.isCancelled, self.sessionGeneration == generation else { return }
                    self.sessions = found
                    self.accept(self.sessionRules.observe(found,now:Date()))
                    self.sessionTask = nil; self.changed()
                }
            }
        }
        drain(); changed()
    }
    private func allowed(_ event:AIAlert)->Bool {
        !settings.mutedProviders.contains(event.provider)
        && (event.kind != "waiting" || settings.notifyWaiting)
        && (event.kind != "ended" || settings.notifyEnded)
        && (event.kind != "reset" || settings.notifyReset)
    }
    private func accept(_ alerts:[AIAlert]) {
        guard !demo else { return }
        for event in alerts where !history.contains(where:{$0.id == event.id}) {
            history.append(event); unreadIDs.insert(event.id)
            if !isMuted && allowed(event) { queue.append(event) }
        }
        history = Array(history.filter { Date().timeIntervalSince($0.createdAt) < 86400 }.suffix(100))
        queue.sort { $0.priority == $1.priority ? $0.createdAt < $1.createdAt : $0.priority < $1.priority }
        queue = Array(queue.prefix(10)); persist()
    }
    private func drain() {
        if isMuted { queue = []; return }
        queue.removeAll { !settings.enabled.contains($0.provider) || !allowed($0) || !AIReminderPolicy.relevant($0,readings:readings,sessions:sessions,now:Date()) }
        guard !isMuted, statusPanel?.window?.isVisible != true, let event = queue.first else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard event.priority == 0 || now - lastPresented >= 15 else { return }
        // Never let multiple P0 items replace each other on successive 2-second ticks.
        guard now - lastPresented >= 8 else { return }
        if present?(event) == true {
            queue.removeFirst(); lastPresented = now
            if settings.sound { NSSound(named:"Glass")?.play() }
        } else if settings.notifications && canUseSystemNotification?() == true {
            let content = UNMutableNotificationContent(); content.title = event.title; content.body = event.body
            if settings.sound { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:event.id,content:content,trigger:nil))
            queue.removeFirst(); lastPresented = now
        }
    }
    private func changed() { statusPanel?.refresh(); onChange?() }
}
