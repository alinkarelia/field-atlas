import XCTest
@testable import FieldCore
final class CoreTests: XCTestCase {
    func testArea(){XCTAssertEqual(Geometry.area([[0,0],[3,0],[3,2],[0,2]]),6)}
    func testCrossing(){XCTAssertFalse(Geometry.validPolygon([[0,0],[3,3],[0,3],[3,0]]))}
    func testCoverage(){let c=Geometry.coverage([[0,0,0,2],[0.1,0.1,0,1],[5,5,0,0]]);XCTAssertEqual(c.count,1);XCTAssertEqual(c.first?.quality,2)}
    func testIsolation(){XCTAssertEqual(ProjectKind.cemetery.objectKind,"grave");XCTAssertNotEqual(ProjectKind.interior.objectKind,"grave")}
    func testMissing(){let o=Observation(projectId:"p",kind:"grave");XCTAssertTrue(o.missing.contains("Фото плиты"))}
    func testRecordRoundTripPreservesUncertaintyAndIdentity()throws{var o=Observation(projectId:"p",kind:"grave");o.transcription="18?4";var person=PersonReading();person.birth="18?4";o.persons=[person];let saved=try JSONEncoder().encode(o);let restored=try JSONDecoder().decode(Observation.self,from:saved);XCTAssertEqual(restored,o);XCTAssertEqual(restored.persons.first?.id,person.id)}
    func testPortablePlanWithoutOptionalMetadataDecodes()throws{
        let json=#"{"schema":"field-room-plan-v1","frameId":"f","rooms":[{"id":"r","name":"Room","walls":[{"id":"w","start":[0,0],"end":[4,0],"height":3,"base":0,"confidence":2}],"openings":[{"id":"d","kind":"door","wallId":"w","offset":1,"width":1,"height":2,"sill":0}]}]}"#
        let doc=try JSONDecoder().decode(RoomPlanDocument.self,from:Data(json.utf8))
        XCTAssertEqual(doc.rooms[0].walls[0].length,4);XCTAssertEqual(doc.rooms[0].openings[0].wallId,"w");XCTAssertNil(doc.rooms[0].ceilingHeight);XCTAssertNil(doc.rooms[0].floor)
        XCTAssertEqual(try JSONDecoder().decode(RoomPlanDocument.self,from:JSONEncoder().encode(doc)),doc)
    }
    func testPlanRoundTripKeepsNonuniformWallAndSourceReferences()throws{
        let wall=PlanWall(id:"w",code:"С1",start:[0,0],end:[4,0],height:3,base:0,confidence:1,profile:[[0,0],[4,0],[4,2],[0,3]])
        let room=MeasuredRoom(id:"r",name:"Комната",level:1,walls:[wall],openings:[],floor:nil)
        var record=Observation(projectId:"p",kind:"room");record.roomPlan=RoomPlanDocument(frameId:"frame",rooms:[room]);record.roomPlanSourceId="source";record.roomPlanModelId="model"
        XCTAssertEqual(try JSONDecoder().decode(Observation.self,from:JSONEncoder().encode(record)),record)
    }
    func testFloorProposalNeedsStableHeightAndManualConfirmation(){
        var hint=FloorSuggestion(level:1);hint.update(height:0,time:0)
        for t in 1...10{hint.update(height:3,time:Double(t))}
        XCTAssertEqual(hint.proposal,2);XCTAssertEqual(hint.level,1)
        hint.confirm(4);XCTAssertEqual(hint.level,4);XCTAssertNil(hint.proposal)
        for t in 11...20{hint.update(height:3.1,time:Double(t))};XCTAssertNil(hint.proposal)
    }
    func testFloorHintRejectsMovementAndResetsAcrossInterruption(){
        var hint=FloorSuggestion(level:0);hint.update(height:0,time:0)
        for t in 1...8{hint.update(height:Double(t),time:Double(t))};XCTAssertNil(hint.proposal)
        hint.restart();for t in 9...20{hint.update(height:8,time:Double(t))};XCTAssertNil(hint.proposal);XCTAssertEqual(hint.level,0)
    }
    func testCeilingSlopePreservesHeightAndRejectsCrossedOutline(){
        var value=CeilingMeasurement(frameId:"f",method:"manual-corners",floorPoint:[0,0,-1],points:[[0,0,1.7],[4,0,1.7],[4,3,2.2],[0,3,2.2]])
        XCTAssertTrue(value.valid);XCTAssertEqual(value.heights.min(),2.7);XCTAssertEqual(value.heights.max(),3.2)
        value.points?.swapAt(1,2);XCTAssertFalse(value.valid)
    }
    func testManualCeilingWithoutTimestampDecodes()throws{
        let json=#"{"schema":"field-ceiling-v1","method":"manual-height","reviewed":true,"manualHeight":2.75,"source":"Лазерная рулетка"}"#
        let value=try JSONDecoder().decode(CeilingMeasurement.self,from:Data(json.utf8));XCTAssertTrue(value.valid);XCTAssertEqual(value.createdAt,0)
        XCTAssertEqual(try JSONDecoder().decode(CeilingMeasurement.self,from:JSONEncoder().encode(value)),value)
    }
}
