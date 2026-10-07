import Foundation
import Testing
@testable import CircleGraph

@Test func preferencesValidateFieldsIndependentlyAndKeepDefaultDesign() {
    let fresh = ExplorerPreferences(values: [:])
    #expect(fresh.layout == .constellation)
    #expect(fresh.grouping == .circles)
    #expect(!fresh.boundaries)
    let restored = ExplorerPreferences(values: ["layout": "invalid", "grouping": "city", "location": "current", "boundaries": true, "motion": false])
    #expect(restored.layout == .constellation)
    #expect(restored.grouping == .city)
    #expect(restored.location == .current)
    #expect(restored.boundaries && !restored.motion)
    #expect(ExplorerPreferences(values: restored.values) == restored)
    var state = ExplorerState(selfID: "self")
    restored.apply(to: &state)
    #expect(state.focus == .person("self"))
    #expect(state.grouping == .city)
    #expect(ExplorerPreferences(state: state) == restored)
}

@Test func cameraCentersGroupsAndBoundsZoom() {
    var camera = GraphCamera()
    camera.center(on: [GraphPoint(x: 20, y: 30), GraphPoint(x: 100, y: 90)])
    #expect(camera.center == GraphPoint(x: 60, y: 60))
    #expect(camera.screen(GraphPoint(x: 60, y: 60), width: 400, height: 300) == GraphPoint(x: 200, y: 150))
    camera.setZoom(2)
    camera.pan(x: 40, y: -20)
    #expect(camera.center == GraphPoint(x: 40, y: 70))
    camera.setZoom(100)
    #expect(camera.zoom == 3)
    camera.setZoom(0)
    #expect(camera.zoom == 0.25)
    camera.center(on: [])
    #expect(camera.center.x.isFinite)
}
