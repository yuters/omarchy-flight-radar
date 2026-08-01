import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "RadarModel.js" as RadarModel

Panel {
  id: radarRoot

  readonly property string pluginId: "yuters.flight-radar"

  moduleName: pluginId
  ipcTarget: pluginId

  property var trackedById: ({})
  property var contacts: []
  property string lastError: ""
  property bool initialized: false
  property bool refreshing: false
  property bool authenticated: false
  property string lastUpdatedAt: ""
  property real frameNow: 0
  property real lastFetchAt: 0
  property bool snapOnNextFix: false
  property bool limitReached: false

  property var overheadIds: ({})
  property var notifiedAt: ({})
  property int overheadCount: 0
  readonly property bool overheadKnown: watchEnabled || opened

  property bool settingsOpen: false
  property bool centreFieldsLoaded: false
  property string settingsNotice: ""
  property bool settingsNoticeIsError: false
  property bool credentialsSaving: false
  property string credentialsAction: ""
  property bool removeConfirmOpen: false

  property real epochMs: 0

  property var litAt: ({})
  property var heldPositions: ({})
  property var drawn: []
  property real drawnAt: -1
  property real prevSweepAngle: -1

  readonly property real sweepRadiansPerMs: 1 / 3000
  readonly property real sweepPeriodMs: Math.PI * 2 / sweepRadiansPerMs

  // The fan's bright edge sits at maximum perpendicular offset, so it leads the
  // base angle by atan(offset / reach) — 40°. Lighting contacts at the base
  // angle would fire a fifth of a revolution late.
  readonly property real sweepLeadRadians: Math.atan2(20 * 5, unitSize / 2 - 1)

  readonly property int unitSize: 240

  readonly property int minFetchGapMs: 10000
  readonly property int reuseWindowMs: authenticated ? minFetchGapMs : minIntervalMs

  readonly property string radarGlyph: String.fromCodePoint(0xF0437)   // nf-md-radar

  property string version: ""
  property string repository: ""

  readonly property var latitudeSetting: conf("latitude", null)
  readonly property var longitudeSetting: conf("longitude", null)

  readonly property bool hasManualCentre: {
    var lat = parseFloat(String(latitudeSetting))
    var lon = parseFloat(String(longitudeSetting))
    return isFinite(lat) && isFinite(lon)
      && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
  }

  property real autoLat: 0
  property real autoLon: 0
  property bool autoResolved: false
  property string autoError: ""

  readonly property bool hasCentre: hasManualCentre || autoResolved

  readonly property real centreLat: hasManualCentre
    ? RadarModel.clampNumber(latitudeSetting, -90, 90, 0) : autoLat
  readonly property real centreLon: hasManualCentre
    ? RadarModel.clampNumber(longitudeSetting, -180, 180, 0) : autoLon

  readonly property real rangeNm: RadarModel.clampNumber(conf("rangeNm", 20), 5, 120, 20)
  readonly property real radiusDeg: RadarModel.rangeNmToDeg(rangeNm)

  readonly property int refreshIntervalMs: Math.round(RadarModel.clampNumber(setting("refreshIntervalSec", 20), 10, 300, 20)) * 1000
  readonly property int scopeSize: Math.round(RadarModel.clampNumber(setting("scopeSize", 320), 200, 520, 320))
  readonly property bool showSweep: setting("sweep", true)
  readonly property bool showLabels: setting("labels", true)
  readonly property bool showTriangles: setting("triangles", true)
  readonly property bool aviationUnits: setting("aviationUnits", true)

  readonly property bool watchEnabled: setting("watch", true)
  readonly property bool notifyEnabled: setting("notify", true)
  readonly property real overheadRadiusNm: RadarModel.clampNumber(conf("overheadRadiusNm", 2), 0.2, 60, 2)
  readonly property real overheadCeilingFt: RadarModel.clampNumber(conf("overheadCeilingFt", 0), 0, 60000, 0)
  readonly property int notifyCooldownMs: Math.round(RadarModel.clampNumber(setting("notifyCooldownMin", 10), 1, 240, 10)) * 60000
  readonly property int watchIntervalSec: Math.round(RadarModel.clampNumber(setting("watchIntervalSec", 60), 30, 900, 60))

  // Anonymous access allows 400 requests/day. Until a fetch proves credentials
  // work, never poll faster than that or a day's quota is gone by lunch.
  readonly property int anonymousFloorMs: 240000
  readonly property int minIntervalMs: authenticated ? 15000 : anonymousFloorMs
  readonly property int pollIntervalMs: limitReached ? 900000 : Math.max(
    opened ? refreshIntervalMs : watchIntervalSec * 1000, minIntervalMs)

  readonly property color scopeTint: Color.accent

  readonly property bool lightTheme:
    0.2126 * Color.background.r + 0.7152 * Color.background.g + 0.0722 * Color.background.b > 0.5
  readonly property color scopeBackground: Qt.darker(Color.background, lightTheme ? 1.07 : 2.4)

  readonly property color ringOuterColor: tinted(0.8)
  readonly property color ringMidColor: tinted(lightTheme ? 0.34 : 0.26)
  readonly property color ringInnerColor: tinted(lightTheme ? 0.2 : 0.14)
  readonly property color labelColor: tinted(lightTheme ? 0.75 : 0.62)
  readonly property color overheadRingColor: tinted(0.55)
  readonly property color glowColor: lightTheme ? Qt.darker(scopeTint, 1.3) : Qt.lighter(scopeTint, 1.4)

  readonly property color badgeColor: scopeTint
  readonly property color badgeTextColor: Color.background

  function tinted(alpha) {
    return Qt.rgba(scopeTint.r, scopeTint.g, scopeTint.b, alpha)
  }

  function litTint(lit) {
    var base = Qt.darker(scopeTint, 1.3)
    var target = lightTheme ? 0 : 1
    return Qt.rgba(base.r + (target - base.r) * lit,
                   base.g + (target - base.g) * lit,
                   base.b + (target - base.b) * lit, 1)
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string rangeText: RadarModel.rangeLabel(radiusDeg, aviationUnits)

  readonly property string helperPath: Qt.resolvedUrl("opensky-fetch").toString().replace(/^file:\/\//, "")
  readonly property string locatePath: Qt.resolvedUrl("locate").toString().replace(/^file:\/\//, "")
  readonly property string credentialsPath: Qt.resolvedUrl("save-credentials").toString().replace(/^file:\/\//, "")
  readonly property string credentialsFile: Qt.resolvedUrl("opensky.json").toString().replace(/^file:\/\//, "")

  property bool hasCredentials: false

  function setNotice(text, isError) {
    settingsNotice = text
    settingsNoticeIsError = isError === true
  }

  function checkCredentials() {
    if (credentialsCheck.running) return
    credentialsCheck.command = ["test", "-s", credentialsFile]
    credentialsCheck.running = true
  }

  function saveCredentials() {
    var id = String(clientIdField.text).replace(/^\s+|\s+$/g, "")
    var secret = String(clientSecretField.text)

    if (id === "" || secret === "") {
      setNotice("Enter both an OpenSky client ID and secret.", true)
      return
    }

    setNotice("", false)
    credentialsSaving = true
    credentialsAction = "save"
    credentialsProcess.stdinEnabled = true
    credentialsProcess.command = ["bash", credentialsPath]
    credentialsProcess.running = true
    credentialsProcess.write(JSON.stringify({ clientId: id, clientSecret: secret }))
    credentialsProcess.stdinEnabled = false
  }

  function clearCredentials() {
    setNotice("", false)
    credentialsSaving = true
    credentialsAction = "clear"
    credentialsProcess.stdinEnabled = false
    credentialsProcess.command = ["bash", credentialsPath, "--clear"]
    credentialsProcess.running = true
  }

  // Panel-edited settings go to the plugin's own file, not to shell.json: any
  // shell.json write rebuilds every bar widget, which would tear the panel down
  // mid-edit and discard all tracked aircraft. Keys set in shell.json still win,
  // so `omarchy bar set` keeps working for the rest.
  readonly property string configPath: Qt.resolvedUrl("settings.json").toString().replace(/^file:\/\//, "")

  property var userConfig: ({})

  // Overrides the base lookup: `omarchy bar set` stores "false" as a string
  // unless it is given --json, so a boolean setting has to be coerced.
  function setting(key, fallback) {
    var value = settings ? settings[key] : undefined
    if (value === undefined || value === null) return fallback
    if (typeof fallback !== "boolean") return value
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value !== false
  }

  function conf(key, fallback) {
    var fromShell = settings ? settings[key] : undefined
    if (fromShell !== undefined && fromShell !== null) return fromShell
    if (userConfig && userConfig[key] !== undefined && userConfig[key] !== null) return userConfig[key]
    return fallback
  }

  function applyUserConfig(raw) {
    var parsed
    try {
      parsed = JSON.parse(String(raw || "{}"))
    } catch (e) {
      parsed = {}
    }
    userConfig = (parsed && typeof parsed === "object") ? parsed : ({})
  }

  function saveConfig(values) {
    var next = ({})
    for (var k in userConfig) next[k] = userConfig[k]

    for (var key in values) {
      if (values[key] === null) delete next[key]
      else next[key] = values[key]
    }

    userConfig = next
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  readonly property string overheadText: RadarModel.formatDistance(overheadRadiusNm * 1.852, aviationUnits)

  readonly property string summary: {
    if (autoError !== "" && !hasCentre) return "Radar: " + autoError
    if (!hasCentre) return "Radar: working out your approximate location…"
    if (!initialized) return "Checking for aircraft overhead…"
    if (limitReached) return "Radar paused — " + lastError
    if (lastError !== "") return "Radar unavailable: " + lastError

    var inRange = contacts.length === 0
      ? "no aircraft within " + rangeText
      : contacts.length + " within " + rangeText

    if (overheadCount > 0)
      return overheadCount + (overheadCount === 1 ? " aircraft overhead" : " aircraft overhead")
        + " (≤" + overheadText + ") · " + inRange

    return inRange.charAt(0).toUpperCase() + inRange.slice(1)
  }

  function loadCentreFields() {
    centreFieldsLoaded = true
    latitudeField.text = hasManualCentre ? String(latitudeSetting) : ""
    longitudeField.text = hasManualCentre ? String(longitudeSetting) : ""
    rangeField.field.value = rangeNm
    overheadField.field.value = overheadRadiusNm
    ceilingField.field.value = overheadCeilingFt
    setNotice("", false)
  }

  // The coordinate half of an edit: {} for "leave them alone", null when the
  // fields do not parse. Empty fields only mean "clear" once they have been
  // filled from the stored values.
  function centreEdit() {
    if (!centreFieldsLoaded) return ({})

    var latText = String(latitudeField.text).replace(/^\s+|\s+$/g, "")
    var lonText = String(longitudeField.text).replace(/^\s+|\s+$/g, "")

    if (latText === "" && lonText === "")
      return hasManualCentre ? { latitude: null, longitude: null } : ({})

    var lat = parseFloat(latText)
    var lon = parseFloat(lonText)

    if (!isFinite(lat) || !isFinite(lon)) {
      setNotice("Enter both a latitude and a longitude, or clear both to locate automatically.", true)
      return null
    }
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      setNotice("Latitude must be between -90 and 90, longitude between -180 and 180.", true)
      return null
    }

    if (hasManualCentre
        && Math.abs(lat - parseFloat(String(latitudeSetting))) < 1e-9
        && Math.abs(lon - parseFloat(String(longitudeSetting))) < 1e-9) return ({})

    return { latitude: lat, longitude: lon }
  }

  function saveSettings() {
    var edit = centreEdit()
    if (edit === null) return

    edit.rangeNm = rangeField.field.value
    edit.overheadRadiusNm = overheadField.field.value
    edit.overheadCeilingFt = ceilingField.field.value

    if (edit.latitude === null) autoResolved = false
    saveConfig(edit)
    setNotice("Settings saved.", false)
  }

  function resetSettings() {
    latitudeField.text = ""
    longitudeField.text = ""
    autoResolved = false

    saveConfig({
      latitude: null,
      longitude: null,
      rangeNm: null,
      overheadRadiusNm: null,
      overheadCeilingFt: null
    })

    rangeField.field.value = rangeNm
    overheadField.field.value = overheadRadiusNm
    ceilingField.field.value = overheadCeilingFt
    setNotice("Settings reset.", false)
  }

  function resolveAutoLocation() {
    if (hasManualCentre || locateProcess.running) return
    locateProcess.command = ["bash", locatePath]
    locateProcess.running = true
  }

  function applyAutoLocation(raw) {
    var data
    try {
      data = JSON.parse(String(raw || ""))
    } catch (e) {
      autoError = "Could not read the location helper's output"
      return
    }

    if (!data || data.error) {
      autoError = data && data.error ? String(data.error) : "Location lookup failed"
      return
    }

    var lat = parseFloat(data.latitude)
    var lon = parseFloat(data.longitude)
    if (!isFinite(lat) || !isFinite(lon)) {
      autoError = "Location lookup returned no usable coordinates"
      return
    }

    autoLat = lat
    autoLon = lon
    autoError = ""
    autoResolved = true

    refresh(true)
  }

  function refresh(force) {
    if (fetchProcess.running) return
    if (!hasCentre) {
      resolveAutoLocation()
      return
    }

    var now = Date.now()
    if (!force && initialized && now - lastFetchAt < reuseWindowMs) return
    lastFetchAt = now
    refreshing = true

    var box = RadarModel.boundingBox(centreLat, centreLon, radiusDeg)
    fetchProcess.command = ["bash", helperPath,
      box.lamin.toFixed(6), box.lomin.toFixed(6), box.lamax.toFixed(6), box.lomax.toFixed(6)]
    fetchProcess.running = true
  }

  function applyOutput(raw) {
    var result = RadarModel.parseResponse(raw)
    initialized = true
    refreshing = false

    if (!result.ok) {
      lastError = result.error
      limitReached = result.limited === true
      return
    }

    lastError = ""
    limitReached = false
    authenticated = result.authenticated
    mergeAircraft(result.aircraft)
    lastUpdatedAt = Qt.formatTime(new Date(), "HH:mm:ss")
    rebuildContacts()
    evaluateOverhead()
    scope.requestPaint()
  }

  function snapPositions() {
    for (var icao in trackedById) trackedById[icao].blendActive = false

    var now = frameNow > 0 ? frameNow : Date.now()
    var live = RadarModel.buildContacts(trackedById, now,
      centreLat, centreLon, radiusDeg, unitSize)
    var seeded = ({})
    for (var i = 0; i < live.length; i++) {
      seeded[live[i].icao24] = {
        lat: live[i].lat,
        lon: live[i].lon,
        trueTrack: live[i].trueTrack
      }
    }
    heldPositions = seeded
  }

  function sweepCrossed(angle, current) {
    var twoPi = Math.PI * 2
    return Math.floor((current - angle) / twoPi) > Math.floor((prevSweepAngle - angle) / twoPi)
  }

  function scopeAngle(x, y) {
    var centre = unitSize / 2 - 1
    var angle = Math.atan2(y - centre, x - centre)
    return angle < 0 ? angle + Math.PI * 2 : angle
  }

  function sweptPositions() {
    return showSweep ? heldPositions : null
  }

  function mergeAircraft(aircraft) {
    var now = Date.now()
    var next = ({})

    for (var i = 0; i < aircraft.length; i++) {
      var ac = aircraft[i]
      var existing = trackedById[ac.icao24]
      if (existing) {
        RadarModel.updateTracked(existing, ac, now)
        next[ac.icao24] = existing
      } else {
        next[ac.icao24] = RadarModel.makeTracked(ac, now)
      }
    }

    trackedById = next

    if (snapOnNextFix) {
      snapOnNextFix = false
      snapPositions()
    }

    var keptGlow = ({})
    for (var icao in litAt) {
      if (next[icao] !== undefined) keptGlow[icao] = litAt[icao]
    }
    litAt = keptGlow

    var keptHeld = ({})
    for (var heldIcao in heldPositions) {
      if (next[heldIcao] !== undefined) keptHeld[heldIcao] = heldPositions[heldIcao]
    }
    heldPositions = keptHeld
    drawnAt = -1
  }

  function rebuildContacts() {
    contacts = RadarModel.buildContacts(trackedById, Date.now(),
      centreLat, centreLon, radiusDeg, unitSize)
  }

  function openOnMap(icao24) {
    var hex = String(icao24 || "").toLowerCase()
    if (hex === "") return

    Quickshell.execDetached(["omarchy-launch-browser",
      "https://map.opensky-network.org/?icao=" + hex])
    close()
  }

  // One projection per animation frame, shared by the canvas and the hit test:
  // cursorShape re-evaluates on every pointer move, which otherwise reprojected
  // every aircraft to decide which cursor to draw.
  function drawnContacts() {
    var now = frameNow > 0 ? frameNow : Date.now()
    if (drawnAt === now) return drawn

    drawnAt = now
    drawn = RadarModel.buildContacts(trackedById, now,
      centreLat, centreLon, radiusDeg, unitSize, sweptPositions())
    return drawn
  }

  function contactAtCanvas(canvasX, canvasY, canvasSize) {
    if (canvasSize <= 0) return null

    var scale = canvasSize / unitSize
    var ux = canvasX / scale
    var uy = canvasY / scale

    var visible = drawnContacts()

    var best = null
    var bestDistance = 9      // units; a little larger than the triangle itself
    for (var i = 0; i < visible.length; i++) {
      var dx = visible[i].x - ux
      var dy = visible[i].y - uy
      var distance = Math.sqrt(dx * dx + dy * dy)
      if (distance < bestDistance) {
        bestDistance = distance
        best = visible[i]
      }
    }
    return best
  }

  function sendNotification(contact) {
    var text = RadarModel.notificationText(contact, aviationUnits)
    Quickshell.execDetached(["omarchy-notification-send",
      "--app-name", "radar", "-u", "low", "-g", radarGlyph,
      text.headline, text.body])
  }

  function evaluateOverhead() {
    var now = Date.now()
    var all = RadarModel.buildContacts(trackedById, now,
      centreLat, centreLon, radiusDeg, unitSize)
    var overhead = RadarModel.overheadContacts(all, overheadRadiusNm, overheadCeilingFt)

    var nextIds = ({})
    for (var i = 0; i < overhead.length; i++) {
      var contact = overhead[i]
      nextIds[contact.icao24] = true

      if (overheadIds[contact.icao24]) continue      // already counted, not new

      var last = notifiedAt[contact.icao24] || 0
      if (notifyEnabled && now - last > notifyCooldownMs) {
        notifiedAt[contact.icao24] = now
        sendNotification(contact)
      }
    }

    overheadIds = nextIds
    overheadCount = overhead.length
    pruneNotified(now)
  }

  function pruneNotified(now) {
    var kept = ({})
    for (var id in notifiedAt) {
      if (now - notifiedAt[id] < notifyCooldownMs * 2) kept[id] = notifiedAt[id]
    }
    notifiedAt = kept
  }

  function paintSweep(ctx, cx, cy, angleRad, reach) {
    var THICKNESS = 20
    var SPACING = 5

    var x1 = cx + Math.cos(angleRad) * reach
    var y1 = cy + Math.sin(angleRad) * reach
    var dx = x1 - cx
    var dy = y1 - cy
    var len = Math.sqrt(dx * dx + dy * dy)
    if (len <= 0) return

    var px = -dy / len
    var py = dx / len

    ctx.lineWidth = 1
    for (var i = 0; i <= THICKNESS; i++) {
      ctx.strokeStyle = tinted((i / THICKNESS) * 0.5)
      ctx.beginPath()
      ctx.moveTo(cx, cy)
      ctx.lineTo(x1 + px * i * SPACING, y1 + py * i * SPACING)
      ctx.stroke()
    }

    ctx.strokeStyle = ringOuterColor
    ctx.beginPath()
    ctx.moveTo(cx, cy)
    ctx.lineTo(x1 + px * THICKNESS * SPACING, y1 + py * THICKNESS * SPACING)
    ctx.stroke()
  }

  function updateSweepHits() {
    if (!showSweep || !opened) return

    var now = frameNow > 0 ? frameNow : Date.now()
    var current = (now - epochMs) * sweepRadiansPerMs + sweepLeadRadians

    if (prevSweepAngle < 0) {
      prevSweepAngle = current
      return
    }

    var visible = RadarModel.buildContacts(trackedById, now,
      centreLat, centreLon, radiusDeg, unitSize)
    var inRange = ({})

    for (var i = 0; i < visible.length; i++) {
      var contact = visible[i]
      inRange[contact.icao24] = true

      if (sweepCrossed(scopeAngle(contact.x, contact.y), current)) {
        litAt[contact.icao24] = now
        heldPositions[contact.icao24] = {
          lat: contact.lat,
          lon: contact.lon,
          trueTrack: contact.trueTrack
        }
      }
    }

    // The sweep erases as well as paints: a contact that has left the scope
    // holds its last blip until the line reaches it, then goes.
    for (var icao in heldPositions) {
      if (inRange[icao]) continue

      var hold = heldPositions[icao]
      var point = RadarModel.project(hold.lat, hold.lon,
        centreLat, centreLon, radiusDeg, unitSize)
      if (sweepCrossed(scopeAngle(point.x, point.y), current)) {
        delete heldPositions[icao]
        delete litAt[icao]
      }
    }

    prevSweepAngle = current
    drawnAt = -1
  }

  function contactGlow(icao24, now) {
    if (!showSweep) return 0

    var lit = litAt[icao24]
    if (lit === undefined) return 0

    var age = now - lit
    if (age <= 0) return 1
    return Math.max(0, 1 - age / sweepPeriodMs)
  }

  function paintContactGlow(ctx, contact, glow) {
    if (glow <= 0.02) return

    var layers = 4
    for (var i = layers; i >= 1; i--) {
      var radius = 2.5 + i * 2.4
      var alpha = glow * 0.15 * (1 - (i - 1) / (layers + 1))
      ctx.fillStyle = Qt.rgba(glowColor.r, glowColor.g, glowColor.b, alpha)
      ctx.beginPath()
      ctx.arc(contact.x, contact.y, radius, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  function paintRing(ctx, cx, cy, radius, colour) {
    ctx.strokeStyle = colour
    ctx.beginPath()
    ctx.arc(cx, cy, radius, 0, Math.PI * 2)
    ctx.stroke()
  }

  function labelBlock(contact) {
    var lines = [
      contact.callsign,
      RadarModel.formatSpeed(contact.velocity, aviationUnits),
      RadarModel.formatAltitude(contact.altitude, aviationUnits)
    ]

    var longest = 0
    for (var i = 0; i < lines.length; i++) longest = Math.max(longest, lines[i].length)

    var lineHeight = 9
    return {
      lines: lines,
      lineHeight: lineHeight,
      w: longest * 4.8,
      h: lines.length * lineHeight
    }
  }

  function boxInsideScope(box, centre, outer) {
    var corners = [[box.x, box.y], [box.x + box.w, box.y],
                   [box.x, box.y + box.h], [box.x + box.w, box.y + box.h]]

    for (var i = 0; i < corners.length; i++) {
      var dx = corners[i][0] - centre
      var dy = corners[i][1] - centre
      if (Math.sqrt(dx * dx + dy * dy) > outer) return false
    }
    return true
  }

  function boxesOverlap(a, b) {
    return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
  }

  function paintLabelBlock(ctx, block, x, y) {
    ctx.fillStyle = labelColor
    ctx.font = "8px \"" + fontFamily + "\""
    ctx.textAlign = "left"
    ctx.textBaseline = "top"

    for (var i = 0; i < block.lines.length; i++)
      ctx.fillText(block.lines[i], x, y + i * block.lineHeight)
  }

  function paintLabels(ctx, visible, centre, outer) {
    var placed = []

    for (var i = 0; i < visible.length; i++) {
      var contact = visible[i]
      var block = labelBlock(contact)
      var offsets = [[5, 5], [-5 - block.w, 5], [5, -5 - block.h], [-5 - block.w, -5 - block.h]]

      for (var j = 0; j < offsets.length; j++) {
        var box = {
          x: contact.x + offsets[j][0],
          y: contact.y + offsets[j][1],
          w: block.w,
          h: block.h
        }

        if (!boxInsideScope(box, centre, outer)) continue

        var collides = false
        for (var k = 0; k < placed.length; k++) {
          if (boxesOverlap(box, placed[k])) { collides = true; break }
        }
        if (collides) continue

        paintLabelBlock(ctx, block, box.x, box.y)
        placed.push(box)
        break
      }
    }
  }

  function paintContact(ctx, contact, glow) {
    var lit = Math.max(0, Math.min(1, glow || 0))
    var fill = litTint(lit)

    if (!showTriangles) {
      ctx.fillStyle = fill
      ctx.beginPath()
      ctx.arc(contact.x, contact.y, 3, 0, Math.PI * 2)
      ctx.fill()
      return
    }

    var track = contact.trueTrack * Math.PI / 180.0
    var dx = Math.sin(track)
    var dy = -Math.cos(track)
    var px = -dy
    var py = dx
    var LENGTH = 6.0
    var WIDTH = 3.0

    ctx.fillStyle = fill
    ctx.beginPath()
    ctx.moveTo(contact.x + dx * LENGTH, contact.y + dy * LENGTH)
    ctx.lineTo(contact.x - dx * LENGTH * 0.5 + px * WIDTH * 0.5,
               contact.y - dy * LENGTH * 0.5 + py * WIDTH * 0.5)
    ctx.lineTo(contact.x - dx * LENGTH * 0.5 - px * WIDTH * 0.5,
               contact.y - dy * LENGTH * 0.5 - py * WIDTH * 0.5)
    ctx.closePath()
    ctx.fill()
  }

  function paintScope(ctx) {
    var centre = unitSize / 2 - 1
    var outer = unitSize / 2 - 1
    var now = frameNow > 0 ? frameNow : Date.now()

    ctx.save()
    ctx.beginPath()
    ctx.arc(centre, centre, outer, 0, Math.PI * 2)
    ctx.clip()

    ctx.fillStyle = scopeBackground
    ctx.fillRect(0, 0, unitSize, unitSize)

    if (showSweep) paintSweep(ctx, centre, centre, (now - epochMs) / 3000.0, outer)

    ctx.lineWidth = 1
    paintRing(ctx, centre, centre, outer, ringOuterColor)
    paintRing(ctx, centre, centre, (outer / 3) * 2, ringMidColor)
    paintRing(ctx, centre, centre, outer / 3, ringInnerColor)

    var visible = drawnContacts()

    var overheadRing = RadarModel.overheadRingUnits(overheadRadiusNm, radiusDeg, unitSize)
    if (overheadRing >= 3 && overheadRing < outer)
      paintRing(ctx, centre, centre, overheadRing, overheadRingColor)

    if (showLabels) paintLabels(ctx, visible, centre, outer)

    var glows = []
    for (var g = 0; g < visible.length; g++) {
      glows.push(contactGlow(visible[g].icao24, now))
      paintContactGlow(ctx, visible[g], glows[g])
    }

    for (var i = 0; i < visible.length; i++) paintContact(ctx, visible[i], glows[i])

    ctx.restore()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    epochMs = Date.now()
    checkCredentials()
    if (!hasManualCentre) resolveAutoLocation()
  }

  onScopeTintChanged: scope.requestPaint()
  onScopeBackgroundChanged: scope.requestPaint()

  onHasManualCentreChanged: {
    if (!hasManualCentre) resolveAutoLocation()
    else refresh(true)
  }

  onOpenedChanged: {
    if (!opened) {
      settingsOpen = false
      return
    }
    frameNow = Date.now()
    snapOnNextFix = true
    snapPositions()
    refresh(false)
    rebuildContacts()
    checkCredentials()
    prevSweepAngle = -1
    scope.requestPaint()
    loadCentreFields()
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      scopeScroll.contentY = 0
    })
  }

  Timer {
    interval: radarRoot.pollIntervalMs
    running: radarRoot.watchEnabled || radarRoot.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: radarRoot.refresh(false)
  }

  Timer {
    interval: 3000
    running: radarRoot.watchEnabled || radarRoot.opened
    repeat: true
    onTriggered: radarRoot.evaluateOverhead()
  }

  Timer {
    interval: 50
    running: radarRoot.opened
    repeat: true
    onTriggered: {
      radarRoot.frameNow = Date.now()
      radarRoot.updateSweepHits()
      scope.requestPaint()
    }
  }

  Timer {
    interval: 2000
    running: radarRoot.opened
    repeat: true
    onTriggered: radarRoot.rebuildContacts()
  }

  FileView {
    id: manifestFile
    path: Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, "")
    watchChanges: false
    printErrors: false

    onLoaded: {
      try {
        var manifest = JSON.parse(text())
        radarRoot.version = String(manifest.version || "")
        radarRoot.repository = String(manifest.repository || manifest.homepage || "")
      } catch (e) {
        radarRoot.version = ""
        radarRoot.repository = ""
      }
    }
  }

  FileView {
    id: configFile
    path: radarRoot.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false

    onLoaded: radarRoot.applyUserConfig(text())
    onLoadFailed: radarRoot.applyUserConfig("{}")
    onFileChanged: reload()
  }

  Process {
    id: credentialsProcess
    running: false
    command: []
    stdinEnabled: true

    stderr: StdioCollector {
      id: credentialsStderr
      waitForEnd: true
    }

    onExited: function(exitCode) {
      radarRoot.credentialsSaving = false

      if (exitCode !== 0) {
        var detail = String(credentialsStderr.text || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
        radarRoot.setNotice(detail !== "" ? detail : "Could not update credentials", true)
        return
      }

      if (radarRoot.credentialsAction === "clear") {
        clientIdField.text = ""
        clientSecretField.text = ""
        radarRoot.setNotice("Credentials removed — back to anonymous access.", false)
      } else {
        clientSecretField.text = ""
        radarRoot.setNotice("Credentials saved.", false)
      }

      radarRoot.checkCredentials()
      radarRoot.refresh(true)
    }
  }

  Process {
    id: credentialsCheck
    running: false
    command: []
    onExited: function(exitCode) { radarRoot.hasCredentials = exitCode === 0 }
  }

  Process {
    id: locateProcess
    running: false
    command: []

    stdout: StdioCollector {
      id: locateStdout
      waitForEnd: true
    }

    onExited: function(exitCode) {
      if (exitCode === 0) radarRoot.applyAutoLocation(locateStdout.text)
      else radarRoot.autoError = "The location helper exited with code " + exitCode
    }
  }

  Process {
    id: fetchProcess
    running: false
    command: []

    stdout: StdioCollector {
      id: fetchStdout
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: fetchStderr
      waitForEnd: true
    }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        radarRoot.applyOutput(fetchStdout.text)
        return
      }

      radarRoot.initialized = true
      radarRoot.refreshing = false
      var detail = String(fetchStderr.text || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
      radarRoot.lastError = detail !== "" ? detail : "The radar helper exited with code " + exitCode
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: radarRoot.bar
    text: radarRoot.radarGlyph
    dimmed: radarRoot.lastError !== ""
    active: radarRoot.overheadCount > 0 && radarRoot.overheadKnown
    activeColor: radarRoot.badgeColor
    tooltipText: radarRoot.summary

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        radarRoot.refresh(true)
        return
      }

      radarRoot.toggle()
    }

    Rectangle {
      id: badge
      visible: radarRoot.overheadCount > 0 && radarRoot.overheadKnown
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      anchors.horizontalCenterOffset: button.opticalSize / 2 - Style.space(1)
      anchors.verticalCenterOffset: -(button.opticalSize / 2 - Style.space(2))
      height: badgeLabel.implicitHeight + Style.spaceReal(1)
      width: Math.max(height, badgeLabel.implicitWidth + Style.spaceReal(3))
      radius: height / 2
      color: radarRoot.badgeColor
      border.width: 1
      border.color: Color.bar.background

      Text {
        id: badgeLabel
        anchors.centerIn: parent
        text: String(radarRoot.overheadCount)
        color: radarRoot.badgeTextColor
        font.family: radarRoot.fontFamily
        font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.78))
        font.bold: true
      }
    }
  }

  KeyboardPanel {
    id: radarPanel
    anchorItem: button
    owner: radarRoot
    bar: radarRoot.bar
    open: radarRoot.opened
    focusTarget: keyCatcher
    contentWidth: radarPanel.fittedContentWidth(Math.max(radarRoot.scopeSize + Style.space(24), Style.space(430)))
    contentHeight: radarPanel.fittedContentHeight(radarColumn.implicitHeight,
      Style.space(radarRoot.settingsOpen ? 820 : 640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (radarRoot.removeConfirmOpen) radarRoot.removeConfirmOpen = false
        else radarRoot.close()
      }
      onTabRequested: function(direction) {
        if (radarRoot.removeConfirmOpen) return
        radarRoot.switchPanel(direction)
      }
      onTextKey: function(text) {
        if (radarRoot.removeConfirmOpen) return

        if (text === "r" || text === "R") radarRoot.refresh(true)
        else if (text === "s" || text === "S") {
          radarRoot.settingsOpen = !radarRoot.settingsOpen
          if (radarRoot.settingsOpen) radarRoot.loadCentreFields()
        }
      }

      Flickable {
        id: scopeScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: radarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        MouseArea {
          width: scopeScroll.contentWidth
          height: Math.max(scopeScroll.contentHeight, scopeScroll.height)
          acceptedButtons: Qt.LeftButton

          onPressed: function(mouse) {
            keyCatcher.forceActiveFocus()
            mouse.accepted = false
          }
        }

        Column {
          id: radarColumn
          width: scopeScroll.width
          spacing: Style.space(12)

          PanelHero {
            title: "Flight Radar"
            meta: radarRoot.lastError !== ""
              ? "Aircraft data unavailable"
              : (radarRoot.initialized
                  ? radarRoot.contacts.length + " " + (radarRoot.contacts.length === 1 ? "contact" : "contacts") + " within " + radarRoot.rangeText
                  : "Scanning…")
            detail: radarRoot.refreshing ? "SYNC"
              : (radarRoot.limitReached ? "LIMIT" : (radarRoot.lastError !== "" ? "OFFLINE" : "LIVE"))
            foreground: radarRoot.foreground
            fontFamily: radarRoot.fontFamily
            iconOpacity: radarRoot.lastError === "" ? 1 : 0.45
            iconComponent: Component {
              Text {
                text: radarRoot.radarGlyph
                color: radarRoot.foreground
                font.family: radarRoot.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            width: parent.width
            text: "R refresh · S settings"
            color: radarRoot.dim
            font.family: radarRoot.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignRight
          }

          Text {
            visible: radarRoot.lastError !== ""
            width: parent.width
            text: radarRoot.lastError
            color: radarRoot.urgent
            font.family: radarRoot.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Column {
            id: settingsColumn
            width: parent.width
            visible: radarRoot.settingsOpen
            spacing: Style.space(10)

            readonly property real cellWidth: Math.floor((width - Style.space(12)) / 2)
            readonly property real thirdWidth: Math.floor((width - Style.space(12) * 2) / 3)

            Grid {
              columns: 2
              columnSpacing: Style.space(12)
              rowSpacing: Style.space(10)

              Column {
                width: settingsColumn.cellWidth
                spacing: Style.space(3)

                Text {
                  text: "Latitude"
                  color: radarRoot.dim
                  font.family: radarRoot.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: latitudeField
                  width: parent.width
                  placeholderText: "auto"
                  foreground: radarRoot.foreground
                  font.family: radarRoot.fontFamily
                  Keys.onEscapePressed: keyCatcher.forceActiveFocus()
                  KeyNavigation.tab: longitudeField
                  KeyNavigation.backtab: clientSecretField
                  onAccepted: radarRoot.saveSettings()
                }
              }

              Column {
                width: settingsColumn.cellWidth
                spacing: Style.space(3)

                Text {
                  text: "Longitude"
                  color: radarRoot.dim
                  font.family: radarRoot.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: longitudeField
                  width: parent.width
                  placeholderText: "auto"
                  foreground: radarRoot.foreground
                  font.family: radarRoot.fontFamily
                  Keys.onEscapePressed: keyCatcher.forceActiveFocus()
                  KeyNavigation.tab: clientIdField
                  KeyNavigation.backtab: latitudeField
                  onAccepted: radarRoot.saveSettings()
                }
              }
            }

            Text {
              width: parent.width
              text: "Leave both coordinates blank to locate automatically"
              color: radarRoot.dim
              font.family: radarRoot.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Grid {
              columns: 3
              columnSpacing: Style.space(12)
              rowSpacing: Style.space(10)

              NumberField {
                id: rangeField
                width: settingsColumn.thirdWidth
                fieldWidth: settingsColumn.thirdWidth
                label: "Range (nm)"
                from: 5
                to: 120
                stepSize: 5
                value: Math.round(RadarModel.clampNumber(radarRoot.conf("rangeNm", 20), 5, 120, 20))
                foreground: radarRoot.foreground
                fontFamily: radarRoot.fontFamily
              }

              NumberField {
                id: overheadField
                width: settingsColumn.thirdWidth
                fieldWidth: settingsColumn.thirdWidth
                label: "Overhead (nm)"
                from: 1
                to: 60
                stepSize: 1
                value: Math.round(RadarModel.clampNumber(radarRoot.conf("overheadRadiusNm", 2), 1, 60, 2))
                foreground: radarRoot.foreground
                fontFamily: radarRoot.fontFamily
              }

              NumberField {
                id: ceilingField
                width: settingsColumn.thirdWidth
                fieldWidth: settingsColumn.thirdWidth
                label: "Ceiling (ft)"
                from: 0
                to: 60000
                stepSize: 1000
                value: Math.round(RadarModel.clampNumber(radarRoot.conf("overheadCeilingFt", 0), 0, 60000, 0))
                foreground: radarRoot.foreground
                fontFamily: radarRoot.fontFamily
              }
            }

            Text {
              width: parent.width
              visible: radarRoot.settingsNotice !== ""
              text: radarRoot.settingsNotice
              color: radarRoot.settingsNoticeIsError ? radarRoot.urgent : radarRoot.dim
              font.family: radarRoot.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(6)

              Button {
                text: "Save"
                tooltipText: "Apply the settings above"
                bordered: true
                foreground: radarRoot.foreground
                fontFamily: radarRoot.fontFamily
                fontSize: Style.font.caption
                onClicked: radarRoot.saveSettings()
              }

              Button {
                text: "Reset to defaults"
                tooltipText: "Put every setting above back to its default"
                bordered: true
                foreground: radarRoot.foreground
                fontFamily: radarRoot.fontFamily
                fontSize: Style.font.caption
                onClicked: radarRoot.resetSettings()
              }
            }

            PanelSeparator {
              foreground: radarRoot.foreground
            }

            Text {
              width: parent.width
              text: "OpenSky account (optional) — 4000 requests a day instead of 400. "
                + "<a href=\"https://opensky-network.org/\">Create an account</a>"
              textFormat: Text.StyledText
              color: radarRoot.dim
              linkColor: radarRoot.foreground
              font.family: radarRoot.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap

              onLinkActivated: function(link) {
                Quickshell.execDetached(["omarchy-launch-browser", link])
                radarRoot.close()
              }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
              }
            }

            Grid {
              columns: 2
              columnSpacing: Style.space(12)
              rowSpacing: Style.space(10)

              Column {
                width: settingsColumn.cellWidth
                spacing: Style.space(3)

                Text {
                  text: "Client ID"
                  color: radarRoot.dim
                  font.family: radarRoot.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: clientIdField
                  width: parent.width
                  enabled: !radarRoot.credentialsSaving
                  foreground: radarRoot.foreground
                  font.family: radarRoot.fontFamily
                  Keys.onEscapePressed: keyCatcher.forceActiveFocus()
                  KeyNavigation.tab: clientSecretField
                  KeyNavigation.backtab: longitudeField
                }
              }

              Column {
                width: settingsColumn.cellWidth
                spacing: Style.space(3)

                Text {
                  text: "Client secret"
                  color: radarRoot.dim
                  font.family: radarRoot.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: clientSecretField
                  width: parent.width
                  password: true
                  enabled: !radarRoot.credentialsSaving
                  foreground: radarRoot.foreground
                  font.family: radarRoot.fontFamily
                  Keys.onEscapePressed: keyCatcher.forceActiveFocus()
                  KeyNavigation.tab: latitudeField
                  KeyNavigation.backtab: clientIdField
                  onAccepted: radarRoot.saveCredentials()
                }
              }

              Button {
                width: settingsColumn.cellWidth
                text: radarRoot.credentialsSaving ? "Saving…" : "Save credentials"
                enabled: !radarRoot.credentialsSaving
                bordered: true
                foreground: radarRoot.foreground
                fontFamily: radarRoot.fontFamily
                fontSize: Style.font.caption
                onClicked: radarRoot.saveCredentials()
              }

              Button {
                width: settingsColumn.cellWidth
                visible: radarRoot.hasCredentials
                text: "Remove credentials"
                tooltipText: "Delete the credentials and go back to anonymous access"
                enabled: !radarRoot.credentialsSaving
                bordered: true
                foreground: radarRoot.foreground
                fontFamily: radarRoot.fontFamily
                fontSize: Style.font.caption
                onClicked: radarRoot.removeConfirmOpen = true
              }
            }

            PanelSeparator {
              foreground: radarRoot.foreground
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignRight
              visible: radarRoot.version !== ""
              text: {
                var label = "Flight Radar v" + radarRoot.version
                return radarRoot.repository === ""
                  ? label
                  : "<a href=\"" + radarRoot.repository + "\">" + label + "</a>"
              }
              textFormat: Text.StyledText
              color: radarRoot.dim
              linkColor: radarRoot.dim
              font.family: radarRoot.fontFamily
              font.pixelSize: Style.font.caption

              onLinkActivated: function(link) {
                Quickshell.execDetached(["omarchy-launch-browser", link])
                radarRoot.close()
              }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
              }
            }
          }

          PanelSeparator {
            visible: radarRoot.settingsOpen
            foreground: radarRoot.foreground
          }

          Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: radarRoot.scopeSize
            height: radarRoot.scopeSize

            Canvas {
              id: scope
              anchors.fill: parent
              renderStrategy: Canvas.Cooperative

              onPaint: {
                var ctx = getContext("2d")
                if (!ctx) return

                ctx.reset()
                ctx.save()
                var k = width / radarRoot.unitSize
                ctx.scale(k, k)
                radarRoot.paintScope(ctx)
                ctx.restore()
              }
            }

            MouseArea {
              id: scopeMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton
              cursorShape: radarRoot.contactAtCanvas(mouseX, mouseY, width)
                ? Qt.PointingHandCursor : Qt.ArrowCursor

              onPressed: keyCatcher.forceActiveFocus()

              onClicked: function(mouse) {
                var contact = radarRoot.contactAtCanvas(mouse.x, mouse.y, width)
                if (contact) radarRoot.openOnMap(contact.icao24)
              }
            }
          }

          Text {
            visible: radarRoot.hasCentre
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: radarRoot.centreLat.toFixed(4) + ", " + radarRoot.centreLon.toFixed(4)
            color: radarRoot.dim
            font.family: radarRoot.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: radarRoot.rangeText + " range · overhead ≤" + radarRoot.overheadText
              + (radarRoot.overheadCeilingFt > 0
                  ? " under " + Math.round(radarRoot.overheadCeilingFt) + "ft" : "")
              + " · " + (radarRoot.authenticated ? "authenticated" : "unauthenticated")
              + (radarRoot.hasCentre ? "" : " · locating…")
              + (radarRoot.watchEnabled ? "" : " · watch off")
            color: radarRoot.dim
            font.family: radarRoot.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            foreground: radarRoot.foreground
          }

          PanelSectionHeader {
            text: "CONTACTS"
            foreground: radarRoot.foreground
            fontFamily: radarRoot.fontFamily
          }

          Text {
            visible: !radarRoot.initialized
            width: parent.width
            text: "Scanning for aircraft…"
            color: radarRoot.dim
            font.family: radarRoot.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            visible: radarRoot.initialized
              && radarRoot.lastError === ""
              && radarRoot.contacts.length === 0
            width: parent.width
            text: "No aircraft in range right now."
            color: radarRoot.dim
            font.family: radarRoot.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: radarRoot.contacts

            delegate: CursorSurface {
              id: contactRow
              required property var modelData

              width: radarColumn.width
              height: implicitHeight
              implicitHeight: contactLabels.implicitHeight + Style.space(16)
              foreground: radarRoot.foreground
              hasCursor: rowMouse.containsMouse
              bordered: true

              Column {
                id: contactLabels
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(3)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(contactCallsign.implicitHeight, contactRange.implicitHeight)
                  height: implicitHeight

                  Text {
                    id: contactCallsign
                    anchors.left: parent.left
                    anchors.right: contactRange.left
                    anchors.rightMargin: Style.space(12)
                    text: contactRow.modelData.callsign
                      + (radarRoot.overheadIds[contactRow.modelData.icao24] ? "  ▲ OVERHEAD" : "")
                    color: radarRoot.overheadIds[contactRow.modelData.icao24]
                      ? radarRoot.urgent : radarRoot.foreground
                    font.family: radarRoot.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    id: contactRange
                    anchors.right: parent.right
                    text: RadarModel.formatDistance(contactRow.modelData.distanceKm, radarRoot.aviationUnits)
                      + " " + RadarModel.compassPoint(contactRow.modelData.bearing)
                    color: radarRoot.dim
                    font.family: radarRoot.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  width: parent.width
                  text: RadarModel.formatAltitude(contactRow.modelData.altitude, radarRoot.aviationUnits)
                    + RadarModel.verticalArrow(contactRow.modelData.verticalRate)
                    + " · " + RadarModel.formatSpeed(contactRow.modelData.velocity, radarRoot.aviationUnits)
                    + " · heading " + Math.round(contactRow.modelData.trueTrack) + "°"
                  color: radarRoot.dim
                  font.family: radarRoot.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: {
                    var parts = []
                    if (contactRow.modelData.originCountry !== "") parts.push(contactRow.modelData.originCountry)
                    if (contactRow.modelData.squawk !== "") parts.push("squawk " + contactRow.modelData.squawk)
                    return parts.join(" · ")
                  }
                  color: radarRoot.dim
                  font.family: radarRoot.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onClicked: radarRoot.openOnMap(contactRow.modelData.icao24)
              }
            }
          }

        }
      }

      ConfirmDialog {
        anchors.fill: parent
        z: 10
        opened: radarRoot.removeConfirmOpen
        message: "Remove your OpenSky credentials? The radar will fall back to anonymous access, limited to 400 requests a day."
        confirmText: "Remove"
        cancelText: "Keep"
        background: Color.background
        foreground: radarRoot.foreground
        fontFamily: radarRoot.fontFamily

        onConfirmed: {
          radarRoot.removeConfirmOpen = false
          radarRoot.clearCredentials()
        }
        onCanceled: radarRoot.removeConfirmOpen = false
      }
    }
  }
}
