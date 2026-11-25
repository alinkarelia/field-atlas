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
        create("interior","Проверка оборудования");tap(app.buttons["workspace-scan"]);let start=app.buttons["capture-start"];XCTAssertTrue(start.waitForExistence(timeout:10));XCTAssertFalse(start.isEnabled);capture("unsupported-lidar");tap(app.buttons["Закрыть"]);XCTAssertTrue(app.buttons["workspace-add"].waitForExistence(timeout:5))
    }
    func testFieldAssistantNeedsAccountAndReturnsToWork(){
        create("land","Помощник в поле");tap(app.buttons["workspace-tools"]);tap(app.buttons["Помощник x0"])
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
}
