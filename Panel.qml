import QtQuick.Controls as QQC
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "." as JellyCore

Panel {
  id: root
  moduleName: "io.github.supergeoffofohio.omajellymusic"
  ipcTarget: "io.github.supergeoffofohio.omajellymusic"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property alias settingsOpen: settingsOverlay.opened
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color dimForeground: Qt.darker(contentForeground, 1.55)
  readonly property color urgentForeground: bar ? bar.urgent : Color.urgent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    var showSettings = JellyCore.JellyfinState.settingsRequested
      || (JellyCore.JellyfinState.initialized && !JellyCore.JellyfinState.configured)
    JellyCore.JellyfinState.settingsRequested = false
    root.controller.show()
    if (!JellyCore.JellyfinState.initialized) JellyCore.JellyfinState.loadStatus()
    if (showSettings)
      root.openSettings()
  }

  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function openSettings() { settingsOverlay.open() }

  onOpenedChanged: {
    if (!opened) settingsOverlay.dismiss()
    else if (JellyCore.JellyfinState.initialized && !JellyCore.JellyfinState.configured)
      root.openSettings()
  }

  Connections {
    target: JellyCore.JellyfinState
    function onPopupRequested(action) {
      if (action === "toggle") root.toggle()
      else if (action === "hide") root.close()
      else root.open()
    }
    function onRefreshRequested() {
      if (!browse.running && JellyCore.JellyfinState.configured) musicPane.loadPage()
    }
    function onInitializedChanged() {
      if (root.opened && JellyCore.JellyfinState.initialized && !JellyCore.JellyfinState.configured)
        root.openSettings()
    }
    function onConfigurationFinished(success, detail) {
      settingsOverlay.finishConfiguration(success)
      if (success && !browse.running) musicPane.loadPage()
    }
    function onConfiguredChanged() {
      settingsOverlay.syncServer()
    }
  }

  Component {
    id: jellyfinIcon
    Text {
      text: "󰟈"
      textFormat: Text.PlainText
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.display
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(musicPane.nowPlaying && !root.settingsOpen ? 360 : 430))
    contentHeight: panel.fittedContentHeight(
      root.settingsOpen ? settingsOverlay.contentImplicitHeight : musicPane.implicitHeight,
      Style.space(760)
    )


    Column {
      id: musicPane
      width: parent.width
      spacing: 6
      visible: !root.settingsOpen
      property var trail: [{action: "artists", title: "Album artists", key: ""}]
      property var rows: []
      property string message: ""
      property string playingTitle: ""
      readonly property var page: trail[trail.length - 1]
      readonly property string helper: JellyCore.JellyfinState.pluginRoot + "/music_helper.py"

      function loadPage() {
        rows = []
        message = "Loading…"
        let args = ["python", helper, page.action]
        if (page.key) args.push(page.key)
        browse.command = args
        browse.running = true
      }

      property var queue: []
      property int position: -1
      property string albumTitle: ""
      property string artistName: ""
      property string artwork: ""
      property bool nowPlaying: false
      property bool queueOpen: false
      property bool paused: false

      function publishMedia() {
        let row = queue[position]
        if (!row || !mediaBridge.running) return
        mediaBridge.write(JSON.stringify({
          id: row.id, title: row.name, album: albumTitle,
          artists: row.artists && row.artists.length ? row.artists : [artistName],
          length: row.lengthUs || 0, cover: artwork,
          previous: position > 0, next: position + 1 < queue.length
        }) + "\n")
      }

      Process {
        id: mediaBridge
        command: ["/usr/bin/python", JellyCore.JellyfinState.pluginRoot + "/music_mpris.py"]
        stdinEnabled: true
        running: musicPane.queue.length > 0
        onStarted: musicPane.publishMedia()
        stdout: SplitParser {
          onRead: data => {
            if (data === "Next") musicPane.jump(musicPane.position + 1)
            else if (data === "Previous") musicPane.jump(musicPane.position - 1)
            else if (data === "Stop") {
              musicPane.pendingPlay = null
              musicPane.queue = []
              musicPane.position = -1
              musicPane.nowPlaying = false
              if (player.running) player.signal(15)
            }
          }
        }
      }

      property bool playlistQueue: false

      function beginQueue(all, row) {
        playlistQueue = page.action === "playlist-tracks"
        queue = all ? rows.slice() : [row]
        albumTitle = page.title
        artistName = trail.length > 1 ? trail[trail.length - 2].title : ""
        artwork = rows.length ? (rows[0].cover || "") : ""
        queueOpen = false
        nowPlaying = true
        jump(0)
      }

      function jump(index) {
        if (index < 0 || index >= queue.length) return
        position = index
        if (playlistQueue) {
          albumTitle = queue[index].album
          artistName = queue[index].artists.join(", ")
          artwork = ""
        }
        paused = false
        requestPlay("play", queue[index].id, queue[index].name)
      }

      Process {
        id: pauseControl
        command: ["python", musicPane.helper, "play-pause"]
        onExited: { if (!pauseProbe.running) pauseProbe.running = true }
      }
      Process {
        id: pauseProbe
        command: ["python", musicPane.helper, "paused"]
        stdout: StdioCollector {
          onStreamFinished: { if (text.trim()) musicPane.paused = text.trim() === "true" }
        }
      }
      Timer {
        interval: 900
        repeat: true
        triggeredOnStart: true
        running: root.opened && musicPane.nowPlaying && player.running
        onTriggered: { if (!pauseProbe.running) pauseProbe.running = true }
      }

      property var pendingPlay: null
      property bool switchingPlayer: false

      function requestPlay(action, key, title) {
        pendingPlay = {action: action, key: key, title: title}
        if (switchingPlayer) return
        if (player.running) {
          switchingPlayer = true
          player.signal(15)
        } else {
          startPending()
        }
      }

      function startPending() {
        switchingPlayer = false
        const next = pendingPlay
        if (!next) return
        pendingPlay = null
        message = ""
        Qt.callLater(publishMedia)
        playingTitle = next.title
        let command = ["python", helper, next.action, next.key]
        if (playlistQueue) command.push("--cover-id", queue[position].coverId)
        player.command = command
        player.running = true
      }

      function selectRow(row) {
        if (page.action === "tracks" || page.action === "playlist-tracks") {
          beginQueue(false, row)
          return
        }
        let next = page.action === "playlists" ? "playlist-tracks"
          : (page.action === "artists" ? "albums" : "tracks")
        trail = trail.concat([{action: next, title: row.name, key: row.id}])
        loadPage()
      }

      Connections {
        target: root
        function onOpenedChanged() {
          if (root.opened && musicPane.queue.length) {
            musicPane.nowPlaying = true
            musicPane.queueOpen = false
          }
          if (root.opened && !musicPane.rows.length && !browse.running)
            musicPane.loadPage()
        }
      }

      Process {
        id: browse
        stdout: StdioCollector {
          onStreamFinished: {
            try {
              musicPane.rows = JSON.parse(text)
              musicPane.message = musicPane.rows.length ? "" : "No items found."
              musicList.positionViewAtBeginning()
            } catch (error) {
              musicPane.message = "Could not read this list."
            }
          }
        }
        stderr: StdioCollector {
          onStreamFinished: { if (text.trim()) console.warn("OmaJelly music:", text.trim()) }
        }
      }

      Process {
        id: player
        stdout: SplitParser {
          onRead: data => {
            if (!data.trim()) return
            let result = JSON.parse(data)
            if (musicPane.playlistQueue && result.track === musicPane.queue[musicPane.position]?.id) {
              musicPane.artwork = result.cover
              musicPane.publishMedia()
            }
          }
        }
        onExited: function(code, status) {
          musicPane.playingTitle = ""
          if (musicPane.pendingPlay) {
            Qt.callLater(function() { musicPane.startPending() })
          } else if (code === 0 && musicPane.position + 1 < musicPane.queue.length) {
            musicPane.jump(musicPane.position + 1)
          } else {
            musicPane.queue = []
            musicPane.position = -1
            musicPane.nowPlaying = false
            if (code !== 0 && status === 0) musicPane.message = "Playback failed."
          }
        }
      }

      Column {
        visible: musicPane.nowPlaying
        width: parent.width
        spacing: Style.space(6)
        Row {
          id: albumHeader
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)
          Image {
            id: playingCover
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(76)
            height: width
            visible: status === Image.Ready
            source: musicPane.artwork
            fillMode: Image.PreserveAspectFit
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            Repeater {
              model: [musicPane.queue[musicPane.position]?.name || "", musicPane.artistName, musicPane.albumTitle]
              Text {
                required property string modelData
                required property int index
                width: Math.min(implicitWidth, Math.max(0, musicPane.width
                  - (playingCover.visible ? playingCover.width + albumHeader.spacing : 0)))
                text: modelData
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.bold: index === 0
                font.pixelSize: Style.font.bodySmall
                color: root.contentForeground
              }
            }
          }
        }
        Row {
          id: transportRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 4
          Repeater {
            model: ["Previous", musicPane.paused ? "Play" : "Pause", "Next", "Queue", "Library"]
            QQC.Button {
              required property int index
              required property string modelData
              readonly property var glyphs: ["\uf048", musicPane.paused ? "\uf04b" : "\uf04c", "\uf051", "\uf03a", "\uf001"]
              text: glyphs[index]
              font.family: "Symbols Nerd Font Mono"
              font.pixelSize: Style.font.body
              width: Math.min(Style.space(40), Math.max(1, (musicPane.width - 4 * transportRow.spacing) / 5))
              implicitHeight: Style.space(34)
              Accessible.name: modelData
              hoverEnabled: true
              QQC.ToolTip.text: modelData
              QQC.ToolTip.visible: hovered
              QQC.ToolTip.delay: 400
              enabled: index === 0 ? musicPane.position > 0
                : index === 2 ? musicPane.position + 1 < musicPane.queue.length : true
              onClicked: {
                if (index === 0) musicPane.jump(musicPane.position - 1)
                else if (index === 1 && !pauseControl.running) pauseControl.running = true
                else if (index === 2) musicPane.jump(musicPane.position + 1)
                else if (index === 3) musicPane.queueOpen = !musicPane.queueOpen
                else if (index === 4) musicPane.nowPlaying = false
              }
            }
          }
        }
        ListView {
          visible: musicPane.queueOpen
          width: parent.width
          height: Math.min(contentHeight, Style.space(230))
          clip: true
          model: musicPane.queue
          currentIndex: musicPane.position
          QQC.ScrollBar.vertical: QQC.ScrollBar {}
          delegate: QQC.ItemDelegate {
            required property int index
            required property var modelData
            width: ListView.view.width
            highlighted: index === musicPane.position
            text: (index + 1) + ".  " + modelData.name
            font.pixelSize: Style.font.bodySmall
            onClicked: musicPane.jump(index)
          }
        }
      }
      Column {
        width: parent.width
        spacing: 6
        visible: !musicPane.nowPlaying
      Row {
        width: parent.width
        spacing: Style.space(8)

        Image {
          id: albumArt
          source: musicPane.page.action === "tracks" && musicPane.rows.length
            ? (musicPane.rows[0].cover || "") : ""
          visible: status === Image.Ready
          width: Style.space(64)
          height: width
          fillMode: Image.PreserveAspectFit
          cache: false
        }

        Text {
          width: parent.width - (albumArt.visible ? albumArt.width + parent.spacing : 0)
          anchors.verticalCenter: parent.verticalCenter
          text: musicPane.page.title
          textFormat: Text.PlainText
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }

      Row {
        spacing: 8
        QQC.Button {
          text: "Back"
          font.pixelSize: Style.font.bodySmall
          enabled: musicPane.trail.length > 1 && !browse.running
          onClicked: {
            musicPane.trail = musicPane.trail.slice(0, -1)
            musicPane.loadPage()
          }
        }
        QQC.Button {
          visible: musicPane.trail.length === 1
          text: musicPane.page.action === "artists" ? "Playlists" : "Album artists"
          enabled: !browse.running
          font.pixelSize: Style.font.bodySmall
          onClicked: {
            let playlists = musicPane.page.action === "artists"
            musicPane.trail = [{action: playlists ? "playlists" : "artists", title: text, key: ""}]
            musicPane.loadPage()
          }
        }
        QQC.Button {
          text: "Now Playing"
          font.pixelSize: Style.font.bodySmall
          visible: musicPane.queue.length > 0
          onClicked: {
            musicPane.queueOpen = false
            musicPane.nowPlaying = true
          }
        }
        QQC.Button {
          text: musicPane.page.action === "playlist-tracks" ? "Play playlist" : "Play album"
          font.pixelSize: Style.font.bodySmall
          visible: musicPane.page.action === "tracks" || musicPane.page.action === "playlist-tracks"
          enabled: !browse.running && musicPane.rows.length > 0
          onClicked: {
            musicPane.beginQueue(true, null)
          }
        }
      }

      QQC.Label {
        visible: text !== ""
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        text: musicPane.message || (player.running ? "Playing: " + musicPane.playingTitle : "")
        textFormat: Text.PlainText
        color: root.contentForeground
        width: parent.width
        elide: Text.ElideRight
      }

      ListView {
        id: musicList
        width: parent.width
        height: Style.space(320)
        clip: true
        model: musicPane.rows
        QQC.ScrollBar.vertical: QQC.ScrollBar {}
        delegate: ItemDelegate {
          required property var modelData
          width: ListView.view.width
          text: modelData.name
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          contentItem: Text {
            text: parent.text
            font: parent.font
            color: root.contentForeground
            textFormat: Text.PlainText
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
          }
          onClicked: musicPane.selectRow(modelData)
        }
      }
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      visible: root.settingsOpen
      blocked: settingsOverlay.inputFocused
      onCloseRequested: settingsOverlay.close()

      ConnectionSettings {
        id: settingsOverlay
        anchors.fill: parent
        z: 30
        foreground: root.contentForeground
        dimForeground: root.dimForeground
        urgentForeground: root.urgentForeground
        fontFamily: root.contentFontFamily
        iconComponent: jellyfinIcon
        onDismissRequested: root.close()
      }

    }
  }
}
