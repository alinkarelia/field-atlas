import XCTest
import CoreLocation
import FieldCore
@testable import FieldAtlas

final class FieldPersistenceTests:XCTestCase {
    @MainActor private func makeStore()->AppStore {
        setenv("FIELD_ATLAS_TEST_SESSION",UUID().uuidString,1)
        return AppStore()
    }
    @MainActor func testTypingCoalescesOnlyNeverAttemptedChanges()throws{
        let store=makeStore();defer{unsetenv("FIELD_ATLAS_TEST_SESSION")}
        let p=FieldProject(title:"Test",type:.cemetery);try store.addProject(p)
        var record=Observation(projectId:p.id,kind:"grave")
        for i in 0..<20{record.title="Плита \(i)";try store.save(record)}
        XCTAssertEqual(store.state.outbox.count,1)
        let first=try XCTUnwrap(store.state.outbox.first);try store.updateMutation(first.id,base:0)
        record.title="Исправлено";try store.save(record)
        XCTAssertEqual(store.state.outbox.count,2)
        XCTAssertEqual(store.state.outbox.first?.record.title,"Плита 19")
        try store.acknowledge(first,version:1)
        XCTAssertEqual(store.state.outbox.count,1)
        XCTAssertTrue(try XCTUnwrap(store.state.records.first).dirty)
        XCTAssertEqual(AppStore().state.records.first?.title,"Исправлено")
    }
    @MainActor func testOldScanCoverageSurvivesMoreThanEightChunksAndRestart()throws{
        let store=makeStore();defer{unsetenv("FIELD_ATLAS_TEST_SESSION")}
        let p=FieldProject(title:"Sectors",type:.cemetery);try store.addProject(p)
        for i in 0..<12 {try store.saveScan(ScanChunk(frameId:"same",points:[[Double(i)*4,0,0,2]]),projectId:p.id)}
        try store.saveScan(ScanChunk(frameId:"unrelated",points:[[999,0,0,2]]),projectId:p.id)
        let restored=AppStore(),preview=restored.loadPreview(projectId:p.id,frameId:"same")
        XCTAssertEqual(preview.points.count,12)
        XCTAssertTrue(preview.points.contains{$0[0]==0})
        XCTAssertFalse(preview.points.contains{$0[0]==999})
        XCTAssertEqual(restored.state.scans.count,13)
    }
    @MainActor func testGPSBreakAndUndoRetainRecoverableTrack()throws{
        let recorder=LocationRecorder()
        let initial=TrackSnapshot(kind:"boundary",points:[[0,0],[2,0],[2,2]],segments:[[[0,0],[2,0]],[[2,2]]],needsReview:true)
        recorder.restore(initial);XCTAssertTrue(recorder.paused);XCTAssertTrue(recorder.needsReview)
        recorder.undo();XCTAssertEqual(recorder.points.count,2);XCTAssertEqual(recorder.segments.flatMap{$0}.count,2)
        recorder.undo();XCTAssertEqual(recorder.points.count,1);XCTAssertEqual(recorder.segments.flatMap{$0}.count,1)
        recorder.position=[1,2];recorder.positionTime=Date().addingTimeInterval(-60);recorder.accuracy=3
        XCTAssertNil(recorder.freshPosition)
        recorder.positionTime=Date();XCTAssertEqual(recorder.freshPosition,[1,2])
        recorder.accuracy=100;XCTAssertNil(recorder.freshPosition)
    }
    @MainActor func testMapOriginAndUncertainReadingSurviveRestart()throws{
        let store=makeStore();defer{unsetenv("FIELD_ATLAS_TEST_SESSION")}
        let p=FieldProject(title:"Grave",type:.cemetery);try store.addProject(p)
        var record=Observation(projectId:p.id,kind:"grave");record.origin=GeoOrigin(lat:61,lon:36);record.point=[5,7]
        record.transcription="18?4";record.unreadable=true;record.comments="Проверить на месте"
        try store.save(record)
        let restored=try XCTUnwrap(AppStore().state.records.first)
        XCTAssertEqual(restored.origin,record.origin);XCTAssertEqual(restored.point,[5,7])
        XCTAssertEqual(restored.transcription,"18?4");XCTAssertTrue(restored.unreadable)
        XCTAssertEqual(restored.status,"draft")
    }
}

