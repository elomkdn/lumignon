import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string backend: "python3 '"
        + decodeURIComponent(Qt.resolvedUrl("../code/lumignon_backend.py").toString().replace("file://", "")) + "'"

    // Quotas and statistics of every agent, refreshed from the backend
    property var agents: ({})
    property real now: Date.now() / 1000
    property bool refreshing: false

    readonly property var agentNames: ({ "claude": "Claude", "codex": "Codex", "opencode": "OpenCode" })
    readonly property var installedAgents: ["claude", "codex", "opencode"].filter(a => agents[a] && agents[a].installed)
    readonly property string agent: installedAgents.indexOf(Plasmoid.configuration.agent) >= 0
        ? Plasmoid.configuration.agent : (installedAgents[0] || "claude")
    readonly property string agentName: agentNames[agent]
    readonly property var current: agents[agent] || ({})
    readonly property var windows: current.windows || []
    readonly property var days: current.days || [0, 0, 0, 0, 0, 0, 0]
    readonly property bool hasQuota: windows.length > 0

    // The window closest to its limit drives the candle
    readonly property var mainWindow: {
        let best = null
        for (const w of windows)
            if (!best || currentUse(w) > currentUse(best)) best = w
        return best
    }
    readonly property real usedMain: currentUse(mainWindow)
    readonly property bool limited: windows.some(w => isLimited(w))
    // Any agent at work wakes the candle up
    readonly property real lastActivity: Math.max(0, ...Object.values(agents).map(a => a.lastActivity || 0))

    // Conversation
    ListModel { id: conversation }
    readonly property alias messages: conversation
    property string session: ""
    property string requestId: ""
    property bool busy: false
    property bool unread: false
    property string activity: ""
    property string model: Plasmoid.configuration.model
    property bool hovered: false

    readonly property string mood: {
        if (limited) return "ko"
        if (busy) return "think"
        if (unread) return "happy"
        if (hovered) return "wave"
        if (expanded) return usedMain >= 0.8 ? "tired" : "idle"
        if (usedMain >= 0.8) return "tired"
        if (now - lastActivity < 60) return "work"
        if (lastActivity > 0 && now - lastActivity > 1800) return "sleep"
        return "idle"
    }

    preferredRepresentation: compactRepresentation
    compactRepresentation: CompactView { app: root }
    fullRepresentation: FullView { app: root }
    switchWidth: Kirigami.Units.gridUnit * 16
    switchHeight: Kirigami.Units.gridUnit * 16
    Plasmoid.status: busy || unread || limited ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus

    toolTipMainText: agentName
    toolTipSubText: limited ? i18n("Limit reached. %1", resetPhrase(windows.find(w => isLimited(w))))
        : hasQuota ? windows.map(w => i18nc("window: share used", "%1: %2%", windowLabel(w), Math.round(currentUse(w) * 100))).join("   ·   ")
        : i18n("Click to ask a question")

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Open %1 in a terminal", root.agentName)
            icon.name: "utilities-terminal"
            onTriggered: root.openTerminal()
        },
        PlasmaCore.Action {
            text: i18n("Refresh usage")
            icon.name: "view-refresh"
            onTriggered: root.refreshNow()
        }
    ]

    onExpandedChanged: {
        if (root.expanded) {
            unread = false
            loadUsage()
        }
    }

    function currentUse(w) {
        if (!w) return 0
        return w.resetsAt <= now ? 0 : w.utilization
    }
    function isLimited(w) {
        return !!w && w.resetsAt > now && (w.status === "rejected" || w.utilization >= 1)
    }
    function windowLabel(w) {
        if (!w || w.limit || !w.minutes) return i18n("Limit")
        if (w.minutes % 1440 === 0) return i18nc("a number of days, short", "%1 d", w.minutes / 1440)
        if (w.minutes % 60 === 0) return i18nc("a number of hours, short", "%1 h", w.minutes / 60)
        return i18nc("a number of minutes, short", "%1 min", w.minutes)
    }
    function formatDate(seconds) {
        return new Date(seconds * 1000).toLocaleString(Qt.locale(), "ddd d MMM HH:mm")
    }
    function resetPhrase(w) {
        if (!w) return ""
        const left = w.resetsAt - now
        if (left <= 0) return i18n("Window free")
        if (left < 3600) return i18n("Resets in %1 min", Math.max(1, Math.round(left / 60)))
        if (left < 86400) return i18n("Resets in %1 h %2", Math.floor(left / 3600), String(Math.floor(left % 3600 / 60)).padStart(2, "0"))
        return i18n("Resets %1", formatDate(w.resetsAt))
    }
    function activityText(a) {
        if (!a) return ""
        switch (a.kind) {
        case "read": return a.detail ? i18n("Reading %1", a.detail) : i18n("Reading a file")
        case "search": return i18n("Searching “%1”", a.detail || "")
        case "fetch": return i18n("Reading a web page")
        case "files": return i18n("Looking through files")
        case "command": return a.detail ? i18n("Running %1", a.detail) : i18n("Running a command")
        case "thinking": return i18n("Thinking")
        default: return i18n("Using %1", a.detail || "")
        }
    }
    function errorText(e, agentId) {
        const name = agentNames[agentId] || agentName
        if (!e) return i18n("%1 could not answer.", name)
        if (typeof e === "string") return e
        switch (e.code) {
        case "api_key": return i18n("%1 is set up with an API key, and Lumignon only uses subscriptions. Request cancelled.", name)
        case "logged_out": return i18n("%1 is not signed in. Open it in a terminal to sign in.", name)
        case "limit": return e.until ? i18n("%1 limit reached. It comes back %2.", name, formatDate(e.until))
                                      : i18n("%1 limit reached.", name)
        case "launch": return i18n("Could not start %1: %2", name, e.detail || "")
        case "worker_died": return i18n("The answer process stopped.")
        case "raw": return e.detail
        default: return i18n("%1 could not answer.", name)
        }
    }
    function shellQuote(text) {
        return "'" + text.split("'").join("'\\''") + "'"
    }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        onNewData: (source, data) => {
            disconnectSource(source)
            const callback = callbacks[source]
            delete callbacks[source]
            if (callback) callback(data["stdout"] || "", data["stderr"] || "", data["exit code"])
        }
        function run(command, callback) {
            callbacks[command] = callback
            connectSource(command)
        }
    }

    function loadUsage() {
        exec.run(backend + " usage", (out) => {
            let data
            try { data = JSON.parse(out) } catch (e) { return }
            agents = data.agents || {}
            now = data.now
        })
    }
    function refreshNow() {
        if (agent !== "claude") {  // only Claude's quota can be measured on demand
            loadUsage()
            return
        }
        refreshing = true
        exec.run(backend + " ping --force", () => {
            refreshing = false
            loadUsage()
        })
    }
    function openTerminal() {
        exec.run(backend + " terminal " + agent + " " + shellQuote(session))
    }
    function setAgent(id) {
        if (busy || id === agent) return
        conversation.clear()
        session = ""
        Plasmoid.configuration.agent = id
    }

    function ask(question) {
        const text = question.trim()
        if (!text || busy) return
        if (text.length > 50000) {
            conversation.append({ role: "error", text: i18n("This question is too long for the widget: use the terminal.") })
            return
        }
        conversation.append({ role: "user", text: text })
        conversation.append({ role: "agent", text: "" })
        requestId = String(Date.now())
        activity = ""
        busy = true
        const chosenModel = agent === "claude" ? model : ""
        exec.run(backend + " ask " + requestId + " " + agent + " " + shellQuote(chosenModel) + " " + shellQuote(session) + " " + shellQuote(text), (out, err, code) => {
            if (code !== 0) finish("error", err.trim() || i18n("Could not start the backend."))
        })
    }
    function stop() {
        exec.run(backend + " stop")
    }
    function newConversation() {
        if (busy) return
        conversation.clear()
        session = ""
    }
    function finish(status, errorMessage) {
        busy = false
        activity = ""
        const last = conversation.count - 1
        if (status === "error") {
            if (last >= 0 && conversation.get(last).text === "") conversation.remove(last)
            conversation.append({ role: "error", text: errorMessage })
        } else if (last >= 0 && conversation.get(last).text === "") {
            conversation.remove(last)
        }
        if (!expanded) unread = true
        loadUsage()
    }
    function pollAnswer() {
        exec.run('cat "${XDG_CACHE_HOME:-$HOME/.cache}/lumignon/answer.json"', (out) => {
            if (!busy) return
            let state
            try { state = JSON.parse(out) } catch (e) { return }
            if (state.id !== requestId) return
            if (state.session) session = state.session
            activity = activityText(state.activity)
            const last = conversation.count - 1
            if (last >= 0 && conversation.get(last).role === "agent" && conversation.get(last).text !== state.text)
                conversation.setProperty(last, "text", state.text)
            if (state.status !== "running")
                finish(state.status, state.status === "error" ? errorText(state.error, state.agent) : "")
        })
    }

    Timer {
        running: root.busy
        repeat: true
        interval: 200
        onTriggered: root.pollAnswer()
    }
    Timer {
        running: true
        repeat: true
        triggeredOnStart: true
        interval: 30000
        onTriggered: root.loadUsage()
    }
    Timer {
        running: true
        repeat: true
        interval: 15000
        onTriggered: root.now = Date.now() / 1000
    }
}
