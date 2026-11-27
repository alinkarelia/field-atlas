import XCTest
import UIKit
import FieldCore
@testable import FieldAtlas

final class MemorialOCRTests:XCTestCase {
    @MainActor func testVisionReadsSeveralCyrillicNamesAndPreservesSourceBoxes()async throws{
        // This is a generated test inscription, not an original or a LiDAR result.
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let image=UIGraphicsImageRenderer(size:CGSize(width:1800,height:700),format:format).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:1800,height:700))
            let rows=["ИВАНОВ ИВАН ИВАНОВИЧ 1910–1942","ПЕТРОВ ПЕТР ПЕТРОВИЧ 1909–1943","СИДОРОВ АЛЕКСЕЙ ИВАНОВИЧ 1912–1941"]
            for (i,text) in rows.enumerated(){(text as NSString).draw(at:CGPoint(x:60,y:80+i*180),withAttributes:[.font:UIFont.systemFont(ofSize:52),.foregroundColor:UIColor.black])}
        }
        let lines=try await LocalOCR.lines(try XCTUnwrap(image.cgImage))
        let text=lines.map(\.text).joined(separator:" ");XCTAssertTrue(text.contains("ИВАНОВ"));XCTAssertTrue(text.contains("ПЕТРОВ"));XCTAssertTrue(text.contains("СИДОРОВ"))
        let sourceID=UUID().uuidString
        let names=lines.compactMap{MemorialNameParser.suggestion(NameReadingEvidence(photoID:sourceID,sha256:String(repeating:"b",count:64),text:$0.text,confidence:$0.confidence,box:$0.box))}
        XCTAssertEqual(names.count,3);XCTAssertTrue(names.allSatisfy{$0.needsReview==true && $0.relation=="inscription" && $0.birth.isEmpty && $0.death.isEmpty})
        for name in names{let evidence=try XCTUnwrap(name.evidence?.first);XCTAssertEqual(evidence.photoID,sourceID);XCTAssertEqual(evidence.box.count,4);XCTAssertGreaterThan(evidence.box[2],0);XCTAssertGreaterThan(evidence.box[3],0)}
    }
}
