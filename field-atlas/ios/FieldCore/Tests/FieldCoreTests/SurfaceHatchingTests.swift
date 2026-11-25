import XCTest
@testable import FieldCore

final class SurfaceHatchingTests: XCTestCase {
    func testDoorRemainsEmpty() {
        let wall=[[0.0,0],[4,0],[4,3],[0,3]], door=[[1.0,0],[2,0],[2,2],[1,2]]
        let lines=SurfaceHatching.segments(outline:wall,holes:[door])
        XCTAssertGreaterThan(lines.count,20)
        for line in lines {
            for t in [0.1,0.5,0.9] {
                let x=line[0][0]+t*(line[1][0]-line[0][0]), y=line[0][1]+t*(line[1][1]-line[0][1])
                XCTAssertTrue(x>=0 && x<=4 && y>=0 && y<=3)
                XCTAssertFalse(x>1 && x<2 && y>0 && y<2)
            }
        }
    }
    func testSlopedWallDoesNotGetRectangularFill() {
        let lines=SurfaceHatching.segments(outline:[[0,0],[4,0],[4,2],[0,4]])
        XCTAssertFalse(lines.isEmpty)
        for line in lines { for p in line { XCTAssertLessThanOrEqual(p[1],4-p[0]/2+1e-8) } }
        XCTAssertTrue(SurfaceHatching.segments(outline:[[.nan,0],[1,0],[1,1]]).isEmpty)
    }
    func testPreviewRetainsOldSectorsAndBestConfidence() {
        var preview=SurfacePreview(limit:32)
        preview.add([[0,0,0,2]])
        preview.add((0..<300).map{[Double($0)/10+10,0,0,1]})
        XCTAssertLessThanOrEqual(preview.points.count,32)
        XCTAssertTrue(preview.points.contains{$0[0]==0 && $0[3]==2})
        preview.add([[0,0,0,1]])
        XCTAssertTrue(preview.points.contains{$0[0]==0 && $0[3]==2})
    }
}
