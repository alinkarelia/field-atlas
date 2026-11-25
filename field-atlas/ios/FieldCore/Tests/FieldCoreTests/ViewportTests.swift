import XCTest
@testable import FieldCore

final class ViewportTests: XCTestCase {
    func testFitKeepsLargeSurveyVisible() {
        var view=PlanViewport()
        let corners=[[1200.0,-500.0],[3600.0,1700.0]]
        view.fit(corners,width:300,height:400)
        for point in corners {
            let pixel=view.screen(point,width:400,height:700)
            XCTAssertTrue((50...350).contains(pixel[0]))
            XCTAssertTrue((150...550).contains(pixel[1]))
        }
    }
    func testPickingAfterPanAndZoomKeepsCoordinates() {
        var view=PlanViewport(); view.pan(x:147,y:-81); view.zoom(2.7)
        let original=[-21.8,57.4]
        let screen=view.screen(original,width:852,height:393)
        let result=view.world(x:screen[0],y:screen[1],width:852,height:393)
        XCTAssertEqual(result[0],original[0],accuracy:0.000001)
        XCTAssertEqual(result[1],original[1],accuracy:0.000001)
    }
    func testInvalidCoordinatesAndGesturesDoNotCorruptView() {
        var view=PlanViewport(); let original=view
        view.fit([[.nan,3],[1]],width:390,height:600)
        view.zoom(.infinity); view.zoom(-1); view.pan(x:.nan,y:0)
        XCTAssertEqual(view,original)
        view.zoom(1e-9); XCTAssertEqual(view.scale,0.01)
        view.zoom(1e9); XCTAssertEqual(view.scale,200)
    }
}
