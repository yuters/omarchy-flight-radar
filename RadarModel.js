
var LAT_METERS_PER_DEG = 111320.0
// The firmware's blend counter advances 0.15 per second (~6.7s per correction).
// Expressed as a duration because progress here is derived from the clock: an
// accumulating counter would advance once per caller rather than once per frame,
// and both the canvas and the list timer ask.
var BLEND_DURATION_MS = 1000.0 / 0.15
var METERS_PER_SEC_TO_KNOTS = 1.943844
var METERS_TO_FEET = 3.280840
var EARTH_RADIUS_KM = 6371.0

function parseAircraft(state) {
  function num(index) {
    var value = state[index]
    if (value === null || value === undefined) return 0
    var parsed = parseFloat(value)
    return isFinite(parsed) ? parsed : 0
  }

  function str(index) {
    var value = state[index]
    return value === null || value === undefined ? "" : String(value).replace(/^\s+|\s+$/g, "")
  }

  return {
    icao24: str(0),
    callsign: str(1),
    originCountry: str(2),
    timePosition: num(3),
    lastContact: num(4),
    longitude: num(5),
    latitude: num(6),
    baroAltitude: num(7),
    onGround: state[8] === true,
    velocity: num(9),
    trueTrack: num(10),
    verticalRate: num(11),
    geoAltitude: num(13),
    squawk: str(14)
  }
}

function parseResponse(raw) {
  var empty = { ok: false, error: "", limited: false, authenticated: false, aircraft: [] }

  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    empty.error = "The radar helper returned unreadable output"
    return empty
  }

  if (!data || typeof data !== "object") {
    empty.error = "The radar helper returned unreadable output"
    return empty
  }

  if (data.error) {
    empty.error = String(data.error)
    empty.limited = data.limited === true
    return empty
  }

  var states = data.states
  if (!states || typeof states.length !== "number") states = []

  var aircraft = []
  for (var i = 0; i < states.length; i++) {
    var state = states[i]
    if (!state || typeof state.length !== "number") continue

    var parsed = parseAircraft(state)
    if (parsed.icao24 === "") continue
    aircraft.push(parsed)
  }

  return {
    ok: true,
    error: "",
    limited: false,
    authenticated: data.authenticated === true,
    aircraft: aircraft
  }
}

function makeTracked(aircraft, now) {
  return {
    state: aircraft,
    lastSeen: now,
    blendFromLat: aircraft.latitude,
    blendFromLon: aircraft.longitude,
    blendStart: now,
    blendActive: false      // first sighting is drawn where it actually is
  }
}

function updateTracked(tracked, aircraft, now) {
  var current = displayPosition(tracked, now)
  tracked.blendFromLat = current.lat
  tracked.blendFromLon = current.lon
  tracked.blendStart = now
  tracked.blendActive = true
  tracked.state = aircraft
  tracked.lastSeen = now
}

function blendAlpha(tracked, now) {
  if (!tracked.blendActive) return 1.0
  return Math.max(0.0, Math.min((now - tracked.blendStart) / BLEND_DURATION_MS, 1.0))
}

function predictPosition(tracked, now) {
  var state = tracked.state

  var dataAgeOnArrival = 0
  if (state.timePosition > 0 && state.lastContact > 0)
    dataAgeOnArrival = state.lastContact - state.timePosition

  var dt = (now - tracked.lastSeen) / 1000.0 + dataAgeOnArrival
  var headingRad = state.trueTrack * Math.PI / 180.0
  var cosLat = Math.cos(state.latitude * Math.PI / 180.0)
  if (Math.abs(cosLat) < 1e-6) cosLat = 1e-6

  var deltaLat = (state.velocity * dt * Math.cos(headingRad)) / LAT_METERS_PER_DEG
  var deltaLon = (state.velocity * dt * Math.sin(headingRad)) / (LAT_METERS_PER_DEG * cosLat)

  return { lat: state.latitude + deltaLat, lon: state.longitude + deltaLon }
}

function displayPosition(tracked, now) {
  var dead = predictPosition(tracked, now)
  var a = blendAlpha(tracked, now)
  if (a >= 1.0) return dead

  var t = a * a * (3.0 - 2.0 * a)

  return {
    lat: tracked.blendFromLat + t * (dead.lat - tracked.blendFromLat),
    lon: tracked.blendFromLon + t * (dead.lon - tracked.blendFromLon)
  }
}

