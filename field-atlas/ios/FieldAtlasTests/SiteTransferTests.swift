import XCTest
@testable import FieldAtlas

final class SiteTransferTests: XCTestCase {
    func testUploadRejectsWrongFileNegativeAndStalledCursor() throws {
        let id = UUID().uuidString
        XCTAssertThrowsError(try SiteAssetProgress(id:id,byteCount:10,uploadedBytes:-1,verified:false).validate(id:id,size:10))
        XCTAssertThrowsError(try SiteAssetProgress(id:id,byteCount:10,uploadedBytes:0,verified:false).validate(id:id,size:10,offset:5))
        XCTAssertThrowsError(try SiteAssetProgress(id:UUID().uuidString,byteCount:10,uploadedBytes:10,verified:true).validate(id:id,size:10))
        XCTAssertThrowsError(try SiteAssetProgress(id:id,byteCount:10,uploadedBytes:5,verified:true).validate(id:id,size:10))
        XCTAssertNoThrow(try SiteAssetProgress(id:id.lowercased(),byteCount:10,uploadedBytes:10,verified:true).validate(id:id,size:10,offset:10))
    }
    func testSandboxCannotAcknowledgeWrongOrPartialOriginal() throws {
        let asset = AssetEntry(id:UUID().uuidString,projectId:UUID().uuidString,filename:"file.json",mime:"application/json",sha256:String(repeating:"a",count:64),size:12)
        XCTAssertThrowsError(try UploadState(id:asset.id,size:12,offset:0,complete:1).validate(asset))
        XCTAssertThrowsError(try UploadState(id:asset.id,size:12,offset:3,complete:0).validate(asset,expectedOffset:6))
        XCTAssertNoThrow(try UploadState(id:asset.id,size:12,offset:12,complete:1).validate(asset,expectedOffset:12))
    }
    func testDestinationLedgersAreSeparateAndSurviveRelaunch() throws {
        var first = SiteTransferLedger(ownerID:"fixture-user",taskID:"fixture-task",title:"Field test")
        first.complete=[UUID().uuidString]
        let second = SiteTransferLedger(ownerID:"fixture-user",taskID:"another-task",title:"Field test")
        XCTAssertNotEqual(first.projectID,second.projectID)
        let restored = try JSONDecoder().decode(SiteTransferLedger.self,from:JSONEncoder().encode(first))
        XCTAssertEqual(restored.complete,first.complete)
        XCTAssertEqual(restored.projectID,first.projectID)
    }
}
