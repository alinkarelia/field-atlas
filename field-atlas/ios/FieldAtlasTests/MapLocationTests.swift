import XCTest
import CoreLocation
import CryptoKit
import FieldCore
@testable import FieldAtlas

final class MapLocationTests:XCTestCase {
    @MainActor func testCoarseGPSIsVisibleWithoutCreatingSurveyOrigin(){
        let recorder=LocationRecorder();recorder.receive(CLLocation(coordinate:CLLocationCoordinate2D(latitude:61.79,longitude:34.35),altitude:0,horizontalAccuracy:80,verticalAccuracy:100,timestamp:Date()))
        XCTAssertEqual(recorder.visiblePosition,GeoOrigin(lat:61.79,lon:34.35));XCTAssertNil(recorder.origin);XCTAssertNil(recorder.freshPosition);XCTAssertTrue(recorder.message.contains("80"))
    }
    @MainActor func testManualUnanchoredGeometryIsNeverSilentlyMovedToGPS(){
        let recorder=LocationRecorder();recorder.begin(manual:true);recorder.addManual([10,20]);recorder.receive(CLLocation(coordinate:CLLocationCoordinate2D(latitude:61.79,longitude:34.35),altitude:0,horizontalAccuracy:4,verticalAccuracy:10,timestamp:Date()))
        XCTAssertNil(recorder.origin);XCTAssertEqual(recorder.points,[[10,20]]);XCTAssertNotNil(recorder.visiblePosition)
    }
    @MainActor func testOldAndInvalidFixesAreRejected(){
        let recorder=LocationRecorder();recorder.receive(CLLocation(coordinate:CLLocationCoordinate2D(latitude:61.79,longitude:34.35),altitude:0,horizontalAccuracy:4,verticalAccuracy:10,timestamp:Date().addingTimeInterval(-120)))
        XCTAssertNil(recorder.visiblePosition);XCTAssertNil(recorder.origin)
    }
    func testMapIntegrityRejectsTruncationAndChangedBytes()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var data=Data([80,77,84,105,108,101,115,3]);data.append(Data(repeating:0,count:119));let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        let json:[String:Any]=["id":"test","title":"Тест","revision":"1","dataDate":"26.11.2026","bounds":[28,60,38,67],"bytes":127,"sha256":hash,"url":"https://archiverf.ru/api/maps/files/"+hash+".pmtiles","maxZoom":3,"detail":"Проверка"]
        let package=try JSONDecoder().decode(MapPackage.self,from:JSONSerialization.data(withJSONObject:json));let file=root.appendingPathComponent("map.pmtiles");try data.write(to:file);XCTAssertNoThrow(try MapPackageStore.verify(file,package))
        try data.dropLast().write(to:file);XCTAssertThrowsError(try MapPackageStore.verify(file,package));data[120]=1;try data.write(to:file);XCTAssertThrowsError(try MapPackageStore.verify(file,package))
    }
}
