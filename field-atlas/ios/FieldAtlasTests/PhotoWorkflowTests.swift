import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import FieldCore
@testable import FieldAtlas

@MainActor final class PhotoWorkflowTests:XCTestCase {
    private func image()->UIImage{UIGraphicsImageRenderer(size:CGSize(width:128,height:96)).image{c in UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:128,height:96));("Тест 18?4" as NSString).draw(at:CGPoint(x:10,y:30),withAttributes:[.foregroundColor:UIColor.black,.font:UIFont.systemFont(ofSize:16)])}}
    func testMultipleOriginalsRemainAttachedAfterRestart()throws {
        setenv("FIELD_ATLAS_TEST_SESSION",UUID().uuidString,1);defer{unsetenv("FIELD_ATLAS_TEST_SESSION")}
        let store=AppStore(),project=FieldProject(title:"Fixture photos",type:.cemetery);try store.addProject(project)
        let jpeg=try XCTUnwrap(image().jpegData(compressionQuality:0.95)),png=try XCTUnwrap(image().pngData())
        var record=Observation(projectId:project.id,kind:"grave")
        record=try store.attachPhoto(jpeg,to:record,role:"inscription");record=try store.attachPhoto(png,to:record,role:"inscription")
        let restored=AppStore(),saved=try XCTUnwrap(restored.records(project.id).first)
        XCTAssertEqual(saved.photos.count,2)
        for (attachment,original) in zip(saved.photos,[jpeg,png]){let url=try XCTUnwrap(restored.assetURL(attachment.id));XCTAssertEqual(try Data(contentsOf:url),original);XCTAssertEqual(attachment.sha256,SiteTransfer.digest(original))}
        XCTAssertTrue(store.state.assets.first!.filename.hasSuffix(".jpg"))
        XCTAssertThrowsError(try store.attachPhoto(Data("not an image".utf8),to:record,role:"overview"))
        XCTAssertEqual(store.records(project.id).first?.photos.count,2)
    }
    func testAssistantPreservesSmallJPEGAndRejectsMismatchedHash()throws {
        let jpeg=try XCTUnwrap(image().jpegData(compressionQuality:0.95)),hash=SiteTransfer.digest(jpeg)
        let prepared=try AssistantImage.prepare(jpeg,hash:hash)
        XCTAssertEqual(prepared.data,jpeg);XCTAssertFalse(prepared.transformed)
        XCTAssertThrowsError(try AssistantImage.prepare(jpeg,hash:String(repeating:"0",count:64)))
    }
    func testAssistantConvertsHEICWithoutChangingOriginalIdentity()throws {
        let data=NSMutableData();let destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.heic.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(image().cgImage),nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original=data as Data,hash=SiteTransfer.digest(original),prepared=try AssistantImage.prepare(original,hash:hash)
        XCTAssertTrue(prepared.transformed);XCTAssertEqual(prepared.originalHash,hash);XCTAssertEqual(prepared.sourceHash,SiteTransfer.digest(prepared.data));XCTAssertLessThanOrEqual(prepared.data.count,6*1024*1024)
        XCTAssertEqual(prepared.data.prefix(2),Data([0xff,0xd8]));XCTAssertEqual(SiteTransfer.digest(original),hash)
    }
}
