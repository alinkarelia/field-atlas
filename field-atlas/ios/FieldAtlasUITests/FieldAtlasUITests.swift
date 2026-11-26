import XCTest

final class FieldAtlasUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        app=XCUIApplication()
        app.launchEnvironment["FIELD_ATLAS_TEST_SESSION"]=UUID().uuidString
        app.launchArguments=["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
    }
    override func tearDownWithError() throws { app.terminate();XCUIDevice.shared.orientation = .portrait }
    private func capture(_ name:String){let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)}
    private func awaitRotation(landscape:Bool){
        let ready=NSPredicate { _,_ in
            let frame=self.app.windows.firstMatch.frame
            return frame.width>0 && frame.height>0 && (frame.width>frame.height)==landscape
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:nil)],timeout:12),.completed)
        let action=app.buttons["wizard-next"]
        XCTAssertTrue(app.windows.firstMatch.frame.contains(action.frame),"The complete bottom action must remain inside the window")
    }
    private func tap(_ element:XCUIElement,file:StaticString=#filePath,line:UInt=#line){XCTAssertTrue(element.waitForExistence(timeout:12),file:file,line:line);XCTAssertTrue(element.isHittable,file:file,line:line);element.tap()}
    private func revealProject(_ element:XCUIElement){
        let scroll=app.scrollViews.firstMatch
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            scroll.swipeUp()
        }
    }
    private func create(_ kind:String,_ title:String){
        let kindButton=app.buttons["project-kind-"+kind];revealProject(kindButton);tap(kindButton);let field=app.textFields["project-title"];tap(field);field.typeText(title);tap(app.buttons["project-create"]);XCTAssertTrue(app.buttons["workspace-add"].waitForExistence(timeout:10))
    }
    func testFourProjectModesAndReturnNavigation(){
        for kind in ["interior","exterior","land","cemetery"]{
            create(kind,"Проверка "+kind);capture("workspace-"+kind);tap(app.buttons["workspace-add"]);XCTAssertTrue(app.textFields["observation-title"].waitForExistence(timeout:10));capture("card-"+kind);tap(app.buttons["Свернуть"]);tap(app.buttons["К проектам"])
        }
    }
    func testCardSurvivesAllStepsAndRelaunch(){
        create("cemetery","Сохранность карточки");tap(app.buttons["workspace-add"]);let title=app.textFields["observation-title"];tap(title);title.typeText("Плита 18?4")
        for _ in 0..<4{tap(app.buttons["wizard-next"])}
        capture("review-portrait");tap(app.buttons["wizard-next"]);XCTAssertTrue(app.buttons["workspace-objects"].waitForExistence(timeout:10));app.terminate();app.launch()
        let savedProject=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Сохранность карточки")).firstMatch;revealProject(savedProject);tap(savedProject);tap(app.buttons["workspace-objects"]);tap(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Плита 18?4")).firstMatch);XCTAssertEqual(app.textFields["observation-title"].value as? String,"Плита 18?4");capture("restored-card")
    }
    func testRotationPreservesEditableCardAndBottomAction(){
        create("land","Поворот экрана");tap(app.buttons["workspace-add"]);let title=app.textFields["observation-title"];tap(title);title.typeText("Длинное название участка")
        XCUIDevice.shared.orientation = .landscapeLeft
        awaitRotation(landscape:true)
        XCTAssertTrue(title.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(title.frame))
        XCTAssertLessThanOrEqual(title.frame.maxY,app.buttons["wizard-next"].frame.minY,"The edited text must remain above the bottom action")
        if app.keyboards.firstMatch.exists {XCTAssertLessThanOrEqual(title.frame.maxY,app.keyboards.firstMatch.frame.minY,"The keyboard must not cover the edited text")}
        XCTAssertTrue(app.buttons["wizard-next"].waitForExistence(timeout:5));XCTAssertTrue(app.buttons["wizard-next"].isHittable);XCTAssertEqual(title.value as? String,"Длинное название участка");capture("card-landscape");tap(app.buttons["wizard-next"])
        XCUIDevice.shared.orientation = .portrait;awaitRotation(landscape:false);XCTAssertTrue(app.buttons["wizard-next"].isHittable);capture("photos-portrait")
    }
    func testWebsiteAccountDoesNotBlockLocalWork(){
        tap(app.buttons["website-account"])
        XCTAssertTrue(app.buttons["website-sign-in"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["website-offline-work"].label.contains("без входа"))
        XCTAssertTrue(app.staticTexts["website-account-status"].exists)
        XCTAssertEqual(app.staticTexts["website-account-status"].label,"Вход нужен для работы с сайтом. Съёмка доступна без интернета.")
        capture("website-account")
        tap(app.buttons["Готово"])
        create("land","Без входа в сайт")
        XCTAssertTrue(app.buttons["workspace-add"].isHittable)
    }
    func testMapScaleControlsAndFit(){
        create("land","Масштаб участка")
        let scale=app.staticTexts["map-scale"];XCTAssertTrue(scale.waitForExistence(timeout:5))
        let original=scale.label;tap(app.buttons["map-zoom-in"]);XCTAssertNotEqual(scale.label,original)
        tap(app.buttons["map-fit"]);XCTAssertEqual(scale.label,original)
        tap(app.buttons["map-zoom-out"]);XCTAssertNotEqual(scale.label,original);capture("map-scale")
    }
    func testSimulatorDoesNotPretendToHaveLiDAR(){
        create("interior","Проверка оборудования");tap(app.buttons["workspace-scan"]);XCTAssertTrue(app.staticTexts["capture-unavailable"].waitForExistence(timeout:10));XCTAssertFalse(app.buttons["capture-start"].exists);capture("unsupported-lidar");tap(app.buttons["capture-close"]);XCTAssertTrue(app.buttons["workspace-add"].waitForExistence(timeout:5))
    }
    func testFieldAssistantNeedsAccountAndReturnsToWork(){
        create("land","Помощник в поле");tap(app.buttons["workspace-assistant"])
        XCTAssertTrue(app.navigationBars["Помощник x0"].waitForExistence(timeout:10));capture("field-assistant-account")
        let send=app.buttons["field-assistant-send"]
        for _ in 0..<4{if send.isHittable{break};app.swipeUp()}
        XCTAssertTrue(send.exists);XCTAssertFalse(send.isEnabled)
        tap(app.buttons["К работе"]);XCTAssertTrue(app.buttons["workspace-add"].waitForExistence(timeout:5))
    }
    func testTimedFieldTaskPausesAndSavesReport(){
        create("land","Замер задания");tap(app.buttons["workspace-missions"])
        let title=app.textFields["mission-title"];tap(title);title.typeText("Контроль времени")
        tap(app.buttons["mission-mode-timed"])
        XCTAssertTrue(app.buttons["mission-mode-timed"].isSelected)
        let start=app.buttons["mission-start"];if !start.isHittable{app.swipeUp()};tap(start)
        let pause=app.buttons["mission-pause"]
        for _ in 0..<4{if pause.isHittable{break};app.swipeDown()}
        tap(pause);XCTAssertEqual(pause.label,"Продолжить");capture("field-task-paused")
        tap(app.buttons["mission-finish"]);tap(app.buttons["Завершить и сохранить"])
        // SwiftUI exposes LabeledContent as a combined label in the accessibility tree.
        XCTAssertTrue(app.staticTexts["Состояние, Завершено"].firstMatch.waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Задание завершено. GPX, журнал и карточка результата сохранены."].exists)
        capture("field-task-completed")
        tap(app.buttons["К работе"]);tap(app.buttons["workspace-objects"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Контроль времени")).firstMatch.waitForExistence(timeout:5))
    }
    func testCameraToolsLeaveCenterClearInPortraitAndLandscape(){
        app.terminate();app.launchEnvironment["FIELD_ATLAS_UI_HARNESS"]="camera";app.launch()
        let ids=["capture-close","capture-torch","capture-coverage","capture-help","capture-pause","room-measure","room-photo","room-more","capture-assistant"]
        for orientation in [UIDeviceOrientation.portrait,.landscapeLeft] {
            XCUIDevice.shared.orientation=orientation
            let landscape=orientation == .landscapeLeft
            let ready=NSPredicate{_,_ in let r=self.app.windows.firstMatch.frame;return r.width>0 && (r.width>r.height)==landscape}
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:nil)],timeout:12),.completed)
            let window=app.windows.firstMatch.frame
            let clear=CGRect(x:window.midX-window.width*0.25,y:window.minY+16,width:window.width*0.5,height:window.height-32)
            for id in ids{let button=app.buttons[id];XCTAssertTrue(button.waitForExistence(timeout:5));XCTAssertTrue(button.isHittable);XCTAssertTrue(window.contains(button.frame));XCTAssertGreaterThanOrEqual(button.frame.width,44);XCTAssertGreaterThanOrEqual(button.frame.height,44);XCTAssertFalse(clear.intersects(button.frame),id)}
            capture(landscape ? "camera-layout-fixture-landscape":"camera-layout-fixture-portrait")
        }
        tap(app.buttons["capture-torch"]);XCTAssertEqual(app.buttons["capture-torch"].value as? String,"Включено")
        tap(app.buttons["capture-help"]);XCTAssertTrue(app.staticTexts["Это проверка расположения кнопок без камеры и LiDAR."].waitForExistence(timeout:5));tap(app.buttons["К камере"])
        XCTAssertTrue(app.buttons["capture-torch"].isHittable)
    }
    func testCemeteryManualBoundaryRoadAndPathPersist(){
        create("cemetery","Карта кладбища")
        for kind in ["boundary","road","path"] {
            tap(app.buttons["workspace-"+kind]);tap(app.buttons["track-start-manual"])
            let map=app.otherElements["survey-map"].firstMatch
            let points=kind=="boundary" ? [CGVector(dx:0.3,dy:0.34),CGVector(dx:0.7,dy:0.34),CGVector(dx:0.7,dy:0.46),CGVector(dx:0.3,dy:0.46)] : [CGVector(dx:0.4,dy:0.35),CGVector(dx:0.6,dy:0.43)]
            for point in points{map.coordinate(withNormalizedOffset:point).tap()}
            XCTAssertEqual(app.staticTexts["track-count"].label,"\(points.count) точек")
            capture("manual-"+kind);tap(app.buttons["track-save"])
            XCTAssertTrue(app.buttons["workspace-add"].isEnabled)
        }
        tap(app.buttons["workspace-objects"])
        for name in ["Граница 1","Дорога 1","Тропинка 1"]{XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout:5))}
        capture("cemetery-saved-paths")
    }
    func testCemeteryMarkersOpenTheirOwnCards(){
        create("cemetery","Метки кладбища")
        for kind in ["entrance","tree","dump","container"] {
            tap(app.buttons["workspace-tools"])
            let feature=app.buttons["marker-"+kind]
            for _ in 0..<6{if feature.isHittable{break};app.swipeUp()}
            tap(feature)
            app.otherElements["survey-map"].firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.38)).tap()
            XCTAssertTrue(app.textFields["observation-title"].waitForExistence(timeout:8))
            XCTAssertFalse((app.textFields["observation-title"].value as? String ?? "").isEmpty)
            tap(app.buttons["Свернуть"])
        }
        tap(app.buttons["workspace-objects"]);capture("cemetery-markers")
        for title in ["Вход","Дерево","Свалка","Мусорный контейнер"]{XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@",title)).firstMatch.exists)}
    }
    func testGravePhotoChecklistAndCameraCancelPreserveCard(){
        create("cemetery","Фото захоронения");tap(app.buttons["workspace-add"]);tap(app.buttons["wizard-next"])
        for role in ["overview","inscription","portrait"]{let row=app.buttons["photo-role-"+role];for _ in 0..<4{if row.isHittable{break};app.swipeUp()};XCTAssertTrue(row.isHittable)}
        let overview=app.buttons["photo-role-overview"];for _ in 0..<5{if overview.isHittable{break};app.swipeDown()};tap(overview)
        // The Simulator must report absence of a camera instead of fabricating a photograph.
        let alert=app.alerts["Фотография"];if alert.waitForExistence(timeout:8){tap(alert.buttons["Понятно"])}
        tap(app.buttons["photo-close"]);XCTAssertTrue(app.buttons["photo-role-overview"].waitForExistence(timeout:5));capture("grave-photo-checklist")
        tap(app.buttons["Свернуть"]);tap(app.buttons["workspace-objects"]);XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","0 фото")).firstMatch.exists)
    }
}
