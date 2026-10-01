import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "io.github.artmoreno.trackpoint"
  ipcTarget: "io.github.artmoreno.trackpoint"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // permits, which adds the device method below to Panel's open/close set.
  manageIpc: false
  property real sensitivity: 0
  // Whether Hyprland accepts input from the TrackPoint at all (pointer and its buttons)
  property bool deviceEnabled: true
  property var deviceQueue: []
  property int stateRevision: 0
  property string device: ""
  property string status: ""
  property bool queued: false
  // Bar icon, set per widget with: omarchy bar set io.github.artmoreno.trackpoint logo <wordmark|dot|color>
  readonly property string logo: ["wordmark", "dot", "color"].indexOf(String(setting("logo", "wordmark"))) !== -1
    ? String(setting("logo", "wordmark")) : "wordmark"
  readonly property var logoOptions: [
    { value: "wordmark", label: "ThinkPad" },
    { value: "dot", label: "Red dot" },
    { value: "color", label: "Color logo" }
  ]
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.artmoreno.trackpoint"
  readonly property string helper: pluginDir + "/control.py"
  // Middle button (the one between the two hard buttons) bound through hypr/bindings.lua
  readonly property string middleHelper: pluginDir + "/middle.py"
  property bool middleEnabled: false
  property var middleProfiles: ({ "default": {} })
  property string middleProfile: "default"
  property string middleSection: "taps"
  property string middleStatus: ""
  readonly property var middleSections: [
    { value: "taps", label: "Taps" },
    { value: "holds", label: "Holds" },
    { value: "gestures", label: "Gestures" },
    { value: "mods", label: "Modifiers" }
  ]
  readonly property var middleSlots: ({
    taps: [
      { key: "tap", label: "Tap" },
      { key: "double", label: "Double tap" },
      { key: "triple", label: "Triple tap" }
    ],
    holds: [
      { key: "hold", label: "Hold" },
      { key: "double_hold", label: "Double tap + hold" },
      { key: "triple_hold", label: "Triple tap + hold" }
    ],
    gestures: [
      { key: "up", label: "Hold + flick up" },
      { key: "down", label: "Hold + flick down" },
      { key: "left", label: "Hold + flick left" },
      { key: "right", label: "Hold + flick right" }
    ],
    mods: [
      { key: "super", label: "Super + tap" },
      { key: "alt", label: "Alt + tap" },
      { key: "shift", label: "Shift + tap" },
      { key: "ctrl", label: "Ctrl + tap" },
      { key: "super_shift", label: "Super + Shift + tap" },
      { key: "super_alt", label: "Super + Alt + tap" },
      { key: "super_ctrl", label: "Super + Ctrl + tap" },
      { key: "ctrl_alt", label: "Ctrl + Alt + tap" },
      { key: "ctrl_shift", label: "Ctrl + Shift + tap" },
      { key: "alt_shift", label: "Alt + Shift + tap" }
    ]
  })
  // Every preset is a stock Omarchy command; anything else goes in "Custom command…"
  readonly property var middlePresets: [
    { value: "", label: "Nothing" },
    // Menus
    { value: "omarchy-menu toggle root", label: "Omarchy menu" },
    { value: "omarchy-menu toggle apps", label: "Apps menu" },
    { value: "omarchy-menu toggle theme", label: "Theme menu" },
    // Capture
    { value: "omarchy-capture-screenshot", label: "Screenshot" },
    { value: "omarchy-capture-screenrecording --stop-recording || omarchy-menu toggle trigger.capture.screenrecord", label: "Screen recording" },
    { value: "omarchy-capture-text", label: "Extract text (OCR)" },
    { value: "pkill hyprpicker || hyprpicker -a", label: "Color picker" },
    // Input
    { value: "omarchy-shell shell toggle omarchy.clipboard", label: "Clipboard history" },
    { value: "omarchy-shell shell toggle omarchy.emojis", label: "Emoji picker" },
    // Media and audio
    { value: "omarchy-shell media playPause", label: "Play / pause" },
    { value: "omarchy-shell media next", label: "Next track" },
    { value: "omarchy-shell media previous", label: "Previous track" },
    { value: "omarchy-audio-output-volume mute-toggle", label: "Mute audio" },
    { value: "omarchy-audio-input-mute", label: "Mute microphone" },
    // Apps
    { value: "omarchy-launch-terminal", label: "Open terminal" },
    { value: "omarchy-launch-browser", label: "Open browser" },
    { value: "omarchy-launch-nautilus", label: "File manager" },
    { value: "omarchy-launch-editor", label: "Editor" },
    // Window and system
    { value: "omarchy-hyprland-window-pop", label: "Pop window out" },
    { value: "omarchy-system-lock", label: "Lock screen" },
    { value: "omarchy-toggle-nightlight", label: "Toggle nightlight" },
    { value: "omarchy-shell shell toggle omarchy.bluetooth", label: "Bluetooth" },
    // Notifications
    { value: "omarchy-shell notifications showHistory", label: "Notification history" },
    { value: "omarchy-shell notifications dismissAll", label: "Dismiss notifications" },
    { value: "omarchy-toggle-notification-silencing", label: "Silence notifications" },
    { value: "custom", label: "Custom command…" }
  ]
  // App profiles fall back to the default for anything left empty, so empty
  // means "same as default" there and ":" (a shell no-op) blocks the default.
  readonly property var appPresets: [
    { value: "", label: "Same as default" },
    { value: ":", label: "Do nothing" }
  ].concat(middlePresets.slice(1))
  readonly property var activePresets: middleProfile === "default" ? middlePresets : appPresets
  readonly property var profileOptions: {
    var options = [{ value: "default", label: "All apps (default)" }]
    for (var name in middleProfiles)
      if (name !== "default") options.push({ value: name, label: name })
    options.push({ value: "__add", label: "Add focused app…" })
    return options
  }
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refreshDevice() {
    if (!reader.running && !writer.running && !deviceWriter.running && deviceQueue.length === 0) {
      reader.revision = stateRevision
      reader.running = true
    }
  }
  function refresh() {
    refreshDevice()
    if (!middleReader.running && !middleWriter.running) middleReader.running = true
  }
  function choiceFor(command) {
    for (var i = 0; i < activePresets.length; i++)
      if (activePresets[i].value === command && command !== "custom") return command
    return "custom"
  }
  function commandFor(slot) {
    return (middleProfiles[middleProfile] || {})[slot] || ""
  }
  function runMiddle(args) {
    if (middleWriter.running) return
    middleStatus = "Saving…"
    middleWriter.command = ["python3", middleHelper].concat(args)
    middleWriter.running = true
  }
  function applyMiddle(data) {
    middleEnabled = !!data.enabled
    middleProfiles = data.profiles || { "default": {} }
    if (data.added) middleProfile = data.added
    if (!middleProfiles[middleProfile]) middleProfile = "default"
    // Dropdown assigns its own value on selection, which drops a binding
    profileDropdown.value = middleProfile
  }
  function setDeviceEnabled(on) {
    return requestDevice(on ? "on" : "off")
  }
  function requestDevice(action) {
    // Preserve every accepted request, including an on following a pending off.
    if (deviceQueue.length >= 32) return "busy: device queue is full"
    stateRevision++
    deviceQueue = deviceQueue.concat([action])
    startDeviceWrite()
    return "queued " + action
  }
  function startDeviceWrite() {
    if (deviceWriter.running || deviceQueue.length === 0) return
    var action = deviceQueue[0]
    deviceQueue = deviceQueue.slice(1)
    status = action === "toggle" ? "Switching TrackPoint…" : action === "on" ? "Turning on…" : "Turning off…"
    deviceWriter.completed = false
    // Python resolves toggle against the configuration while holding its lock.
    deviceWriter.command = ["python3", helper, action]
    deviceWriter.running = true
  }
  // omarchy-shell io.github.artmoreno.trackpoint device <on|off|toggle>
  function deviceIpc(action) {
    action = String(action || "toggle")
    if (["on", "off", "toggle"].indexOf(action) === -1) return "usage: device <on|off|toggle>"
    return requestDevice(action)
  }
  function setSensitivity(value) {
    stateRevision++
    sensitivity = Math.round(Math.max(-1, Math.min(1, value)) * 100) / 100
    status = "Saving…"
    if (writer.running) { queued = true; return }
    queued = false
    writer.command = ["python3", helper, sensitivity.toFixed(2)]
    writer.running = true
  }
  Component.onCompleted: refresh()
  onOpenedChanged: {
    if (!opened) return
    refresh()
    // Start with every list folded so they don't cover each other
    Qt.callLater(function() {
      profileDropdown.close()
      for (var i = 0; i < slotRepeater.count; i++) {
        var slotItem = slotRepeater.itemAt(i)
        if (slotItem) slotItem.closeDropdown()
      }
    })
  }

  Process {
    id: reader
    property int revision: 0
    command: ["python3", root.helper]
    stdout: StdioCollector {
      onStreamFinished: {
        // A read started before a user action must not overwrite its result.
        if (reader.revision !== root.stateRevision || deviceWriter.running || writer.running || root.deviceQueue.length) return
        try {
          var data = JSON.parse(text)
          if (data.error) root.status = data.error
          else { root.sensitivity = data.value; root.device = data.device || ""; root.deviceEnabled = data.enabled !== false }
        } catch (e) { root.status = "Could not read sensitivity." }
      }
    }
  }
  Process {
    id: deviceWriter
    property bool completed: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.error) root.status = data.error
          else { root.deviceEnabled = data.enabled !== false; root.device = data.device || ""; root.status = root.deviceEnabled ? "TrackPoint on" : "TrackPoint off" }
        } catch (e) { root.status = "Could not switch the TrackPoint." }
      }
    }
    onExited: function(exitCode, exitStatus) {
      completed = true
      if (exitCode !== 0 && (root.status === "Turning on…" || root.status === "Turning off…" || root.status === "Switching TrackPoint…")) root.status = "Could not switch the TrackPoint."
    }
    onRunningChanged: {
      if (running) return
      if (!completed) root.status = "Could not start the TrackPoint helper."
      Qt.callLater(function() { root.startDeviceWrite() })
    }
  }
  // Keep closed widgets and additional monitors in sync with CLI/config edits.
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: root.refreshDevice()
  }
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function device(action: string): string { return root.deviceIpc(action) }
  }
  Process {
    id: writer
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.status = data.error ? data.error : "Saved"
        } catch (e) { root.status = "Could not save sensitivity." }
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 && root.status === "Saving…") root.status = "Could not save sensitivity."
      if (root.queued) root.setSensitivity(root.sensitivity)
    }
  }
  Process {
    id: middleReader
    command: ["python3", root.middleHelper]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.error) root.middleStatus = data.error
          else { root.applyMiddle(data); root.middleStatus = "" }
        } catch (e) { root.middleStatus = "Could not read middle button." }
      }
    }
  }
  Process {
    id: middleWriter
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.error) root.middleStatus = data.error
          else {
            root.applyMiddle(data)
            root.middleStatus = data.added ? "Added " + data.added : "Saved"
          }
        } catch (e) { root.middleStatus = "Could not save middle button." }
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 && root.middleStatus === "Saving…") root.middleStatus = "Could not save middle button."
    }
  }

  Process {
    id: logoWriter
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.status = "Could not change the bar icon."
    }
  }
  function setLogo(value) {
    if (logoWriter.running || value === logo) return
    // Omarchy's own command stores it on this widget's bar entry, which updates the icon live
    logoWriter.command = ["omarchy", "bar", "set", "io.github.artmoreno.trackpoint", "logo", value]
    logoWriter.running = true
  }

  TextMetrics {
    id: logoMetrics
    text: "ThinkPad"
    font.family: "Liberation Sans"
    font.pixelSize: Style.bar.iconFont
    font.bold: true
    font.italic: true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: (root.device ? "TrackPoint · " + root.device : "TrackPoint") + (root.deviceEnabled ? "" : " · off")
    // The wordmark and color logo are wider than the square icon slot.
    fixedWidth: vertical || root.logo === "dot" ? -1
      : root.logo === "color" ? colorLogoWidth + Style.space(12)
      : Math.ceil(logoMetrics.advanceWidth) + Style.space(12)
    readonly property int colorLogoHeight: Math.round(Style.bar.iconFont * 1.15)
    // thinkpad-color.svg is 768 x 274
    readonly property int colorLogoWidth: Math.ceil(colorLogoHeight * 768 / 274)
    iconComponent: Component {
      Item {
        opacity: root.deviceEnabled ? 1 : 0.4
        Text {
          anchors.centerIn: parent
          visible: root.logo === "wordmark"
          text: logoMetrics.text
          color: "#e2231a"
          font: logoMetrics.font
        }
        Rectangle {
          anchors.centerIn: parent
          visible: root.logo === "dot"
          width: Math.round(Style.bar.iconFont * 0.8)
          height: width
          radius: width / 2
          color: "#e2231a"
        }
        Image {
          anchors.centerIn: parent
          visible: root.logo === "color"
          source: root.logo === "color" ? Qt.resolvedUrl("thinkpad-color.svg") : ""
          width: button.colorLogoWidth
          height: button.colorLogoHeight
          sourceSize: Qt.size(width * 2, height * 2)
          fillMode: Image.PreserveAspectFit
          smooth: true
        }
      }
    }
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(content.implicitHeight + padding * 2 + Style.space(8), Style.space(900))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.setSensitivity(root.sensitivity + dx * 0.05)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)
        Item {
          width: parent.width
          implicitHeight: Math.max(deviceTitle.implicitHeight, deviceSwitch.implicitHeight)
          Text {
            id: deviceTitle
            anchors.verticalCenter: parent.verticalCenter
            text: "TrackPoint"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Button {
            id: deviceSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.deviceEnabled ? "Turn off" : "Turn on"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            focusable: true
            enabled: !deviceWriter.running && root.deviceQueue.length === 0
            onClicked: root.setDeviceEnabled(!root.deviceEnabled)
          }
        }
        Text {
          visible: !root.deviceEnabled
          width: parent.width
          text: "The TrackPoint is off: moving it or pressing its buttons does nothing. Kept for the next login."
          wrapMode: Text.WordWrap
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          text: "Pointer sensitivity  " + (slider.dragging ? slider.liveValue : root.sensitivity).toFixed(2)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }
        PanelSlider {
          id: slider
          width: parent.width
          bar: root.bar
          minimum: -1
          maximum: 1
          step: 0.05
          value: root.sensitivity
          fillColor: "#e55768"
          knobColor: "#e55768"
          onReleased: function(v) { root.setSensitivity(v) }
        }
        Item {
          width: parent.width
          implicitHeight: slower.implicitHeight
          Text {
            id: slower
            text: "Slower"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            text: "Faster"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Button {
          text: "Reset to default"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          focusable: true
          onClicked: root.setSensitivity(0)
        }
        Text {
          width: parent.width
          text: root.status || "Release to apply · Saved for next login"
          wrapMode: Text.WordWrap
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          text: "Bar icon"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }
        ButtonGroup {
          options: root.logoOptions
          value: root.logo
          spacing: Style.space(4)
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { root.setLogo(v) }
        }

        PanelSeparator { width: parent.width }

        Item {
          width: parent.width
          implicitHeight: Math.max(middleTitle.implicitHeight, turnOff.implicitHeight)
          Text {
            id: middleTitle
            anchors.verticalCenter: parent.verticalCenter
            text: "Middle button"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Button {
            id: turnOff
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.middleEnabled
            text: "Turn off"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            focusable: true
            onClicked: root.runMiddle(["disable"])
          }
        }

        // Nothing in the Hyprland config changes until the user opts in here
        Column {
          visible: !root.middleEnabled
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: parent.width
            text: "Run your own actions on taps, holds and flicks of the middle button. Enabling adds a marked block to ~/.config/hypr/bindings.lua and turns off the TrackPoint's hold-to-scroll. Turn off removes the block and restores scrolling."
            wrapMode: Text.WordWrap
            color: root.bar.foreground
            opacity: 0.7
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Button {
            text: "Enable middle button actions"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            focusable: true
            onClicked: root.runMiddle(["enable"])
          }
        }

        Column {
          visible: root.middleEnabled
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(6)
            Dropdown {
              id: profileDropdown
              width: parent.width - (removeApp.visible ? removeApp.width + parent.spacing : 0)
              showLabel: false
              options: root.profileOptions
              Component.onCompleted: value = root.middleProfile
              onChanged: function(v) {
                if (v === "__add") {
                  value = root.middleProfile
                  root.runMiddle(["add-app"])
                } else {
                  root.middleProfile = v
                }
              }
            }
            Button {
              id: removeApp
              visible: root.middleProfile !== "default"
              text: "Remove"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              focusable: true
              onClicked: root.runMiddle(["remove-app", root.middleProfile])
            }
          }

          ButtonGroup {
            options: root.middleSections
            value: root.middleSection
            spacing: Style.space(4)
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.caption
            focusable: false
            onChanged: function(v) { root.middleSection = v }
          }

          Repeater {
            id: slotRepeater
            model: root.middleSlots[root.middleSection]
            delegate: Column {
              id: slotRow
              required property var modelData
              readonly property string slot: modelData.key
              readonly property string command: root.commandFor(slot)
              property bool editingCustom: false
              readonly property string choice: editingCustom ? "custom" : root.choiceFor(command)
              width: parent ? parent.width : 0
              spacing: Style.space(4)

              function closeDropdown() { slotDropdown.close() }
              function sync() {
                // Dropdown assigns its own value on selection, which drops a binding
                slotDropdown.value = choice
                if (choice === "custom" && !editingCustom) slotField.text = command
              }
              onChoiceChanged: sync()
              onCommandChanged: { editingCustom = false; sync() }
              Component.onCompleted: sync()

              Item {
                width: parent.width
                implicitHeight: slotDropdown.implicitHeight
                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width * 0.42
                  text: slotRow.modelData.label
                  elide: Text.ElideRight
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Dropdown {
                  id: slotDropdown
                  anchors.right: parent.right
                  width: parent.width * 0.58
                  showLabel: false
                  options: root.activePresets
                  onChanged: function(v) {
                    if (v === "custom") {
                      slotRow.editingCustom = true
                      slotField.text = slotRow.command
                      slotField.forceActiveFocus()
                    } else {
                      slotRow.editingCustom = false
                      root.runMiddle(["set", root.middleProfile, slotRow.slot, v])
                    }
                  }
                }
              }
              Row {
                visible: slotRow.choice === "custom"
                width: parent.width
                spacing: Style.space(6)
                TextField {
                  id: slotField
                  width: parent.width - saveCustom.width - parent.spacing
                  placeholderText: "Command to run"
                  foreground: root.bar.foreground
                  verticalPadding: Style.space(4)
                  onAccepted: root.runMiddle(["set", root.middleProfile, slotRow.slot, text])
                  Keys.onEscapePressed: root.close()
                }
                Button {
                  id: saveCustom
                  text: "Save"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  bordered: true
                  focusable: true
                  onClicked: root.runMiddle(["set", root.middleProfile, slotRow.slot, slotField.text])
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.middleEnabled || root.middleStatus !== ""
          text: root.middleStatus || (root.middleSection === "mods"
            ? "Hold the modifier keys, then tap the middle button · runs instantly"
            : "Hold 0.4 s · taps 0.3 s apart count together · flick while holding for gestures · app profiles override the default")
          wrapMode: Text.WordWrap
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
