import AppKit

/// A remaining-quota meter. Missing/old data never masquerades as a healthy quota.
private final class AIQuotaMeter: NSView {
    let fraction: Double?
    let tint: NSColor
    init(fraction:Double?, tint:NSColor) {
        self.fraction = fraction; self.tint = tint
        super.init(frame:.zero)
        heightAnchor.constraint(equalToConstant:5).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("剩余额度")
        setAccessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "未知")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect:bounds,xRadius:2.5,yRadius:2.5).fill()
        guard let fraction, fraction > 0 else { return }
        tint.setFill()
        NSBezierPath(roundedRect:NSRect(x:0,y:0,width:bounds.width * min(1,max(0,fraction)),height:bounds.height),xRadius:2.5,yRadius:2.5).fill()
    }
}
private final class AICardDocument: NSView { override var isFlipped:Bool { true } }

@MainActor
final class AIStatusPanel: NSWindowController, NSWindowDelegate {
    private unowned let service: AICompanionService
    private let content = NSStackView()
    private let footnote = NSTextField(labelWithString:"")
    private var signature = ""
    private var outsideClickMonitor: Any?

    init(service:AICompanionService) {
        self.service = service
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:360,height:210),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        panel.title = service.demo ? "奶灰 · 额度卡片（演示）" : "奶灰 · 额度卡片"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        super.init(window:panel); panel.delegate = self
        let backdrop = NSVisualEffectView(); backdrop.material = .popover; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        panel.contentView = backdrop
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 4; root.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:backdrop.leadingAnchor,constant:12),root.trailingAnchor.constraint(equalTo:backdrop.trailingAnchor,constant:-12),root.topAnchor.constraint(equalTo:backdrop.topAnchor,constant:26),root.bottomAnchor.constraint(equalTo:backdrop.bottomAnchor,constant:-8)])
        let header = NSStackView(); header.spacing = 4
        header.addArrangedSubview(Self.label("AI 额度",size:13,weight:.semibold))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal); header.addArrangedSubview(spacer)
        header.addArrangedSubview(icon("arrow.clockwise",label:"刷新额度",action:#selector(refreshNow)))
        header.addArrangedSubview(icon("gearshape",label:"提醒设置",action:#selector(settings)))
        root.addArrangedSubview(header); header.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let doc = AICardDocument(); doc.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 4; content.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content); scroll.documentView = doc
        NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),content.leadingAnchor.constraint(equalTo:doc.leadingAnchor),content.trailingAnchor.constraint(equalTo:doc.trailingAnchor,constant:-6),content.topAnchor.constraint(equalTo:doc.topAnchor),content.bottomAnchor.constraint(equalTo:doc.bottomAnchor)])
        root.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:130).isActive = true
        footnote.font = .systemFont(ofSize:10); footnote.textColor = .tertiaryLabelColor
        root.addArrangedSubview(footnote)
        panel.center(); refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    private static func label(_ text:String,size:CGFloat = 12,weight:NSFont.Weight = .regular)->NSTextField {
        let v = NSTextField(wrappingLabelWithString:text); v.font = .systemFont(ofSize:size,weight:weight); v.isSelectable = true; return v
    }
    private func icon(_ symbol:String,label:String,action:Selector)->NSButton {
        let b = NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:label)!,target:self,action:action)
        b.bezelStyle = .texturedRounded; b.toolTip = label; b.setAccessibilityLabel(label); return b
    }
    private func append(_ view:NSView,to stack:NSStackView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
    private func divider() { let line = NSBox(); line.boxType = .separator; append(line,to:content) }
    func position(near anchor:NSRect?) {
        guard let window, let anchor else { return }
        let screen = NSScreen.screens.first(where:{$0.frame.intersects(anchor)}) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let x = min(visible.maxX-size.width-8,max(visible.minX+8,anchor.midX-size.width/2))
        let y = min(visible.maxY-size.height-8,max(visible.minY+8,anchor.minY-size.height-8))
        window.setFrameOrigin(NSPoint(x:x,y:y))
    }
    func refresh() {
        footnote.stringValue = service.demo ? "演示数据 · 未连接真实账号" : service.isMuted ? "免打扰中 · 数据仍会更新" : "只读监控 · 数据按平台刷新"
        let now = Date()
        let encoded = (try? JSONEncoder().encode(Array(service.readings.values).sorted { $0.provider.rawValue < $1.provider.rawValue })) ?? Data()
        let key = (service.settings.resetTimeFormat?.rawValue ?? "automatic") + encoded.base64EncodedString() + service.sessions.map { "\($0.id)\($0.state)\($0.evidence)" }.joined() + service.settings.enabled.map(\.rawValue).sorted().joined() + service.refreshing.map(\.rawValue).sorted().joined() + String(Int(now.timeIntervalSince1970/30))
        guard key != signature else { return }; signature = key
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        let columns = NSStackView(); columns.orientation = .horizontal; columns.alignment = .top; columns.spacing = 16; columns.distribution = .fillEqually
        append(columns,to:content)
        for p in AIProvider.allCases {
            let section = NSStackView(); section.orientation = .vertical; section.alignment = .leading; section.spacing = 2
            columns.addArrangedSubview(section)
            let usage = service.readings[p]
            let valid = usage?.status == .ok && now.timeIntervalSince(usage?.sourceAt ?? .distantPast) <= 900
            let header = NSStackView(); header.spacing = 4
            let name = Self.label(p.title,size:13,weight:.semibold); header.addArrangedSubview(name)
            let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal); header.addArrangedSubview(spacer)
            let state = Self.label(service.refreshing.contains(p) ? "更新中…" : usage.map { stateText($0.status) } ?? "未连接",size:10)
            state.textColor = valid ? .secondaryLabelColor : .tertiaryLabelColor
            header.addArrangedSubview(state); append(header,to:section)
            if let usage, !usage.windows.isEmpty {
                for limit in usage.windows.filter({ !$0.isExtra }) { windowRow(limit,valid:valid,to:section) }
                let extras = usage.windows.filter(\.isExtra).count
                if extras > 0 { let more = Self.label("另有 \(extras) 个额度窗口，可在设置查看",size:10); more.textColor = .secondaryLabelColor; append(more,to:section) }
                let mins = max(0,Int(now.timeIntervalSince(usage.sourceAt)/60))
                let freshness = Self.label(valid ? (mins == 0 ? "刚刚确认" : "\(mins) 分钟前确认") : "历史记录 · \(mins) 分钟前",size:10)
                header.toolTip = freshness.stringValue
                if !valid { freshness.textColor = .tertiaryLabelColor; append(freshness,to:section) }
                if !valid, let message = usage.message { let info = Self.label(message,size:10); info.textColor = .secondaryLabelColor; append(info,to:section) }
            } else {
                let empty = Self.label(usage?.message ?? (service.settings.enabled.contains(p) ? "正在读取账号额度…" : "连接后显示剩余额度与重置时间。"))
                empty.textColor = .secondaryLabelColor; append(empty,to:section)
                // Unknown is visually grey, never a false 0% or a full green bar.
                append(AIQuotaMeter(fraction:nil,tint:.tertiaryLabelColor),to:section)
                let connect = NSButton(title:service.settings.enabled.contains(p) ? "连接设置" : "连接 \(p.title)",target:self,action:#selector(connect(_:)))
                connect.identifier = .init(p.rawValue); connect.bezelStyle = .rounded; connect.isEnabled = !service.demo
                section.addArrangedSubview(connect)
            }
        }
        divider()
        let title = Self.label(service.sessions.isEmpty ? "任务 · 暂无可确认的活动" : "任务状态",size:11,weight:.semibold); title.textColor = .secondaryLabelColor; append(title,to:content)
        if !service.sessions.isEmpty {
            for p in AIProvider.allCases {
                let list = service.sessions.filter { $0.provider == p }; guard !list.isEmpty else { continue }
                let waiting = list.filter { $0.state == "waiting" }.count
                let busy = list.filter { $0.state == "busy" }.count
                let text = waiting > 0 ? "\(waiting) 个等待操作" : busy > 0 ? "\(busy) 个活动中" : list.contains(where:{["ended","success"].contains($0.state)}) ? "本轮结束" : list.contains(where:{$0.state == "idle"}) ? "空闲" : "状态未知"
                let row = Self.label("\(p.title)   \(text)",size:12); row.textColor = waiting > 0 ? .systemOrange : .labelColor; append(row,to:content)
            }
        }
    }
    private func windowRow(_ limit:AILimit,valid:Bool,to stack:NSStackView) {
        let fraction = limit.usedFraction.flatMap { $0.isFinite && $0 >= 0 ? max(0,1-$0) : nil }
        let color:NSColor = !valid || fraction == nil ? .tertiaryLabelColor : fraction! <= 0.10 ? .systemRed : fraction! <= 0.20 ? .systemOrange : .systemGreen
        let line = NSStackView(); line.spacing = 8
        line.addArrangedSubview(Self.label(limit.label,size:11))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal); line.addArrangedSubview(spacer)
        let percent:String = limit.unlimited ? "不限额" : fraction.map { $0 > 0 && $0 < 0.01 ? "剩余 <1%" : "剩余 \(Int(($0*100).rounded()))%" } ?? "未知"
        let value = Self.label(percent,size:12,weight:.semibold); value.textColor = color; line.addArrangedSubview(value)
        append(line,to:stack); append(AIQuotaMeter(fraction:limit.unlimited ? nil : fraction,tint:color),to:stack)
        let countdown = Self.label(resetText(limit.resetAt),size:10); countdown.textColor = .secondaryLabelColor
        if let date = limit.resetAt { countdown.toolTip = date.formatted(date:.complete,time:.shortened) }
        append(countdown,to:stack)
    }
    private func resetText(_ date:Date?)->String {
        guard let date else { return "暂未提供重置时间" }
        return ResetCopy.text(for:date,format:service.settings.resetTimeFormat ?? .automatic)
    }
    private func stateText(_ state:AIStatus)->String {
        switch state { case .ok:return "已连接";case .stale:return "已过期";case .needsAuth:return "需登录";case .accessDenied:return "未授权";case .unsupported:return "暂不支持";case .error:return "更新失败";case .disconnected:return "未连接" }
    }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
    }
    private func dismiss() {
        window?.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
    }
    func windowDidResignKey(_ notification:Notification) { dismiss() }
    func windowWillClose(_ notification:Notification) { dismiss() }
    @objc private func refreshNow() { service.refreshAll() }
    @objc private func settings() { service.showSettings() }
    @objc private func connect(_ sender:NSButton) {
        guard let raw = sender.identifier?.rawValue, let p = AIProvider(rawValue:raw) else { return }
        if service.settings.enabled.contains(p) { service.showSettings() } else { service.connect(p) }
    }
}