function normalizeLonDelta(delta) {
  var d = delta
  while (d > 180) d -= 360
  while (d < -180) d += 360
  return d
}

function project(lat, lon, centreLat, centreLon, radiusDeg, size) {
  var centre = size / 2 - 1
  var pxPerDeg = centre / radiusDeg
  var dLat = lat - centreLat
  var dLon = normalizeLonDelta(lon - centreLon)

  return {
    x: centre + dLon * Math.cos(centreLat * Math.PI / 180.0) * pxPerDeg,
    y: centre - dLat * pxPerDeg
  }
}

function distanceKm(fromLat, fromLon, toLat, toLon) {
  var dLat = (toLat - fromLat) * Math.PI / 180.0
  var dLon = normalizeLonDelta(toLon - fromLon) * Math.PI / 180.0
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(fromLat * Math.PI / 180.0) * Math.cos(toLat * Math.PI / 180.0) *
      Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(a)))
}

function bearingDeg(fromLat, fromLon, toLat, toLon) {
  var lat1 = fromLat * Math.PI / 180.0
  var lat2 = toLat * Math.PI / 180.0
  var dLon = normalizeLonDelta(toLon - fromLon) * Math.PI / 180.0
  var y = Math.sin(dLon) * Math.cos(lat2)
  var x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLon)
  var deg = Math.atan2(y, x) * 180.0 / Math.PI
  return (deg + 360) % 360
}

function boundingBox(centreLat, centreLon, radiusDeg) {
  var cosLat = Math.cos(centreLat * Math.PI / 180.0)
  if (Math.abs(cosLat) < 0.05) cosLat = 0.05
  var lonRadius = Math.min(radiusDeg / cosLat, 90)

  return {
    lamin: clampLat(centreLat - radiusDeg),
    lamax: clampLat(centreLat + radiusDeg),
    lomin: centreLon - lonRadius,
    lomax: centreLon + lonRadius
  }
}

function clampLat(value) {
  return Math.max(-90, Math.min(90, value))
}

var NM_PER_DEG_LAT = (LAT_METERS_PER_DEG / 1000.0) / 1.852

function rangeNmToDeg(rangeNm) {
  var nm = parseFloat(String(rangeNm))
  if (!isFinite(nm) || nm <= 0) return 0
  return nm / NM_PER_DEG_LAT
}

function rangeDegToNm(radiusDeg) {
  var deg = parseFloat(String(radiusDeg))
  if (!isFinite(deg) || deg <= 0) return 0
  return deg * NM_PER_DEG_LAT
}

function clampNumber(value, min, max, fallback) {
  var parsed = parseFloat(String(value))
  if (!isFinite(parsed)) return fallback
  return Math.max(min, Math.min(max, parsed))
}

function buildContacts(trackedById, now, centreLat, centreLon, radiusDeg, size, frozenAt) {
  var contacts = []
  var outer = size / 2 - 1

  for (var icao in trackedById) {
    var tracked = trackedById[icao]
    if (tracked.state.onGround) continue

    var at = (frozenAt && frozenAt[icao] !== undefined) ? frozenAt[icao] : now
    var position = displayPosition(tracked, at)
    var point = project(position.lat, position.lon, centreLat, centreLon, radiusDeg, size)

    var centre = size / 2 - 1
    var offsetX = point.x - centre
    var offsetY = point.y - centre
    if (Math.sqrt(offsetX * offsetX + offsetY * offsetY) > outer) continue

    var ground = distanceKm(centreLat, centreLon, position.lat, position.lon)
    var altitude = tracked.state.baroAltitude !== 0 ? tracked.state.baroAltitude : tracked.state.geoAltitude

    contacts.push({
      icao24: tracked.state.icao24,
      callsign: tracked.state.callsign !== "" ? tracked.state.callsign : tracked.state.icao24.toUpperCase(),
      x: point.x,
      y: point.y,
      trueTrack: tracked.state.trueTrack,
      velocity: tracked.state.velocity,
      verticalRate: tracked.state.verticalRate,
      altitude: altitude,
      originCountry: tracked.state.originCountry,
      squawk: tracked.state.squawk,
      distanceKm: ground,
      bearing: bearingDeg(centreLat, centreLon, position.lat, position.lon)
    })
  }

  contacts.sort(function(left, right) {
    return left.distanceKm - right.distanceKm
  })

  return contacts
}

