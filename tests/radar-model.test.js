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
