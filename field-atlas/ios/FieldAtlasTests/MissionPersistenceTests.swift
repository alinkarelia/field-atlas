import XCTest
import FieldCore
@testable import FieldAtlas

final class MissionPersistenceTests:XCTestCase {
    @MainActor func testTimedMissionSurvivesInterruptionAndExportsOriginals()throws {
        setenv("FIELD_ATLAS_TEST_SESSION",UUID().uuidString,1);defer{unsetenv("FIELD_ATLAS_TEST_SESSION")}
        let store=AppStore(),project=FieldProject(title:"Timing fixture",type:.land)
        try store.addProject(project)
        let first=FieldMissionRecorder();first.configure(store)
        first.create(project:project,title:"Control timer",mode:.timed,assignment:"fixture-task")
        XCTAssertEqual(first.summary.status,"running")
        first.checkpoint("Start gate")
        let second=FieldMissionRecorder();second.configure(store)
        XCTAssertEqual(second.summary.status,"interrupted")
        XCTAssertEqual(second.summary.checkpoints.count,1)
        second.pauseOrResume();XCTAssertEqual(second.summary.status,"running")
        second.pauseOrResume();XCTAssertEqual(second.summary.status,"paused")
        second.finish();XCTAssertEqual(second.summary.status,"completed")
        let record=try XCTUnwrap(store.state.records.first(where:{$0.fieldMissionID != nil}))
        XCTAssertEqual(record.title,"Control timer");XCTAssertEqual(record.sourceAssetIDs?.count,2)
        let file=try XCTUnwrap(store.state.assets.first(where:{$0.mime=="application/gpx+xml"}))
        XCTAssertTrue(try String(contentsOf:XCTUnwrap(store.assetURL(file.id)),encoding:.utf8).contains("<gpx"))
    }
}
