import XCTest
import FieldCore
@testable import FieldAtlas

final class MissionPersistenceTests:XCTestCase {
    @MainActor func testCorruptIndexCannotBeOverwrittenByStartingAnotherMission()throws {
        setenv("FIELD_ATLAS_TEST_SESSION",UUID().uuidString,1);defer{unsetenv("FIELD_ATLAS_TEST_SESSION")}
        let store=AppStore(),project=FieldProject(title:"Fixture",type:.land)
        try store.addProject(project)
        let path=store.root.appendingPathComponent("mission-index.json"),original=Data("{interrupted".utf8)
        try original.write(to:path)
        let recorder=FieldMissionRecorder();recorder.configure(store)
        XCTAssertFalse(recorder.storageReady)
        recorder.create(project:project,title:"Must not overwrite",mode:.timed,assignment:"")
        XCTAssertEqual(try Data(contentsOf:path),original)
        XCTAssertNil(recorder.selectedID)
    }
    @MainActor func testIncompleteJournalTailIsPreservedAndRecoveredBeforeResume()throws {
        setenv("FIELD_ATLAS_TEST_SESSION",UUID().uuidString,1);defer{unsetenv("FIELD_ATLAS_TEST_SESSION")}
        let store=AppStore(),project=FieldProject(title:"Fixture",type:.land)
        try store.addProject(project)
        let first=FieldMissionRecorder();first.configure(store);first.create(project:project,title:"Route",mode:.timed,assignment:"")
        first.pauseOrResume()
        let id=try XCTUnwrap(first.selectedID),path=store.root.appendingPathComponent("mission-"+id+".jsonl")
        let tail=Data("{\"kind\":\"fix\",\"time\":".utf8)
        let handle=try FileHandle(forWritingTo:path);try handle.seekToEnd();try handle.write(contentsOf:tail);try handle.close()
        let second=FieldMissionRecorder();second.configure(store)
        XCTAssertTrue(second.storageReady);XCTAssertEqual(second.summary.status,"paused")
        let recovery=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:store.root,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix(path.lastPathComponent+".recovery-")})
        XCTAssertEqual(try Data(contentsOf:recovery),tail)
        second.pauseOrResume();second.finish();XCTAssertEqual(second.summary.status,"completed")
        XCTAssertTrue(second.storageReady,second.message)
        let third=FieldMissionRecorder();third.configure(store);third.open(id)
        XCTAssertTrue(third.storageReady);XCTAssertEqual(third.summary.status,"completed")
    }
    @MainActor func testPausedTaskCannotBeHiddenByOpeningAnOldCompletedTask()throws {
        setenv("FIELD_ATLAS_TEST_SESSION",UUID().uuidString,1);defer{unsetenv("FIELD_ATLAS_TEST_SESSION")}
        let store=AppStore(),project=FieldProject(title:"Fixture",type:.land)
        try store.addProject(project)
        let recorder=FieldMissionRecorder();recorder.configure(store)
        recorder.create(project:project,title:"Old",mode:.timed,assignment:"");let old=try XCTUnwrap(recorder.selectedID);recorder.finish()
        XCTAssertTrue(recorder.storageReady,recorder.message)
        recorder.create(project:project,title:"Current",mode:.timed,assignment:"");let current=try XCTUnwrap(recorder.selectedID)
        XCTAssertNotEqual(current,old);XCTAssertEqual(recorder.summary.status,"running")
        recorder.pauseOrResume()
        recorder.open(old);XCTAssertEqual(recorder.selectedID,current);XCTAssertEqual(recorder.summary.status,"paused")
    }
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
