import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.aryan-techie.battery"
  ipcTarget: "io.github.aryan-techie.battery"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0

  // ---- Charge threshold toggle, Quick Dim, Travel Mode, GPU status, watts
  //      history -- new in this fork, not present in the built-in widget.
  property bool chargeThresholdEnabled: false
  property bool quickDimActive: false
  property var quickDimSavedBrightness: null
  property bool travelModeActive: false
  property var travelModeSaved: null  // { profile, brightness, monitor }
  property bool hybridGpuPresent: false
  property string gpuStatusText: ""
  property var drainSamples: []

  // Resolve the laptop battery instead of assuming its native name contains
  // "BAT". Apple Silicon uses macsmc-battery, and UPower may also expose
  // peripheral batteries; only a device with `power supply: yes` is suitable
  // for the charge-threshold API.
  readonly property string chargeThresholdBatterySetup:
    'battery="$(upower -e | grep "/battery_" | while IFS= read -r device; do LC_ALL=C upower -i "$device" | grep -q "power supply: *yes" && { printf "%s\\n" "$device"; break; }; done)"; test -n "$battery" || exit 1; '

  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") {
      batteryInfo = next
      root.recordDrainSample()
      root.refreshChargeThreshold()
    } else {
      systemInfo = next
    }
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // ---- Charge threshold toggle. Calls UPower's own EnableChargeThreshold
  // DBus method (UPower ships its own polkit policy for it) rather than
  // writing the sysfs threshold file directly, which is root-owned on this
  // hardware and every other laptop checked. The value itself (75-80% here)
  // is whatever UPower/firmware already has configured -- this only flips
  // whether it's *enforced*, matching what omarchy-battery-status's
  // "threshold" field already reports as configured.
  function refreshChargeThreshold() {
    if (!root.batteryInfo.threshold) return
    chargeThresholdReadProc.command = ["bash", "-c",
      root.chargeThresholdBatterySetup
        + 'gdbus call --system --dest org.freedesktop.UPower --object-path "$battery" --method org.freedesktop.DBus.Properties.Get org.freedesktop.UPower.Device ChargeThresholdEnabled']
    chargeThresholdReadProc.running = true
  }

  function toggleChargeThreshold() {
    if (chargeThresholdActionProc.running) return
    var next = !root.chargeThresholdEnabled
    chargeThresholdActionProc.command = ["bash", "-c",
      root.chargeThresholdBatterySetup
        + 'gdbus call --system --dest org.freedesktop.UPower --object-path "$battery" --method org.freedesktop.UPower.Device.EnableChargeThreshold "$1"',
      "_", next ? "true" : "false"]
    chargeThresholdActionProc.running = true
  }

  // ---- Quick Dim. Reads the laptop panel's current brightness first so
  // undimming restores the exact prior value, not a guess. A read that
  // can't resolve a number (docked, no internal panel active) means Quick
  // Dim quietly does nothing rather than dimming something with no way
  // back.
  function toggleQuickDim() {
    if (root.quickDimActive) {
      root.quickDimActive = false
      if (root.quickDimSavedBrightness !== null)
        setBrightness(root.quickDimSavedBrightness)
      root.quickDimSavedBrightness = null
    } else {
      quickDimReadProc.running = true
    }
  }

  function setBrightness(percent) {
    brightnessSetProc.command = ["omarchy", "brightness", "display", "--monitor", "eDP-2", "--no-osd", percent + "%"]
    brightnessSetProc.running = true
  }

  // ---- Travel Mode. Saves profile + brightness + this monitor's refresh
  // rate as one bundle, applies a travel-friendly preset, and restores all
  // three on toggle-off. Session-only by design -- nothing here persists
  // past a restart, same as the plugin this idea came from.
  function toggleTravelMode() {
    if (root.travelModeActive) {
      var saved = root.travelModeSaved
      root.travelModeActive = false
      root.travelModeSaved = null
      if (!saved) return
      if (saved.profile) root.setProfile(saved.profile)
      if (saved.brightness !== null) setBrightness(saved.brightness)
      if (saved.monitor) {
        travelMonitorProc.command = ["hyprctl", "keyword", "monitor",
          Model.monitorKeywordLine(saved.monitor, saved.monitor.refreshRate)]
        travelMonitorProc.running = true
      }
    } else {
      travelModeReadProc.running = true
    }
  }

  function refreshGpuStatus() {
    if (!root.hybridGpuPresent) return
    gpuStatusProc.running = true
  }

  function recordDrainSample() {
    var watts = Model.parseWattsRate(root.batteryInfo.rate)
    root.drainSamples = Model.appendDrainSample(root.drainSamples, watts, Date.now() / 1000, 600)
  }

  IpcHandler {
    target: "io.github.aryan-techie.battery"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Process {
    id: chargeThresholdReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = Model.parseGdbusBoolean(text)
        if (value !== null) root.chargeThresholdEnabled = value
      }
    }
  }

  Process { id: chargeThresholdActionProc; onExited: root.refreshChargeThreshold() }

  Process {
    id: quickDimReadProc
    command: ["omarchy", "brightness", "display", "--monitor", "eDP-2"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var pct = Model.parseBrightnessPercent(text)
        if (pct === null) return // no laptop panel to dim right now
        root.quickDimSavedBrightness = pct
        root.quickDimActive = true
        root.setBrightness(40)
      }
    }
  }

  Process { id: brightnessSetProc }

  Process {
    id: travelModeReadProc
    command: ["bash", "-c", 'omarchy brightness display --monitor eDP-2; echo "---"; hyprctl monitors -j']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text).split("---")
        var brightnessPct = Model.parseBrightnessPercent(parts[0])
        var monitors = []
        try { monitors = JSON.parse(parts[1] || "[]") } catch (e) { monitors = [] }
        var focused = null
        for (var i = 0; i < monitors.length; i++) if (monitors[i].focused) { focused = monitors[i]; break }
        if (!focused && monitors.length > 0) focused = monitors[0]

        root.travelModeSaved = { profile: root.activeProfile, brightness: brightnessPct, monitor: focused }
        root.travelModeActive = true

        root.setProfile("power-saver")
        if (brightnessPct !== null) root.setBrightness(40)
        if (focused) {
          travelMonitorProc.command = ["hyprctl", "keyword", "monitor", Model.monitorKeywordLine(focused, 60)]
          travelMonitorProc.running = true
        }
      }
    }
  }

  Process { id: travelMonitorProc }

  Process {
    id: hybridGpuCheckProc
    command: ["omarchy", "hw", "hybrid", "gpu"]
    onExited: function(exitCode) {
      root.hybridGpuPresent = exitCode === 0
      if (root.hybridGpuPresent) root.refreshGpuStatus()
    }
  }

  Process {
    id: gpuStatusProc
    command: ["nvidia-smi", "--query-gpu=power.draw,utilization.gpu", "--format=csv,noheader,nounits"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text).split(",")
        var watts = parseFloat(parts[0])
        var util = parseInt(parts[1], 10)
        root.gpuStatusText = isFinite(watts)
          ? ("NVIDIA " + watts.toFixed(1) + "W" + (isFinite(util) ? ", " + util + "% util" : ""))
          : ""
      }
    }
  }

  Component.onCompleted: hybridGpuCheckProc.running = true

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: {
      root.refresh()
      if (root.hybridGpuPresent) root.refreshGpuStatus()
    }
  }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }

        // ---------- Charge threshold toggle. Only shown once the battery
        //            actually reports a configured threshold -- the same
        //            gate omarchy-battery-status already applies before
        //            printing the "threshold" field. ----------
        Item {
          visible: !!root.batteryInfo.threshold
          width: parent.width
          height: visible ? chargeThresholdColumn.implicitHeight : 0

          Column {
            id: chargeThresholdColumn
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.bar.foreground }

            Toggle {
              width: parent.width
              label: "Charge threshold"
              description: root.batteryInfo.threshold
                ? ("Hold at " + root.batteryInfo.threshold + " to protect battery health")
                : "Hold charge below the firmware limit"
              checked: root.chargeThresholdEnabled
              foreground: root.bar.foreground
              accent: Color.accent
              fontFamily: root.bar.fontFamily
              onClicked: root.toggleChargeThreshold()
            }
          }
        }

        // ---------- Quick Dim + Travel Mode ----------
        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "QUICK ACTIONS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (parent.width - parent.spacing) / 2
              iconText: "󰃞"
              iconSize: Style.font.title
              text: root.quickDimActive ? "Undim" : "Quick Dim"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.quickDimActive
              onClicked: root.toggleQuickDim()
            }

            Button {
              width: (parent.width - parent.spacing) / 2
              iconText: "󰀚"
              iconSize: Style.font.title
              text: root.travelModeActive ? "End Travel" : "Travel Mode"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.travelModeActive
              onClicked: root.toggleTravelMode()
            }
          }
        }

        // ---------- GPU status. Hybrid-GPU hardware only. ----------
        Item {
          visible: root.hybridGpuPresent && root.gpuStatusText !== ""
          width: parent.width
          height: visible ? gpuColumn.implicitHeight : 0

          Column {
            id: gpuColumn
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.bar.foreground }

            InfoPair { label: "GPU"; value: root.gpuStatusText }
          }
        }

        // ---------- Power draw history: a short sparkline, no
        //            persistence -- see Model.appendDrainSample. ----------
        Item {
          visible: root.drainSamples.length > 1
          width: parent.width
          height: visible ? drainColumn.implicitHeight : 0

          Column {
            id: drainColumn
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.bar.foreground }

            Item {
              width: parent.width
              implicitHeight: Math.max(drainHeader.implicitHeight, drainNow.implicitHeight)

              PanelSectionHeader {
                id: drainHeader
                text: "POWER DRAW (LAST 10 MIN)"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // A flat near-zero line reads as "broken" without this --
              // the number makes a quiet graph legible on its own.
              InfoValue {
                id: drainNow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.drainSamples.length > 0
                  ? root.drainSamples[root.drainSamples.length - 1].w.toFixed(1) + "W"
                  : ""
              }
            }

            Canvas {
              id: sparkline
              width: parent.width
              height: Style.space(40)
              // Vertical inset so a flat (near-zero draw) line sits a few
              // pixels off the bottom edge instead of hugging it -- glued
              // to the edge, a flat line at 0 is functionally invisible.
              readonly property real topInset: Style.space(4)
              readonly property real bottomInset: Style.space(6)
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var samples = root.drainSamples
                if (samples.length < 2) return
                var maxW = 0
                for (var i = 0; i < samples.length; i++) maxW = Math.max(maxW, samples[i].w)
                if (maxW <= 0) maxW = 1
                var minT = samples[0].t
                var maxT = samples[samples.length - 1].t
                var spanT = Math.max(1, maxT - minT)
                var plotHeight = height - topInset - bottomInset

                ctx.strokeStyle = Style.selectedStateColor(root.bar.foreground, Color.accent)
                ctx.lineWidth = 1.5
                ctx.beginPath()
                for (var j = 0; j < samples.length; j++) {
                  var x = ((samples[j].t - minT) / spanT) * width
                  var y = topInset + plotHeight - (samples[j].w / maxW) * plotHeight
                  if (j === 0) ctx.moveTo(x, y)
                  else ctx.lineTo(x, y)
                }
                ctx.stroke()
              }

              Connections {
                target: root
                function onDrainSamplesChanged() { sparkline.requestPaint() }
              }
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
