import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "." as JellyCore

Rectangle {
  id: root

  property bool opened: false
  property bool confirmClear: false
  property bool tokenExpanded: false
  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(foreground, 1.55)
  property color urgentForeground: Color.urgent
  property string fontFamily: Style.font.family
  property Component iconComponent
  signal dismissRequested()
  readonly property bool pairing: JellyCore.JellyfinState.authenticationState === "starting"
    || JellyCore.JellyfinState.authenticationState === "waiting"
  readonly property bool inputFocused: serverField.activeFocus || usernameField.activeFocus
    || passwordField.activeFocus || tokenField.activeFocus
    || saveSettingsButton.activeFocus || closeSettingsButton.activeFocus
    || clearSettingsButton.activeFocus || advancedButton.activeFocus
    || quickConnectButton.activeFocus || cancelQuickConnectButton.activeFocus
  readonly property real contentImplicitHeight: settingsColumn.implicitHeight
  function formattedQuickConnectCode() {
    var code = JellyCore.JellyfinState.quickConnectCode
    if (code.length === 6) return code.slice(0, 3) + "  " + code.slice(3)
    if (code.length === 8) return code.slice(0, 4) + "  " + code.slice(4)
    return code
  }

  visible: opened
  color: Color.background

  function open() {
    confirmClear = false
    opened = true
    tokenExpanded = false
    serverField.text = JellyCore.JellyfinState.connectionServer
    usernameField.text = ""
    passwordField.text = ""
    tokenField.text = ""
    Qt.callLater(function() { serverField.forceActiveFocus() })
  }

  function close() {
    if (JellyCore.JellyfinState.authenticationState !== "idle") {
      JellyCore.JellyfinState.cancelQuickConnect()
      return
    }
    if (!JellyCore.JellyfinState.configured) {
      dismissRequested()
      return
    }
    dismiss()
  }

  function dismiss() {
    opened = false
    confirmClear = false
    passwordField.text = ""
    tokenField.text = ""
    tokenExpanded = false
  }

  function submit() {
    var submitted = JellyCore.JellyfinState.configure({
      server: serverField.text,
      username: usernameField.text,
      password: passwordField.text,
      token: tokenField.text
    })
    if (submitted) {
      passwordField.text = ""
      tokenField.text = ""
    }
  }

  function finishConfiguration(success) {
    if (!success) return
    opened = false
    confirmClear = false
  }

  function syncServer() {
    if (opened)
      serverField.text = JellyCore.JellyfinState.connectionServer
  }

  function librarySummary() {
    var libraries = JellyCore.JellyfinState.musicLibraries
    return libraries.length ? "Music · " + libraries.map(function(item) { return item.title || item.id }).join(", ")
      : "Browse your music collection from the bar."
  }
  Flickable {
    anchors.fill: parent
    contentWidth: width
    contentHeight: settingsColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height

    Column {
      id: settingsColumn
      width: parent.width
      spacing: Style.space(10)

      PanelHero {
        width: parent.width
        iconComponent: root.iconComponent
        title: "Jellyfin"
        meta: JellyCore.JellyfinState.configured ? "Settings" : "Connect to Jellyfin"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      PanelSeparator { foreground: root.foreground }

      Text {
        visible: JellyCore.JellyfinState.lastError !== ""
        width: parent.width
        text: JellyCore.JellyfinState.safeText(JellyCore.JellyfinState.lastError, 220)
        textFormat: Text.PlainText
        color: root.urgentForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        visible: JellyCore.JellyfinState.setupMessage !== ""
        width: parent.width
        text: JellyCore.JellyfinState.safeText(JellyCore.JellyfinState.setupMessage, 220)
        textFormat: Text.PlainText
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Column {
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          width: parent.width
          text: "SERVER"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          visible: JellyCore.JellyfinState.configured
          width: parent.width
          text: (JellyCore.JellyfinState.authenticationMode === "quickconnect"
            ? "Signed in with Quick Connect"
            : (JellyCore.JellyfinState.authenticationMode === "password"
              ? "Signed in with username" : "API key connection"))
            + " · " + (JellyCore.JellyfinState.connectionName
              || JellyCore.JellyfinState.connectionServer)
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: JellyCore.JellyfinState.configured
          width: parent.width
          text: root.librarySummary()
          textFormat: Text.PlainText
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        TextField {
          id: serverField
          width: parent.width
          placeholderText: "http://media/jellyfin"
          maximumLength: 512
          foreground: root.foreground
          font.family: root.fontFamily
          enabled: !JellyCore.JellyfinState.updating && !JellyCore.JellyfinState.authenticating
          inputMethodHints: Qt.ImhUrlCharactersOnly
          onAccepted: JellyCore.JellyfinState.startQuickConnect(serverField.text)
          Keys.onEscapePressed: root.close()
        }

        Text {
          width: parent.width
          text: "Use the Jellyfin base URL, including a reverse-proxy path if you have one."
          textFormat: Text.PlainText
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Button {
          id: quickConnectButton
          width: parent.width
          text: JellyCore.JellyfinState.authenticationState === "starting"
            ? "Getting a code…"
            : (JellyCore.JellyfinState.authenticationState === "waiting"
              ? "Waiting for a signed-in app…"
              : (JellyCore.JellyfinState.authenticationMode === "quickconnect"
                ? "Get a new Quick Connect code" : "Get a Quick Connect code"))
          iconText: root.pairing ? "󰑐" : ""
          iconSpinning: root.pairing
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          focusable: true
          enabled: !JellyCore.JellyfinState.updating && !JellyCore.JellyfinState.authenticating
          onClicked: JellyCore.JellyfinState.startQuickConnect(serverField.text)
          Keys.onEscapePressed: root.close()
        }

        Text {
          visible: JellyCore.JellyfinState.quickConnectCode !== ""
          width: parent.width
          text: root.formattedQuickConnectCode()
          textFormat: Text.PlainText
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          font.letterSpacing: Style.space(1)
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          width: parent.width
          text: root.pairing
            ? "On a signed-in Jellyfin app, open the profile menu → Quick Connect and enter the code."
            : "Creates a short code. Enter it in a Jellyfin app that is already signed in."
          textFormat: Text.PlainText
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Button {
          id: cancelQuickConnectButton
          visible: root.pairing
          width: parent.width
          text: "Cancel code"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          focusable: true
          enabled: true
          onClicked: JellyCore.JellyfinState.cancelQuickConnect()
          Keys.onEscapePressed: root.close()
        }

        Column {
          visible: JellyCore.JellyfinState.configured && !root.pairing
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            width: parent.width
            text: "PASSWORD SIGN-IN"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          TextField {
            id: usernameField
            width: parent.width
            placeholderText: "Jellyfin username"
            maximumLength: 128
            foreground: root.foreground
            font.family: root.fontFamily
            enabled: !JellyCore.JellyfinState.updating && !JellyCore.JellyfinState.authenticating
            onAccepted: passwordField.forceActiveFocus()
            Keys.onEscapePressed: root.close()
          }

          TextField {
            id: passwordField
            width: parent.width
            placeholderText: JellyCore.JellyfinState.configured
              ? "Leave blank to reuse sign-in for the same server" : "Jellyfin password"
            echoMode: TextInput.Password
            maximumLength: 256
            foreground: root.foreground
            font.family: root.fontFamily
            enabled: !JellyCore.JellyfinState.updating && !JellyCore.JellyfinState.authenticating
            onAccepted: root.submit()
            Keys.onEscapePressed: root.close()
          }

          Button {
            id: saveSettingsButton
            width: parent.width
            text: JellyCore.JellyfinState.configuring ? "Testing connection…" : "Test and save connection"
            iconText: JellyCore.JellyfinState.configuring ? "󰑐" : ""
            iconSpinning: JellyCore.JellyfinState.configuring
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            focusable: true
            enabled: !JellyCore.JellyfinState.updating && !JellyCore.JellyfinState.authenticating
            onClicked: root.submit()
          }

          Button {
            id: advancedButton
            width: parent.width
            text: root.tokenExpanded ? "Hide API key" : "Use an API key instead"
            foreground: root.dimForeground
            fontFamily: root.fontFamily
            bordered: false
            focusable: true
            enabled: !JellyCore.JellyfinState.updating && !JellyCore.JellyfinState.authenticating
            onClicked: {
              root.tokenExpanded = !root.tokenExpanded
              if (root.tokenExpanded) Qt.callLater(function() { tokenField.forceActiveFocus() })
            }
            Keys.onEscapePressed: root.close()
          }

          Column {
            visible: root.tokenExpanded
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: tokenField
              width: parent.width
              placeholderText: JellyCore.JellyfinState.configured
                ? "Leave blank to reuse sign-in for the same server" : "Dashboard → API Keys"
              echoMode: TextInput.Password
              maximumLength: 8192
              foreground: root.foreground
              font.family: root.fontFamily
              enabled: !JellyCore.JellyfinState.updating && !JellyCore.JellyfinState.authenticating
              onAccepted: root.submit()
              Keys.onEscapePressed: root.close()
            }

            Text {
              width: parent.width
              text: "Create a dedicated key so this machine can be revoked on its own."
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            width: parent.width
            text: "Passwords and API keys go to the helper over stdin and the desktop secret service. They are never written to plugin settings, command lines, logs, or cache."
            textFormat: Text.PlainText
            color: root.dimForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
      Row {
        width: parent.width
        spacing: Style.space(5)

        Button {
          id: closeSettingsButton
          width: JellyCore.JellyfinState.configured
            ? (parent.width - parent.spacing) / 2 : parent.width
          text: "Close"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          focusable: true
          enabled: !JellyCore.JellyfinState.configuring
          onClicked: root.close()
        }

        Button {
          id: clearSettingsButton
          visible: JellyCore.JellyfinState.configured
          width: (parent.width - parent.spacing) / 2
          text: root.confirmClear ? "Confirm remove" : "Remove credentials"
          foreground: root.confirmClear ? root.urgentForeground : root.foreground
          fontFamily: root.fontFamily
          bordered: true
          focusable: true
          enabled: !JellyCore.JellyfinState.updating && !JellyCore.JellyfinState.authenticating
          onClicked: {
            if (root.confirmClear) {
              if (JellyCore.JellyfinState.clearConfiguration()) root.confirmClear = false
            } else root.confirmClear = true
          }
        }
      }
    }
  }
}
