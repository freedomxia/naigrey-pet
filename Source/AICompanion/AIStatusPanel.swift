import AppKit

private final class AITopDownView: NSView { override var isFlipped: Bool { true } }

@MainActor
final class AIStatusPanel: NSWindowController {
    private unowned let service: AICompanionService
    private let content = NSStackView()
    private let status = NSTextField(labelWithString:"")
    private let sound = NSButton(checkboxWithTitle:"声音",target:nil,action:nil)
    private let notifications = NSButton(checkboxWithTitle:"系统通知",target:nil,action:nil)
    private let motion = NSButton(checkboxWithTitle:"轻动作联动",target:nil,action:nil)
    private let thresholds = NSTextField(string:"20,10,0")
    private let mute = NSButton(title:"暂停提醒 1 小时",target:nil,action:nil)
    private var signature = ""
    private let ended = NSButton(checkboxWithTitle:"本轮结束",target:nil,action:nil)
    private let waiting = NSButton(checkboxWithTitle:"等待操作",target:nil,action:nil)
    private let reset = NSButton(checkboxWithTitle:"额度恢复",target:nil,action:nil)
    private let quiet = NSTextField(string:"")

    init(service:AICompanionService) {
        self.service = service
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:640,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = service.demo ? "奶灰 · AI 额度与任务（演示）" : "奶灰 · AI 额度与任务"
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width:570,height:620); window.isReleasedWhenClosed = false
        super.init(window:window)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top:20,left:22,bottom:20,right:22); root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView(); window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
        let title = Self.label("额度清楚，工作安心。",size:23,weight:.semibold)
        root.addArrangedSubview(title)
        status.font = .systemFont(ofSize:12); status.textColor = .secondaryLabelColor; root.addArrangedSubview(status)
        let toolbar = NSStackView(); toolbar.spacing = 8
        toolbar.addArrangedSubview(button("刷新额度",#selector(refreshNow)))
        toolbar.addArrangedSubview(button("预览气泡",#selector(previewBubble)))
        mute.target = self; mute.action = #selector(toggleMute); toolbar.addArrangedSubview(mute)
        root.addArrangedSubview(toolbar)
        let options = NSStackView(); options.spacing = 18
        for control in [sound,notifications,motion] { control.target = self; control.action = #selector(changeOptions); options.addArrangedSubview(control) }
        root.addArrangedSubview(options)
        let events = NSStackView(); events.spacing = 16
        for control in [ended,waiting,reset] { control.target = self; control.action = #selector(changeEvents); events.addArrangedSubview(control) }
        root.addArrangedSubview(events)
        let quietRow = NSStackView(); quietRow.spacing = 8
        quietRow.addArrangedSubview(Self.label("每日免打扰",size:12))
        quiet.placeholderString = "22:00-08:00，留空关闭"; quiet.widthAnchor.constraint(equalToConstant:180).isActive = true
        quiet.setAccessibilityLabel("每日免打扰时段")
        quietRow.addArrangedSubview(quiet); quietRow.addArrangedSubview(button("保存时段",#selector(saveQuiet)))
        root.addArrangedSubview(quietRow)
        let thresholdRow = NSStackView(); thresholdRow.spacing = 8
        thresholdRow.addArrangedSubview(Self.label("剩余额度提醒 %",size:12))
        thresholds.widthAnchor.constraint(equalToConstant:110).isActive = true
        thresholds.setAccessibilityLabel("剩余额度阈值，逗号分隔")
        thresholdRow.addArrangedSubview(thresholds); thresholdRow.addArrangedSubview(button("保存阈值",#selector(saveThresholds)))
        root.addArrangedSubview(thresholdRow)
        let line = NSBox(); line.boxType = .separator; root.addArrangedSubview(line); line.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-44).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 15; content.translatesAutoresizingMaskIntoConstraints = false
        let document = AITopDownView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content); scroll.documentView = document
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),content.leadingAnchor.constraint(equalTo:document.leadingAnchor),content.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-12),content.topAnchor.constraint(equalTo:document.topAnchor),content.bottomAnchor.constraint(equalTo:document.bottomAnchor)])
        root.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-44).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
        let footer = Self.label("只读本机登录与状态 · 不自动使用重置券 · 不修改 Codex / Claude 配置",size:11)
        footer.textColor = .secondaryLabelColor; root.addArrangedSubview(footer)
        thresholds.stringValue = service.settings.thresholds.map(String.init).joined(separator:",")
        if let start = service.settings.quietStart, let end = service.settings.quietEnd {
            quiet.stringValue = String(format:"%02d:%02d-%02d:%02d",start/60,start%60,end/60,end%60)
        }
        window.initialFirstResponder = nil
        window.center(); refresh()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private static func label(_ text:String,size:CGFloat = 13,weight:NSFont.Weight = .regular)->NSTextField {
        let v = NSTextField(wrappingLabelWithString:text); v.font = .systemFont(ofSize:size,weight:weight); v.isSelectable = true; return v
    }
    private func button(_ title:String,_ action:Selector)->NSButton {
        let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b
    }
    func refresh() {
        ended.state = service.settings.notifyEnded ? .on : .off
        waiting.state = service.settings.notifyWaiting ? .on : .off
        reset.state = service.settings.notifyReset ? .on : .off
        sound.state = service.settings.sound ? .on : .off
        notifications.state = service.settings.notifications ? .on : .off
        motion.state = service.settings.motion ? .on : .off
        mute.title = service.isMuted ? "恢复提醒 1 小时" : "暂停提醒 1 小时"
        status.stringValue = service.demo ? "演示数据，不会读取账号、发送通知或保存设置。" : service.isMuted ? "已暂停主动提醒；额度和任务继续更新。" : "点击连接后才开始读取。首次读数只显示，不补发过去的提醒。"
        let lines = AIProvider.allCases.map { providerText($0) }
        let sessionText = service.sessions.map { "\($0.provider.title) · \($0.name) · \(stateName($0.state))\($0.evidence == "explicit" ? "" : "（检测到活动）")" }.joined(separator:"\n")
        let recent = service.history.suffix(5).reversed().map { "\($0.title)\n\($0.body)" }.joined(separator:"\n\n")
        let next = lines.joined(separator:"|") + sessionText + recent + service.settings.enabled.map(\.rawValue).sorted().joined() + service.refreshing.map(\.rawValue).sorted().joined() + service.settings.mutedProviders.map(\.rawValue).sorted().joined()
        guard next != signature else { return }; signature = next
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index,p) in AIProvider.allCases.enumerated() {
            let header = NSStackView(); header.spacing = 12
            header.addArrangedSubview(Self.label(p.title,size:18,weight:.semibold))
            let connect = button(service.settings.enabled.contains(p) ? "断开" : "连接本机账号",#selector(toggleConnection(_:)))
            connect.identifier = NSUserInterfaceItemIdentifier(p.rawValue); connect.isEnabled = !service.demo
            header.addArrangedSubview(connect)
            let muteProvider = button(service.settings.mutedProviders.contains(p) ? "取消静音" : "静音提醒",#selector(toggleProviderMute(_:)))
            muteProvider.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
            header.addArrangedSubview(muteProvider)
            if service.refreshing.contains(p) { header.addArrangedSubview(Self.label("正在读取…",size:12)) }
            content.addArrangedSubview(header)
            let text = Self.label(lines[index]); text.setAccessibilityLabel("\(p.title) 额度详情")
            content.addArrangedSubview(text)
            text.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
            let divider = NSBox(); divider.boxType = .separator; content.addArrangedSubview(divider); divider.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        }
        content.addArrangedSubview(Self.label("任务",size:16,weight:.semibold))
        content.addArrangedSubview(Self.label(sessionText.isEmpty ? "未检测到可确认的活动。无更新不代表任务完成。" : sessionText))
        content.addArrangedSubview(Self.label("最近提醒",size:16,weight:.semibold))
        content.addArrangedSubview(Self.label(recent.isEmpty ? "暂无提醒。" : recent))
    }
    private func providerText(_ provider:AIProvider)->String {
        guard let value = service.readings[provider] else {
            return service.settings.enabled.contains(provider) ? "等待首次读取…" : "尚未连接。仅连接后读取本机账号，登录失效时需回原应用登录。"
        }
        var lines:[String] = []
        if value.status != .ok { lines.append("\(statusName(value.status)) · \(value.message ?? "以下为上次记录")") }
        if value.sourceAt > Date.distantPast { lines.append("\(value.status == .ok ? "最近确认" : "历史记录")：\(relative(value.sourceAt)) · \(value.source)") }
        for limit in value.windows {
            let percent:String
            if limit.unlimited { percent = "不限额" }
            else if let f = limit.usedFraction, f.isFinite, f >= 0 {
                let left = max(0,100*(1-f)); percent = left > 0 && left < 1 ? "<1%" : "\(Int(left.rounded()))%"
            } else { percent = "暂不可用" }
            lines.append("\(limit.isExtra ? "其他 · " : "")\(limit.label)   剩余 \(percent)\n\(resetText(limit.resetAt))")
        }
        if value.status == .ok, let message = value.message { lines.append(message) }
        if value.windows.isEmpty, value.status == .ok { lines.append("账号暂未提供可识别的额度窗口。") }
        return lines.joined(separator:"\n\n")
    }
    private func relative(_ date:Date)->String {
        let mins = max(0,Int(Date().timeIntervalSince(date)/60)); return mins == 0 ? "刚刚" : "\(mins) 分钟前"
    }
    private func resetText(_ date:Date?)->String {
        guard let date else { return "暂未提供重置时间" }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "已到预计重置时间，正在确认" }
        let mins = max(1,Int(ceil(remaining/60))), days = mins/1440, hours = mins/60%24
        let duration = days > 0 ? "\(days) 天 \(hours) 小时" : hours > 0 ? "\(hours) 小时 \(mins%60) 分钟" : "\(mins) 分钟"
        let formatter = DateFormatter(); formatter.dateFormat = "M月d日 HH:mm z"
        return "\(duration)后重置 · \(formatter.string(from:date))"
    }
    private func statusName(_ s:AIStatus)->String {
        switch s { case .ok:return "正常"; case .stale:return "数据过期"; case .needsAuth:return "需要登录"; case .accessDenied:return "访问未授权"; case .unsupported:return "暂不支持"; case .error:return "更新失败"; case .disconnected:return "已断开" }
    }
    private func stateName(_ s:String)->String {
        switch s { case "busy":return "工作中";case "waiting":return "等待操作";case "ended":return "本轮结束";case "success":return "已完成";case "failure":return "失败";case "idle":return "空闲";default:return "状态未知" }
    }
    @objc private func previewBubble() { service.previewReminder() }
    @objc private func toggleProviderMute(_ sender:NSButton) {
        guard let raw = sender.identifier?.rawValue, let p = AIProvider(rawValue:raw) else { return }
        service.updateSettings { if $0.mutedProviders.contains(p) { $0.mutedProviders.remove(p) } else { $0.mutedProviders.insert(p) } }
    }
    @objc private func changeEvents() { service.updateSettings { $0.notifyEnded = ended.state == .on; $0.notifyWaiting = waiting.state == .on; $0.notifyReset = reset.state == .on } }
    @objc private func saveQuiet() {
        let text = quiet.stringValue.trimmingCharacters(in:.whitespaces)
        if text.isEmpty { service.updateSettings { $0.quietStart = nil; $0.quietEnd = nil }; return }
        let halves = text.split(separator:"-")
        func minute(_ part:Substring)->Int? {
            let pair = part.split(separator:":"); guard pair.count == 2, let h = Int(pair[0]), let m = Int(pair[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }; return h*60+m
        }
        guard halves.count == 2, let start = minute(halves[0]), let end = minute(halves[1]), start != end else { status.stringValue = "时段格式为 22:00-08:00，起止时间不能相同。"; return }
        service.updateSettings { $0.quietStart = start; $0.quietEnd = end; $0.quietOverrideUntil = nil }
    }
    @objc private func refreshNow() { service.refreshAll() }
    @objc private func toggleMute() { let wasMuted = service.isMuted; service.updateSettings { if wasMuted { $0.mutedUntil = nil; $0.quietOverrideUntil = Date().addingTimeInterval(3600) } else { $0.mutedUntil = Date().addingTimeInterval(3600) } } }
    @objc private func toggleConnection(_ sender:NSButton) {
        guard let raw = sender.identifier?.rawValue, let p = AIProvider(rawValue:raw) else { return }
        if service.settings.enabled.contains(p) { service.disconnect(p) } else { service.connect(p) }
    }
    @objc private func changeOptions(_ sender:NSButton) {
        if sender === notifications { service.enableNotifications(sender.state == .on) }
        else { service.updateSettings { $0.sound = sound.state == .on; $0.motion = motion.state == .on } }
    }
    @objc private func saveThresholds() {
        let parts = thresholds.stringValue.replacingOccurrences(of:"，",with:",").split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }
        let values = parts.compactMap(Int.init)
        guard !values.isEmpty, values.count == parts.count, values.allSatisfy({$0 >= 0 && $0 < 100}) else {
            status.stringValue = "请输入 0～99 的整数，用逗号分隔，例如 20,10,0。"; return
        }
        let sorted = Array(Set(values + [0])).sorted(by:>)
        service.updateSettings { $0.thresholds = sorted }; thresholds.stringValue = sorted.map(String.init).joined(separator:",")
    }
}
