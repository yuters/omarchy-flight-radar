const test = require("node:test")
const assert = require("node:assert/strict")

const radar = require("../RadarModel.js")

function state(icao24, longitude, latitude) {
  return [icao24, "TEST", "Test", 1, 1, longitude, latitude,
    1000, false, 100, 90, 0, null, 1000, "1234"]
}

test("responses keep real zero coordinates and drop missing positions", () => {
  const result = radar.parseResponse(JSON.stringify({
    states: [
      state("valid", 0, 0),
      state("no-lon", null, 45),
      state("no-lat", -73, null)
    ]
  }))

  assert.equal(result.ok, true)
  assert.deepEqual(result.aircraft.map(aircraft => aircraft.icao24), ["valid"])
  assert.equal(result.aircraft[0].longitude, 0)
  assert.equal(result.aircraft[0].latitude, 0)
})

test("antimeridian scopes split into valid boxes and count both requests", () => {
  for (const longitude of [-179, 179]) {
    const boxes = radar.boundingBoxes(0, longitude, 2)

    assert.equal(boxes.length, 2)
    assert.equal(radar.requestCredits(boxes), 2)
    for (const box of boxes) {
      assert.ok(box.lomin >= -180)
      assert.ok(box.lomax <= 180)
      assert.ok(box.lomin < box.lomax)
    }
  }

  assert.equal(radar.boundingBoxes(45, -73, 2).length, 1)
})

test("motion availability distinguishes missing values from northbound zero", () => {
  const northbound = state("north", -73, 45)
  northbound[10] = 0

  const missing = state("missing", -73, 45)
  missing[9] = null
  missing[10] = null

  const result = radar.parseResponse(JSON.stringify({ states: [northbound, missing] }))

  assert.equal(result.aircraft[0].trueTrack, 0)
  assert.equal(result.aircraft[0].hasTrueTrack, true)
  assert.equal(result.aircraft[0].hasVelocity, true)
  assert.equal(result.aircraft[1].hasTrueTrack, false)
  assert.equal(result.aircraft[1].hasVelocity, false)
})

function movingAircraft({ heading, sampledAt, longitude = 0.05 }) {
  return {
    icao24: "forecast",
    callsign: "FORECAST",
    originCountry: "Test",
    timePosition: sampledAt,
    lastContact: sampledAt,
    longitude,
    latitude: 0,
    baroAltitude: 3000,
    onGround: false,
    velocity: 100,
    hasVelocity: true,
    trueTrack: heading,
    hasTrueTrack: true,
    verticalRate: 0,
    geoAltitude: 3000,
    squawk: "1234"
  }
}

function trackedWithHeadings(now, firstHeading, secondHeading) {
  const first = movingAircraft({ heading: firstHeading, sampledAt: now / 1000 - 20 })
  const tracked = radar.makeTracked(first, now - 10000)
  const second = movingAircraft({ heading: secondHeading, sampledAt: now / 1000 - 10 })
  radar.updateTracked(tracked, second, now)
  return tracked
}

test("stable inbound tracks predict their closest approach", () => {
  const now = 1700000000000
  const tracked = trackedWithHeadings(now, 270, 272)
  const approach = radar.forecastApproach(tracked, { lat: 0, lon: 0.05 }, now, 0, 0)

  assert.ok(approach)
  assert.ok(approach.etaSeconds > 50 && approach.etaSeconds < 60)
  assert.ok(approach.distanceKm < 0.2)
})

test("forecasts reject unstable, stale, and receding tracks", () => {
  const now = 1700000000000
  const unstable = trackedWithHeadings(now, 240, 270)
  assert.equal(radar.forecastApproach(unstable, { lat: 0, lon: 0.05 }, now, 0, 0), null)

  const stale = trackedWithHeadings(now, 270, 270)
  stale.state.timePosition = now / 1000 - 121
  assert.equal(radar.forecastApproach(stale, { lat: 0, lon: 0.05 }, now, 0, 0), null)

  assert.equal(radar.closestApproach({ lat: 0, lon: 0.05 }, 90, 100, 0, 0, 600), null)
})

test("forecast qualification respects the overhead ring and ceiling", () => {
  function contact(id, distanceNm, closestNm, etaSeconds, altitude = 3000) {
    return {
      icao24: id,
      distanceKm: distanceNm * 1.852,
      closestDistanceKm: closestNm * 1.852,
      approachEtaSeconds: etaSeconds,
      altitude
    }
  }

  const contacts = [
    contact("later", 5, 1, 240),
    contact("sooner", 4, 0.5, 120),
    contact("already-overhead", 1, 0.2, 30),
    contact("misses", 5, 3, 120),
    contact("too-high", 5, 1, 90, 6000)
  ]

  const forecasts = radar.forecastContacts(contacts, 2, 15000)

  assert.deepEqual(forecasts.map(contact => contact.icao24), ["sooner", "later"])
  assert.equal(radar.forecastText(forecasts[0], true), "INBOUND · 2 min · closest 0.5nm")
})

test("notification batches preserve every aircraft", () => {
  const alerts = [
    { headline: "FIRST approaching overhead", body: "Closest in 2 min", forecast: true },
    { headline: "SECOND approaching overhead", body: "Closest in 4 min", forecast: true }
  ]

  const batch = radar.notificationBatchText(alerts)

  assert.equal(batch.headline, "2 aircraft approaching overhead")
  assert.match(batch.body, /FIRST approaching overhead · Closest in 2 min/)
  assert.match(batch.body, /SECOND approaching overhead · Closest in 4 min/)
  assert.deepEqual(radar.notificationBatchText([alerts[0]]), {
    headline: alerts[0].headline,
    body: alerts[0].body
  })
})
