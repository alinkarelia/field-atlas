import XCTest
@testable import FieldCore

final class MapPackageTests:XCTestCase {
    private func package(_ changes:[String:Any]=[:])throws->MapPackage{
        var value:[String:Any]=["id":"karelia","title":"Республика Карелия","revision":"20261126.1","dataDate":"26.11.2026","bounds":[28.9,60.65,37.95,66.7],"bytes":861071635,"sha256":String(repeating:"a",count:64),"url":"https://archiverf.ru/api/maps/files/"+String(repeating:"a",count:64)+".pmtiles","maxZoom":15,"detail":"Карта дорог"]
        value.merge(changes){_,new in new};return try JSONDecoder().decode(MapPackage.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testPetrozavodskBelongsToKareliaAndForeignRegionDoesNot()throws{
        let p=try package().validated();XCTAssertTrue(p.contains(GeoOrigin(lat:61.79,lon:34.35)));XCTAssertFalse(p.contains(GeoOrigin(lat:59.94,lon:30.31)));XCTAssertTrue(p.matches("карелия"))
    }
    func testCatalogCannotRedirectDownloadToArbitraryHostOrPath()throws{
        for url in ["https://evil.invalid/file","http://archiverf.ru/api/maps/files/a.pmtiles","https://archiverf.ru/api/maps/files/"+String(repeating:"a",count:64)+".pmtiles?token=secret","https://user:secret@archiverf.ru/api/maps/files/a.pmtiles"]{XCTAssertThrowsError(try package(["url":url]).validated())}
        XCTAssertThrowsError(try package(["bounds":[37,66,28,60]]).validated())
        XCTAssertThrowsError(try package(["bundledResource":"../private"] ).validated())
    }
    func testResumedRangesAreContiguousAndLastRangeExact()throws{
        let total:Int64=5_000_001;let a=try MapDownloadPolicy.range(offset:0,total:total),b=try MapDownloadPolicy.range(offset:a.upperBound+1,total:total),c=try MapDownloadPolicy.range(offset:b.upperBound+1,total:total)
        XCTAssertEqual(a.count,2*1024*1024);XCTAssertEqual(b.lowerBound,a.upperBound+1);XCTAssertEqual(c.upperBound,total-1)
        XCTAssertNoThrow(try MapDownloadPolicy.validateResponse(status:206,contentRange:"bytes \(c.lowerBound)-\(c.upperBound)/\(total)",bytes:Int64(c.count),range:c,total:total))
        XCTAssertThrowsError(try MapDownloadPolicy.validateResponse(status:200,contentRange:nil,bytes:total,range:c,total:total))
        XCTAssertThrowsError(try MapDownloadPolicy.validateResponse(status:206,contentRange:"bytes \(c.lowerBound)-\(c.upperBound)/\(total)",bytes:Int64(c.count)-1,range:c,total:total))
    }
}