function formatSpeed(metersPerSecond, useAviationUnits) {
  if (!isFinite(metersPerSecond) || metersPerSecond <= 0) return "—"
  if (useAviationUnits) return String(Math.round(metersPerSecond * METERS_PER_SEC_TO_KNOTS)) + "kt"
  return String(Math.round(metersPerSecond * 3.6)) + "km/h"
}

function formatAltitude(meters, useAviationUnits) {
  if (!isFinite(meters) || meters === 0) return "—"
  if (useAviationUnits) {
    var feet = Math.round(meters * METERS_TO_FEET / 100) * 100
    return String(feet) + "ft"
  }
  return String(Math.round(meters)) + "m"
}

function formatDistance(km, useAviationUnits) {
  if (!isFinite(km)) return "—"
  if (useAviationUnits) return (km / 1.852).toFixed(km / 1.852 < 10 ? 1 : 0) + "nm"
  return km.toFixed(km < 10 ? 1 : 0) + "km"
}

function isOverhead(contact, radiusNm, ceilingFt) {
  if (contact.distanceKm / 1.852 > radiusNm) return false

  if (ceilingFt > 0 && contact.altitude > 0) {
    if (Math.round(contact.altitude * METERS_TO_FEET) > ceilingFt) return false
  }

  return true
}

function overheadContacts(contacts, radiusNm, ceilingFt) {
  var out = []
  for (var i = 0; i < contacts.length; i++) {
    if (isOverhead(contacts[i], radiusNm, ceilingFt)) out.push(contacts[i])
  }
  return out
}

function overheadRingUnits(radiusNm, radiusDeg, size) {
  var scopeNm = (radiusDeg * LAT_METERS_PER_DEG / 1000.0) / 1.852
  if (scopeNm <= 0) return 0
  return (size / 2 - 1) * (radiusNm / scopeNm)
}

function notificationText(contact, useAviationUnits) {
  var trend = ""
  if (isFinite(contact.verticalRate) && Math.abs(contact.verticalRate) >= 0.5)
    trend = contact.verticalRate > 0 ? " · climbing" : " · descending"

  return {
    headline: contact.callsign + " overhead",
    body: formatDistance(contact.distanceKm, useAviationUnits)
      + " " + compassPoint(contact.bearing)
      + " · " + formatAltitude(contact.altitude, useAviationUnits)
      + " · " + formatSpeed(contact.velocity, useAviationUnits)
      + trend
  }
}

function compassPoint(bearing) {
  var points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
  var index = Math.round(((bearing % 360) + 360) % 360 / 22.5) % 16
  return points[index]
}

function verticalArrow(verticalRate) {
  if (!isFinite(verticalRate) || Math.abs(verticalRate) < 0.5) return ""
  return verticalRate > 0 ? "↑" : "↓"
}

function rangeLabel(radiusDeg, useAviationUnits) {
  return formatDistance(radiusDeg * LAT_METERS_PER_DEG / 1000.0, useAviationUnits)
}

if (typeof module !== "undefined") {
  module.exports = {
    parseAircraft: parseAircraft,
    parseResponse: parseResponse,
    makeTracked: makeTracked,
    updateTracked: updateTracked,
    blendAlpha: blendAlpha,
    predictPosition: predictPosition,
    displayPosition: displayPosition,
    normalizeLonDelta: normalizeLonDelta,
    project: project,
    distanceKm: distanceKm,
    bearingDeg: bearingDeg,
    boundingBox: boundingBox,
    rangeNmToDeg: rangeNmToDeg,
    rangeDegToNm: rangeDegToNm,
    clampNumber: clampNumber,
    buildContacts: buildContacts,
    formatSpeed: formatSpeed,
    formatAltitude: formatAltitude,
    formatDistance: formatDistance,
    isOverhead: isOverhead,
    overheadRingUnits: overheadRingUnits,
    overheadContacts: overheadContacts,
    notificationText: notificationText,
    compassPoint: compassPoint,
    verticalArrow: verticalArrow,
    rangeLabel: rangeLabel
  }
}
