pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property bool installed: false
  property bool initialized: false
  property bool configured: false
  property bool settingsRequested: false
  property string lastError: ""
  property string connectionServer: ""
  property string connectionName: ""
  property string authenticationMode: ""
  property string authenticationState: "idle"
  property string quickConnectCode: ""
  property var musicLibraries: []
  property string setupMessage: ""
  property string _statusOutput: ""
  property string _statusError: ""
  property string _setupOutput: ""
  property string _setupError: ""
  property string _setupPayload: ""
  property string _clearOutput: ""
  property string _clearError: ""
  property string _authOutput: ""
  property string _authError: ""
  signal configurationFinished(bool success, string detail)

  readonly property string pluginRoot: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/io.github.supergeoffofohio.omajellymusic"
  readonly property string helperCommand: pluginRoot + "/bin/omajelly"
  readonly property bool configuring: setupProcess.running
  readonly property bool clearingConfiguration: clearProcess.running
  readonly property bool authenticating: authenticationState !== "idle"
    || authStartProcess.running || authPollProcess.running || authCancelProcess.running
  readonly property bool settingsBusy: configuring || clearingConfiguration
    || authStartProcess.running || authPollProcess.running || authCancelProcess.running
  readonly property bool updating: statusProcess.running || settingsBusy
  signal popupRequested(string action)
  signal refreshRequested()

  function safeText(value, maximum) {
    return Model.plainText(value, maximum || 220)
  }

  function normalizeLibraries(value) {
    if (!(value instanceof Array) || value.length > 16)
      throw new Error("Jellyfin returned invalid library settings")
    var result = []
    for (var index = 0; index < value.length; index++) {
      var library = value[index]
      var id = String(library && library.id || "")
      if (!/^[0-9a-fA-F-]{8,48}$/.test(id) || !library || typeof library.title !== "string")
        throw new Error("Jellyfin returned invalid library settings")
      result.push({ id: id, title: safeText(library.title, 128) })
    }
    return result
  }

  function applyConnection(value) {
    if (!value) return
    if (typeof value.server !== "string" || typeof value.serverName !== "string"
        || typeof value.authMode !== "string")
      throw new Error("Jellyfin returned invalid connection settings")
    connectionServer = safeText(value.server, 512)
    connectionName = safeText(value.serverName, 128)
    authenticationMode = value.authMode === "password" ? "password"
      : (value.authMode === "quickconnect" ? "quickconnect"
        : (value.authMode === "token" ? "token" : ""))
    musicLibraries = normalizeLibraries(value.musicLibraries || [])
  }

  function applyDocument(raw) {
    var value = JSON.parse(String(raw || ""))
    applyConnection(value.connection)
    configured = value.configured === true
    lastError = value.error || ""
    initialized = true
  }

  function loadStatus() {
    if (!installed || statusProcess.running || settingsBusy) return false
    _statusOutput = ""
    _statusError = ""
    statusProcess.command = ["timeout", "--signal=TERM", "12", helperCommand, "status"]
    statusProcess.running = true
    return true
  }

  function configure(values) {
    if (!installed || statusProcess.running
        || settingsBusy || authenticating)
      return false
    var server = safeText(values.server, 512)
    var username = safeText(values.username, 128)
    var password = String(values.password || "")
    var token = String(values.token || "")
    if (server === "") {
      lastError = "Enter the Jellyfin server URL"
      return false
    }
    var hasPassword = username !== "" && password !== ""
    var hasToken = token !== ""
    if (!configured && !hasPassword && !hasToken) {
      lastError = "Enter a username and password, or an API key"
      return false
    }
    if (username !== "" && password === "" && !configured && !hasToken) {
      lastError = "Enter the Jellyfin password"
      return false
    }
    if (password.length > 256) {
      lastError = "The password is too long"
      return false
    }
    if (token.length > 8192) {
      lastError = "The API key is too long"
      return false
    }
    _setupOutput = ""
    _setupError = ""
    _setupPayload = JSON.stringify({
      server: server,
      username: username,
      password: password,
      token: token
    })
    password = ""
    token = ""
    lastError = ""
    setupMessage = ""
    setupProcess.command = ["timeout", "--signal=TERM", "35", helperCommand, "configure"]
    setupProcess.running = true
    return true
  }

  function startQuickConnect(server) {
    if (!installed || statusProcess.running
        || settingsBusy || authenticating)
      return false
    var origin = safeText(server, 512)
    if (origin === "") {
      lastError = "Enter the Jellyfin server URL"
      return false
    }
    _authOutput = ""
    _authError = ""
    quickConnectCode = ""
    authenticationState = "starting"
    lastError = ""
    setupMessage = "Getting a Quick Connect code…"
    authStartProcess.command = [
      "timeout", "--signal=TERM", "25", helperCommand, "quick-connect-start",
      "--server", origin
    ]
    authStartProcess.running = true
    return true
  }

  function pollQuickConnect() {
    if (authenticationState !== "waiting" || authPollProcess.running)
      return false
    _authOutput = ""
    _authError = ""
    authPollProcess.command = [
      "timeout", "--signal=TERM", "25", helperCommand, "quick-connect-poll"
    ]
    authPollProcess.running = true
    return true
  }

  function cancelQuickConnect() {
    if (!authenticating || authCancelProcess.running) return false
    authPollTimer.stop()
    authenticationState = "idle"
    quickConnectCode = ""
    setupMessage = ""
    _authError = ""
    authCancelProcess.command = [
      "timeout", "--signal=TERM", "12", helperCommand, "quick-connect-cancel"
    ]
    authCancelProcess.running = true
    return true
  }

  function clearConfiguration() {
    if (!installed || statusProcess.running || settingsBusy)
      return false
    _clearOutput = ""
    _clearError = ""
    lastError = ""
    setupMessage = ""
    clearProcess.command = ["timeout", "--signal=TERM", "12", helperCommand, "clear-configuration"]
    clearProcess.running = true
    return true
  }

  IpcHandler {
    target: "io.github.supergeoffofohio.omajellymusic"

    function open() { root.popupRequested("summon") }
    function close() { root.popupRequested("hide") }
    function show() { root.popupRequested("summon") }
    function hide() { root.popupRequested("hide") }
    function toggle() { root.popupRequested("toggle") }

    function refresh(): string { root.refreshRequested(); return "Music library refresh requested" }
    function settings(): string {
      root.settingsRequested = true
      root.popupRequested("summon")
      return "Jellyfin connection settings opened"
    }

    function status(): string {
      return JSON.stringify({configured: root.configured, updating: root.updating, error: root.lastError})
    }
  }

  Timer {
    id: authPollTimer
    interval: 2000
    repeat: true
    onTriggered: root.pollQuickConnect()
  }

  Process {
    id: whichProcess
    running: true
    command: ["test", "-x", root.helperCommand]
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.loadStatus()
      else {
        root.initialized = true
        root.lastError = "Bundled Jellyfin helper is missing"
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: root._statusOutput = text
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
      onStreamFinished: root._statusError = text
    }
    onExited: function(exitCode) {
      var stdout = String(root._statusOutput || statusStdout.text || "")
      var stderr = String(root._statusError || statusStderr.text || "")
      if (exitCode !== 0) {
        root.initialized = true
        root.lastError = root.safeText(stderr || "Could not read saved Jellyfin data", 220)
        return
      }
      try {
        root.applyDocument(stdout)
      } catch (error) {
        root.initialized = true
        root.lastError = root.safeText(error, 220)
      }
    }
  }

  Process {
    id: setupProcess
    running: false
    command: []
    stdinEnabled: true
    onStarted: {
      write(root._setupPayload + "\n")
      root._setupPayload = ""
    }
    stdout: StdioCollector {
      id: setupStdout
      waitForEnd: true
      onStreamFinished: root._setupOutput = text
    }
    stderr: StdioCollector {
      id: setupStderr
      waitForEnd: true
      onStreamFinished: root._setupError = text
    }
    onExited: function(exitCode) {
      root._setupPayload = ""
      var stdout = String(root._setupOutput || setupStdout.text || "")
      var stderr = String(root._setupError || setupStderr.text || "")
      try {
        if (exitCode !== 0) throw new Error(stderr || "Jellyfin setup failed")
        root.applyDocument(stdout)
        root.setupMessage = "Connected to " + (root.connectionName || root.connectionServer)
        root.configurationFinished(true, root.setupMessage)
      } catch (error) {
        root.lastError = root.safeText(stderr || (exitCode === 124
          ? "Jellyfin setup exceeded thirty seconds" : error), 220)
        root.configurationFinished(false, root.lastError)
      }
    }
  }

  Process {
    id: authStartProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: authStartStdout
      waitForEnd: true
      onStreamFinished: root._authOutput = text
    }
    stderr: StdioCollector {
      id: authStartStderr
      waitForEnd: true
      onStreamFinished: root._authError = text
    }
    onExited: function(exitCode) {
      var stdout = String(root._authOutput || authStartStdout.text || "")
      var stderr = String(root._authError || authStartStderr.text || "")
      try {
        if (exitCode !== 0) throw new Error(stderr || "Could not start Quick Connect")
        var document = JSON.parse(stdout)
        var code = String(document && document.code || "")
        if (!document || document.state !== "pending" || !/^\d{4,8}$/.test(code))
          throw new Error("Jellyfin returned an invalid Quick Connect code")
        root.quickConnectCode = code
        root.authenticationState = "waiting"
        root.setupMessage = "Enter this code in a Jellyfin app that is already signed in."
        authPollTimer.restart()
      } catch (error) {
        root.authenticationState = "idle"
        root.quickConnectCode = ""
        root.lastError = root.safeText(stderr || error, 220)
        root.setupMessage = ""
        root.configurationFinished(false, root.lastError)
      }
    }
  }

  Process {
    id: authPollProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: authPollStdout
      waitForEnd: true
      onStreamFinished: root._authOutput = text
    }
    stderr: StdioCollector {
      id: authPollStderr
      waitForEnd: true
      onStreamFinished: root._authError = text
    }
    onExited: function(exitCode) {
      if (root.authenticationState === "idle") return
      var stdout = String(root._authOutput || authPollStdout.text || "")
      var stderr = String(root._authError || authPollStderr.text || "")
      try {
        if (exitCode !== 0) throw new Error(stderr || "Could not finish Quick Connect")
        var document = JSON.parse(stdout)
        if (document && document.state === "pending") {
          var code = String(document.code || "")
          if (/^\d{4,8}$/.test(code)) root.quickConnectCode = code
          return
        }
        authPollTimer.stop()
        root.applyDocument(stdout)
        root.authenticationState = "idle"
        root.quickConnectCode = ""
        root.setupMessage = "Connected to " + (root.connectionName || root.connectionServer)
        root.configurationFinished(true, root.setupMessage)
      } catch (error) {
        authPollTimer.stop()
        root.authenticationState = "idle"
        root.quickConnectCode = ""
        root.lastError = root.safeText(stderr || error, 220)
        root.setupMessage = "Quick Connect stopped. Try again."
        root.configurationFinished(false, root.lastError)
      }
    }
  }

  Process {
    id: authCancelProcess
    running: false
    command: []
    stderr: StdioCollector {
      id: authCancelStderr
      waitForEnd: true
      onStreamFinished: root._authError = text
    }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.lastError = root.safeText(
          root._authError || authCancelStderr.text || "Could not cancel Quick Connect",
          220
        )
    }
  }

  Process {
    id: clearProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: clearStdout
      waitForEnd: true
      onStreamFinished: root._clearOutput = text
    }
    stderr: StdioCollector {
      id: clearStderr
      waitForEnd: true
      onStreamFinished: root._clearError = text
    }
    onExited: function(exitCode) {
      var stdout = String(root._clearOutput || clearStdout.text || "")
      var stderr = String(root._clearError || clearStderr.text || "")
      try {
        if (exitCode !== 0) throw new Error(stderr || "Could not clear Jellyfin settings")
        root.applyDocument(stdout)
        root.setupMessage = "Connection settings cleared"
      } catch (error) {
        root.lastError = root.safeText(stderr || error, 220)
      }
    }
  }

}
