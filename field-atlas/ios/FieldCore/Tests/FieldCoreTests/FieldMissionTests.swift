import XCTest
@testable import FieldCore

final class FieldMissionTests:XCTestCase {
    func testPauseDoesNotJoinDisjointTracksOrCountPauseAsRecording(){
        var m=FieldMission(projectId:"p",title:"Маршрут",mode:.walking)
        m.events=[.init("start",time:0),.init("fix",time:1,fix:.init(time:1,lat:61,lon:36,accuracy:2,speed:1)),.init("fix",time:11,fix:.init(time:11,lat:61.00009,lon:36,accuracy:2,speed:1)),.init("pause",time:20),.init("resume",time:80),.init("fix",time:81,fix:.init(time:81,lat:62,lon:36,accuracy:2,speed:1)),.init("finish",time:100)]
        let s=m.summary(at:200)
        XCTAssertEqual(s.elapsed,100);XCTAssertEqual(s.recording,40);XCTAssertEqual(s.moving,10)
        XCTAssertEqual(s.distance,10,accuracy:0.2);XCTAssertEqual(s.segments.count,2);XCTAssertEqual(s.status,"completed")
    }
    func testDrivingAcceptsRoadSpeedButWalkingRejectsJump(){
        var m=FieldMission(projectId:"p",title:"Авто",mode:.driving)
        m.events=[.init("start",time:0),.init("fix",time:1,fix:.init(time:1,lat:61,lon:36,accuracy:4,speed:20)),.init("fix",time:6,fix:.init(time:6,lat:61.0009,lon:36,accuracy:4,speed:20))]
        XCTAssertEqual(m.summary(at:6).distance,100,accuracy:1)
        m.mode = .walking;XCTAssertEqual(m.summary(at:6).distance,0);XCTAssertEqual(m.summary(at:6).rejectedFixes,1)
    }
    func testPoorFixAndLongGapNeverInventTravel(){
        var m=FieldMission(projectId:"p",title:"GPS",mode:.driving)
        m.events=[.init("start",time:0),.init("fix",time:1,fix:.init(time:1,lat:61,lon:36,accuracy:4)),.init("fix",time:2,fix:.init(time:2,lat:65,lon:36,accuracy:200)),.init("fix",time:80,fix:.init(time:80,lat:62,lon:36,accuracy:4)),.init("fix",time:120,fix:.init(time:120,lat:63,lon:36,accuracy:4))]
        let s=m.summary(at:120);XCTAssertEqual(s.distance,0);XCTAssertEqual(s.moving,0);XCTAssertEqual(s.segments.count,3)
    }
    func testStationaryJitterAndInvalidCoordinatesDoNotAccumulateDistance(){
        var m=FieldMission(projectId:"p",title:"Пауза движения",mode:.walking);m.events=[.init("start",time:0)]
        for t in 1...40{m.events.append(.init("fix",time:Double(t),fix:.init(time:Double(t),lat:61+Double(t%2)*0.00001,lon:36,accuracy:4,speed:0)))}
        XCTAssertEqual(m.summary(at:40).distance,0);XCTAssertEqual(m.summary(at:40).moving,0)
        XCTAssertFalse(RouteFix(time:1,lat:999,lon:0,accuracy:2).valid)
    }
    func testGPXEscapesTitleAndPreservesSegmentBoundaries()throws{
        var m=FieldMission(projectId:"p",title:"A & <B>",mode:.walking)
        m.events=[.init("start",time:0),.init("fix",time:1,fix:.init(time:1,lat:61,lon:36,accuracy:1)),.init("pause",time:2),.init("resume",time:3),.init("fix",time:4,fix:.init(time:4,lat:62,lon:36,accuracy:1))]
        XCTAssertTrue(m.gpx.contains("A &amp; &lt;B&gt;"));XCTAssertEqual(m.gpx.components(separatedBy:"<trkseg>").count,3)
        XCTAssertEqual(try JSONDecoder().decode(FieldMission.self,from:JSONEncoder().encode(m)),m)
    }
}
