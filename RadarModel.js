
var LAT_METERS_PER_DEG = 111320.0
// A contact eases onto a new fix over this long. A duration rather than a step
// per update, because progress is read from the clock: a step would advance
// once per caller, and both the canvas and the list timer ask.
var BLEND_DURATION_MS = 6667
var METERS_PER_SEC_TO_KNOTS = 1.943844
var METERS_TO_FEET = 3.280840
var EARTH_RADIUS_KM = 6371.0
// A forecast waits for two real observations, rejects a turn over 15°, and
// never projects a position more than ten minutes into the future.
var FORECAST_HORIZON_SECONDS = 10 * 60
var FORECAST_MAX_SOURCE_AGE_MS = 2 * 60 * 1000
var FORECAST_MAX_HEADING_CHANGE_DEG = 15

function parseAircraft(state) {
  function num(index) {
    var value = state[index]
    if (value === null || value === undefined) return 0
    var parsed = parseFloat(value)
    return isFinite(parsed) ? parsed : 0
  }

  function coordinate(index) {
    var value = state[index]
    if (value === null || value === undefined) return null
    var parsed = parseFloat(value)
    return isFinite(parsed) ? parsed : null
  }

  function optionalNumber(index) {
    var value = state[index]
    if (value === null || value === undefined) return null
    var parsed = parseFloat(value)
    return isFinite(parsed) ? parsed : null
  }

  function str(index) {
    var value = state[index]
    return value === null || value === undefined ? "" : String(value).replace(/^\s+|\s+$/g, "")
  }

  var velocity = optionalNumber(9)
  var trueTrack = optionalNumber(10)

  return {
    icao24: str(0),
    callsign: str(1),
    originCountry: str(2),
    timePosition: num(3),
    lastContact: num(4),
    longitude: coordinate(5),
    latitude: coordinate(6),
    baroAltitude: num(7),
    onGround: state[8] === true,
    velocity: velocity === null ? 0 : velocity,
    hasVelocity: velocity !== null,
    trueTrack: trueTrack === null ? 0 : trueTrack,
    hasTrueTrack: trueTrack !== null,
    verticalRate: num(11),
    geoAltitude: num(13),
    squawk: str(14)
  }
}

function numberOr(value, fallback) {
  var parsed = parseFloat(value)
  return isFinite(parsed) ? parsed : fallback
}

function parseResponse(raw) {
  var empty = { ok: false, error: "", limited: false, retryAfter: 0,
                authenticated: false, remaining: -1, aircraft: [] }

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
    empty.retryAfter = numberOr(data.retryAfter, 0)
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
    if (parsed.latitude === null || parsed.longitude === null) continue
    if (parsed.latitude < -90 || parsed.latitude > 90) continue
    if (parsed.longitude < -180 || parsed.longitude > 180) continue
    aircraft.push(parsed)
  }

  return {
    ok: true,
    error: "",
    limited: false,
    retryAfter: 0,
    authenticated: data.authenticated === true,
    remaining: numberOr(data.remaining, -1),
    aircraft: aircraft
  }
}

function makeTracked(aircraft, now) {
  var tracked = {
    state: aircraft,
    lastSeen: now,
    dropped: false,
    blendFromLat: aircraft.latitude,
    blendFromLon: aircraft.longitude,
    blendStart: now,
    blendActive: false,     // first sighting is drawn where it actually is
    motionSamples: []
  }
  recordMotionSample(tracked, aircraft)
  return tracked
}

function updateTracked(tracked, aircraft, now) {
  var current = displayPosition(tracked, now)
  tracked.blendFromLat = current.lat
  tracked.blendFromLon = current.lon
  tracked.blendStart = now
  tracked.blendActive = true
  tracked.state = aircraft
  tracked.lastSeen = now
  recordMotionSample(tracked, aircraft)
}

