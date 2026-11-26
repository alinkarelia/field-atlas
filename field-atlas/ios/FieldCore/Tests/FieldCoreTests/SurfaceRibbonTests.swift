import XCTest
@testable import FieldCore

final class SurfaceRibbonTests:XCTestCase {
    func testVisibleRibbonsHaveFiniteWidthAndDoubleSidedTriangleWinding(){
        let mesh=SurfaceHatching.ribbons(lines:[[[0,0],[2,0]]],width:0.012)
        XCTAssertEqual(mesh.vertices.count,4);XCTAssertEqual(mesh.indices,[0,1,2,2,1,3])
        XCTAssertEqual(abs(mesh.vertices[0][1]-mesh.vertices[1][1]),0.012,accuracy:1e-9)
        XCTAssertEqual(Set(mesh.indices),Set([0,1,2,3]))
    }
    func testInvalidOrDegenerateRibbonsAreExcluded(){
        XCTAssertTrue(SurfaceHatching.ribbons(lines:[[[0,0],[0,0]],[[Double.nan,0],[1,1]],[[0],[1,1]]],width:0.012).vertices.isEmpty)
        XCTAssertTrue(SurfaceHatching.ribbons(lines:[[[0,0],[1,1]]],width:.infinity).vertices.isEmpty)
    }
    func testHatchLeavesDoorInteriorEmpty(){
        let lines=SurfaceHatching.segments(outline:[[0,0],[4,0],[4,3],[0,3]],holes:[[[1,0],[2,0],[2,2],[1,2]]])
        XCTAssertFalse(lines.isEmpty)
        for line in lines{for t in [0.1,0.25,0.5,0.75,0.9]{let x=line[0][0]+(line[1][0]-line[0][0])*t,y=line[0][1]+(line[1][1]-line[0][1])*t;XCTAssertFalse(x>1.01 && x<1.99 && y>0.01 && y<1.99)}}
    }
}
