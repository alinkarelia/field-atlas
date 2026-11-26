import XCTest
import CoreLocation
import FieldCore
@testable import FieldAtlas

@MainActor final class SurveyWorkflowTests:XCTestCase {
    func testManualBoundarySurvivesSnapshotAndIgnoresGPS()throws {
        let recorder=LocationRecorder();recorder.begin(manual:true)
        [[0.0,0],[10,0],[10,10],[0,10]].forEach{recorder.addManual($0)}
        XCTAssertTrue(Geometry.validPolygon(recorder.points));XCTAssertEqual(Geometry.area(recorder.points),100)
        recorder.addManual([0,10]);recorder.addManual([.nan,0]);XCTAssertEqual(recorder.points.count,4)
        let snapshot=TrackSnapshot(kind:"boundary",points:recorder.points,segments:recorder.segments,needsReview:true,manual:true)
        let decoded=try JSONDecoder().decode(TrackSnapshot.self,from:JSONEncoder().encode(snapshot))
        let restored=LocationRecorder();restored.restore(decoded)
        XCTAssertTrue(restored.manual);XCTAssertFalse(restored.paused);XCTAssertEqual(restored.points,recorder.points)
        restored.locationManager(CLLocationManager(),didUpdateLocations:[fix(lat:59,lon:30)])
        XCTAssertEqual(restored.points.count,4)
        restored.undo();XCTAssertEqual(restored.segments.flatMap{$0}.count,3)
    }
    func testOldSnapshotRestoresPausedGPS()throws {
        let data=Data(#"{"kind":"road","points":[[0,0],[1,1]],"segments":[[[0,0],[1,1]]],"needsReview":false}"#.utf8)
        let snapshot=try JSONDecoder().decode(TrackSnapshot.self,from:data)
        let recorder=LocationRecorder();recorder.restore(snapshot)
        XCTAssertFalse(recorder.manual);XCTAssertTrue(recorder.paused);XCTAssertEqual(recorder.points.count,2)
    }
    func testPoorGPSDoesNotInventTrackPoints(){
        let recorder=LocationRecorder();recorder.origin=GeoOrigin(lat:59,lon:30);recorder.recording=true
        let manager=CLLocationManager()
        recorder.locationManager(manager,didUpdateLocations:[fix(lat:59,lon:30)])
        recorder.locationManager(manager,didUpdateLocations:[fix(lat:59.01,lon:30,accuracy:80)])
        XCTAssertEqual(recorder.points.count,1);XCTAssertTrue(recorder.needsReview)
        recorder.locationManager(manager,didUpdateLocations:[fix(lat:59.0001,lon:30)])
        XCTAssertEqual(recorder.segments.count,2)
    }
    func testRequiredMarkerKindsHaveDistinctStableIdentifiers(){
        XCTAssertEqual(Set(SurveyFeature.allCases.map(\.rawValue)),Set(["entrance","tree","dump","container","obstacle","anomaly"]))
        XCTAssertEqual(Set(SurveyFeature.allCases.map(\.symbol)).count,SurveyFeature.allCases.count)
    }
    func testUnanchoredDrawingCannotBecomeGeographicAfterLaterGPSFix(){
        XCTAssertNil(SurveyGeography.coordinate([10,20],origin:nil))
        let origin=GeoOrigin(lat:59,lon:30)
        let point=SurveyGeography.coordinate([0,111.32],origin:origin)
        XCTAssertEqual(point?.latitude ?? 0,59.001,accuracy:0.00000001)
        XCTAssertEqual(point?.longitude ?? 0,30,accuracy:0.00000001)
        XCTAssertNil(SurveyGeography.coordinate([.nan,0],origin:origin))
        XCTAssertNil(SurveyGeography.coordinate([0],origin:origin))
    }
    private func fix(lat:Double,lon:Double,accuracy:Double=3)->CLLocation{CLLocation(coordinate:CLLocationCoordinate2D(latitude:lat,longitude:lon),altitude:0,horizontalAccuracy:accuracy,verticalAccuracy:5,timestamp:Date())}
}