function motionSample(aircraft) {
  if (!aircraft.hasVelocity || !aircraft.hasTrueTrack) return null

  var sampledAt = Math.max(aircraft.timePosition, aircraft.lastContact)
  if (!isFinite(sampledAt) || sampledAt <= 0) return null

  return { sampledAt: sampledAt, trueTrack: aircraft.trueTrack }
}

function recordMotionSample(tracked, aircraft) {
  var sample = motionSample(aircraft)
  if (!sample) return

  // Repeated reads of the same OpenSky state do not prove a stable heading.
  var samples = tracked.motionSamples || []
  var last = samples.length > 0 ? samples[samples.length - 1] : null
  if (last && last.sampledAt === sample.sampledAt) {
    samples[samples.length - 1] = sample
    tracked.motionSamples = samples
    return
  }

  samples.push(sample)
  if (samples.length > 2) samples.shift()
  tracked.motionSamples = samples
}

function headingChangeDeg(from, to) {
  var change = Math.abs(from - to) % 360
  return Math.min(change, 360 - change)
}

function hasStableHeading(tracked) {
  var samples = tracked.motionSamples || []
  if (samples.length < 2) return false

  var previous = samples[samples.length - 2]
  var current = samples[samples.length - 1]
  return headingChangeDeg(previous.trueTrack, current.trueTrack) <= FORECAST_MAX_HEADING_CHANGE_DEG
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

function closestApproach(position, trueTrack, velocity, centreLat, centreLon, horizonSeconds) {
  if (!position || !isFinite(position.lat) || !isFinite(position.lon)) return null
  if (!isFinite(trueTrack) || !isFinite(velocity) || velocity <= 0) return null
  if (!isFinite(horizonSeconds) || horizonSeconds <= 0) return null

  var cosLat = Math.cos(centreLat * Math.PI / 180.0)
  if (Math.abs(cosLat) < 1e-6) cosLat = 1e-6

  var east = normalizeLonDelta(position.lon - centreLon) * LAT_METERS_PER_DEG * cosLat
  var north = (position.lat - centreLat) * LAT_METERS_PER_DEG
  var track = trueTrack * Math.PI / 180.0
  var eastVelocity = Math.sin(track) * velocity
  var northVelocity = Math.cos(track) * velocity
  var speedSquared = eastVelocity * eastVelocity + northVelocity * northVelocity
  var etaSeconds = -(east * eastVelocity + north * northVelocity) / speedSquared

  if (etaSeconds <= 0 || etaSeconds > horizonSeconds) return null

  var closestEast = east + eastVelocity * etaSeconds
  var closestNorth = north + northVelocity * etaSeconds

  return {
    etaSeconds: etaSeconds,
    distanceKm: Math.sqrt(closestEast * closestEast + closestNorth * closestNorth) / 1000.0
  }
}

function hasFreshPosition(state, now) {
  if (!isFinite(state.timePosition) || state.timePosition <= 0) return false

  var age = now - state.timePosition * 1000
  return age >= -60000 && age <= FORECAST_MAX_SOURCE_AGE_MS
}

function forecastApproach(tracked, position, now, centreLat, centreLon) {
  var state = tracked.state
  if (!state.hasVelocity || !state.hasTrueTrack) return null
  if (!hasFreshPosition(state, now)) return null
  if (!hasStableHeading(tracked)) return null

  return closestApproach(position, state.trueTrack, state.velocity,
    centreLat, centreLon, FORECAST_HORIZON_SECONDS)
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

// A WGS84 bounding box cannot wrap across the antimeridian. Split a crossing
// scope into the two valid boxes OpenSky expects, one on either side.
function boundingBoxes(centreLat, centreLon, radiusDeg) {
  var box = boundingBox(centreLat, centreLon, radiusDeg)
  if (box.lomin < -180) {
    return [
      { lamin: box.lamin, lamax: box.lamax, lomin: box.lomin + 360, lomax: 180 },
      { lamin: box.lamin, lamax: box.lamax, lomin: -180, lomax: box.lomax }
    ]
  }
  if (box.lomax > 180) {
    return [
      { lamin: box.lamin, lamax: box.lamax, lomin: box.lomin, lomax: 180 },
      { lamin: box.lamin, lamax: box.lamax, lomin: -180, lomax: box.lomax - 360 }
    ]
  }
  return [box]
}

// OpenSky bills /states/all by bounding-box area: 1 credit up to 25 square
// degrees, then 2, 3 and 4 as it crosses 100 and 400.
function boxAreaSqDeg(box) {
  return Math.abs(box.lamax - box.lamin) * Math.abs(box.lomax - box.lomin)
}

function boxCredits(box) {
  var area = boxAreaSqDeg(box)
  if (area <= 25) return 1
  if (area <= 100) return 2
  if (area <= 400) return 3
  return 4
}

function requestCredits(boxes) {
  if (typeof boxes.length !== "number") return boxCredits(boxes)

  var credits = 0
  for (var i = 0; i < boxes.length; i++) credits += boxCredits(boxes[i])
  return credits
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

function buildContacts(trackedById, now, centreLat, centreLon, radiusDeg, size, held, includeForecast, blend) {
  var contacts = []
  var outer = size / 2 - 1

  for (var icao in trackedById) {
    var tracked = trackedById[icao]
    if (tracked.state.onGround) continue

    // A track the API has stopped reporting exists only to hold its last blip
    // until the sweep wipes it. It is drawn from that hold and counted nowhere.
    if (tracked.dropped && !held) continue

    // Easing onto a new fix is a rendering nicety for contacts drawn live.
    // Everything that measures — the list, the overhead check, forecasts, and
    // the point the sweep freezes — wants the current estimate, not one still
    // travelling toward it.
    var position = blend ? displayPosition(tracked, now) : predictPosition(tracked, now)
    var drawnLat = position.lat
    var drawnLon = position.lon
    var track = tracked.state.trueTrack

    // Held in degrees, not pixels, so a hold survives a range or centre change.
    // With holds in play a contact is only drawn once the sweep has painted it.
    var hold = held ? held[icao] : null
    if (held && !hold) continue

    var altitude = tracked.state.baroAltitude !== 0 ? tracked.state.baroAltitude : tracked.state.geoAltitude
    var speed = tracked.state.velocity
    var callsign = tracked.state.callsign !== "" ? tracked.state.callsign : tracked.state.icao24.toUpperCase()

    // A hold is the whole blip as the sweep found it, label included. Letting
    // the altitude tick over while the contact sits where it was painted shows
    // a reading the sweep never took.
    if (hold) {
      drawnLat = hold.lat
      drawnLon = hold.lon
      track = hold.trueTrack
      if (hold.callsign !== undefined) callsign = hold.callsign
      if (hold.altitude !== undefined) altitude = hold.altitude
      if (hold.velocity !== undefined) speed = hold.velocity
    }

    var point = project(drawnLat, drawnLon, centreLat, centreLon, radiusDeg, size)

    var centre = size / 2 - 1
    var offsetX = point.x - centre
    var offsetY = point.y - centre
    if (Math.sqrt(offsetX * offsetX + offsetY * offsetY) > outer) continue

    var ground = distanceKm(centreLat, centreLon, position.lat, position.lon)
    var approach = includeForecast
      ? forecastApproach(tracked, position, now, centreLat, centreLon)
      : null

    contacts.push({
      icao24: tracked.state.icao24,
      callsign: callsign,
      x: point.x,
      y: point.y,
      lat: drawnLat,
      lon: drawnLon,
      trueTrack: track,
      velocity: speed,
      verticalRate: tracked.state.verticalRate,
      altitude: altitude,
      originCountry: tracked.state.originCountry,
      squawk: tracked.state.squawk,
      distanceKm: ground,
      bearing: bearingDeg(centreLat, centreLon, position.lat, position.lon),
      approachEtaSeconds: approach ? approach.etaSeconds : -1,
      closestDistanceKm: approach ? approach.distanceKm : -1
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

function isForecastContact(contact, radiusNm, ceilingFt) {
  if (contact.approachEtaSeconds <= 0 || contact.closestDistanceKm < 0) return false
  if (contact.distanceKm / 1.852 <= radiusNm) return false
  if (contact.closestDistanceKm / 1.852 > radiusNm) return false
  if (ceilingFt <= 0 || contact.altitude <= 0) return true
  return Math.round(contact.altitude * METERS_TO_FEET) <= ceilingFt
}

function forecastContacts(contacts, radiusNm, ceilingFt) {
  var out = []
  for (var i = 0; i < contacts.length; i++) {
    if (isForecastContact(contacts[i], radiusNm, ceilingFt)) out.push(contacts[i])
  }
  out.sort(function(left, right) {
    return left.approachEtaSeconds - right.approachEtaSeconds
  })
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

function formatForecastEta(seconds) {
  if (!isFinite(seconds) || seconds <= 0) return "—"
  var minutes = Math.max(1, Math.ceil(seconds / 60))
  return minutes + " min"
}

function forecastText(contact, useAviationUnits) {
  if (!contact || contact.approachEtaSeconds <= 0 || contact.closestDistanceKm < 0) return ""
  return "INBOUND · " + formatForecastEta(contact.approachEtaSeconds)
    + " · closest " + formatDistance(contact.closestDistanceKm, useAviationUnits)
}

function forecastNotificationText(contact, useAviationUnits) {
  return {
    headline: contact.callsign + " approaching overhead",
    body: "Closest in " + formatForecastEta(contact.approachEtaSeconds)
      + " at " + formatDistance(contact.closestDistanceKm, useAviationUnits)
      + " · " + formatAltitude(contact.altitude, useAviationUnits)
      + " · " + formatSpeed(contact.velocity, useAviationUnits)
  }
}

function notificationBatchText(notifications) {
  if (!notifications || notifications.length === 0) return { headline: "", body: "" }
  if (notifications.length === 1)
    return { headline: notifications[0].headline, body: notifications[0].body }

  var forecastCount = 0
  var closestForecastSeconds = -1
  for (var i = 0; i < notifications.length; i++) {
    if (!notifications[i].forecast) continue

    forecastCount++
    var eta = notifications[i].etaSeconds
    if (!isFinite(eta) || eta <= 0) continue
    if (closestForecastSeconds < 0 || eta < closestForecastSeconds)
      closestForecastSeconds = eta
  }

  var headline = notifications.length + " aircraft alerts"
  if (forecastCount === notifications.length)
    headline = notifications.length + " aircraft approaching overhead"
  if (forecastCount === 0)
    headline = notifications.length + " aircraft overhead"

  var body = "Open Flight Radar for positions and flight details."
  if (closestForecastSeconds > 0)
    body = "Closest one in " + formatForecastEta(closestForecastSeconds) + ".\n" + body

  return { headline: headline, body: body }
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
    numberOr: numberOr,
    makeTracked: makeTracked,
    updateTracked: updateTracked,
    headingChangeDeg: headingChangeDeg,
    hasStableHeading: hasStableHeading,
    blendAlpha: blendAlpha,
    predictPosition: predictPosition,
    displayPosition: displayPosition,
    normalizeLonDelta: normalizeLonDelta,
    project: project,
    distanceKm: distanceKm,
    bearingDeg: bearingDeg,
    closestApproach: closestApproach,
    forecastApproach: forecastApproach,
    boundingBox: boundingBox,
    boundingBoxes: boundingBoxes,
    boxAreaSqDeg: boxAreaSqDeg,
    requestCredits: requestCredits,
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
    isForecastContact: isForecastContact,
    forecastContacts: forecastContacts,
    notificationText: notificationText,
    formatForecastEta: formatForecastEta,
    forecastText: forecastText,
    forecastNotificationText: forecastNotificationText,
    notificationBatchText: notificationBatchText,
    compassPoint: compassPoint,
    verticalArrow: verticalArrow,
    rangeLabel: rangeLabel
  }
}
