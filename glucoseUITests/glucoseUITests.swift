import XCTest

final class glucoseUITests: XCTestCase {

    @MainActor
    func testQueryFlowShowsTimeline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--reset-workout-cache"]
        app.launch()

        let queryButton = app.buttons["조회"]
        XCTAssertTrue(queryButton.waitForExistence(timeout: 5))
        queryButton.tap()
        sleep(3)

        attachScreen(name: "after-tap-query")

        // HealthKit 권한 시트 처리 (앱 접근성 계층에 포함되어 나타난다)
        let turnOnAll = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["Turn On All", "모두 켜기"])).firstMatch
        if turnOnAll.waitForExistence(timeout: 8) {
            turnOnAll.tap()
            let allow = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Allow", "허용"])).firstMatch
            if allow.waitForExistence(timeout: 3) {
                allow.tap()
            }
        }
        sleep(2)
        // iPad 시뮬레이터에서 뜨는 iCloud 건강 동기화 안내는 닫는다.
        let notNow = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Not Now", "나중에"])).firstMatch
        if notNow.waitForExistence(timeout: 2) {
            notNow.tap()
        }
        attachScreen(name: "after-permission")

        // 타임라인 화면 확인
        let workoutButton = app.buttons["운동 조회하기"]
        let timelineShown = workoutButton.waitForExistence(timeout: 10)
        attachScreen(name: "timeline-day")
        XCTAssertTrue(timelineShown, "타임라인 화면이 나타나야 합니다")

        // 좌우 스와이프로 이전 기간 이동 (차트 위에서도 페이지 전환이 되어야 한다)
        app.swipeRight()
        sleep(1)
        let yesterdayFormatter = DateFormatter()
        yesterdayFormatter.locale = Locale(identifier: "ko_KR")
        yesterdayFormatter.dateFormat = "M월 d일"
        let yesterday = yesterdayFormatter.string(from: Date().addingTimeInterval(-86400))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", yesterday))
                .firstMatch.waitForExistence(timeout: 5),
            "스와이프로 전날 페이지로 이동해야 합니다")
        attachScreen(name: "timeline-previous-day")

        // 운동 조회하기
        if workoutButton.exists && workoutButton.isHittable {
            workoutButton.tap()
            sleep(2)
        }
        XCTAssertTrue(
            app.staticTexts["계단 오르기"].waitForExistence(timeout: 5),
            "계단 오르기 운동 종류가 이름으로 표시되어야 합니다")
        attachScreen(name: "workouts")

        // 운동을 고르면 차트가 그 구간으로 확대되고 돋보기 버튼이 나타난다
        let zoomInButton = app.buttons["zoomIn"]
        XCTAssertFalse(zoomInButton.exists, "선택이 없을 때는 돋보기 버튼이 없어야 합니다")
        app.staticTexts["계단 오르기"].tap()
        XCTAssertTrue(zoomInButton.waitForExistence(timeout: 3), "운동을 고르면 돋보기 버튼이 보여야 합니다")
        attachScreen(name: "workout-focused")
        zoomInButton.tap()
        sleep(1)
        attachScreen(name: "workout-zoom-in")
        app.buttons["zoomOut"].tap()
        app.buttons["zoomOut"].tap()
        sleep(1)
        attachScreen(name: "workout-zoom-out")
        app.staticTexts["계단 오르기"].tap()  // 다시 누르면 선택 해제
        sleep(1)
        XCTAssertFalse(zoomInButton.exists, "선택을 풀면 돋보기 버튼이 사라져야 합니다")

        // 조회 후에는 다시 조회 버튼으로 바뀌어야 한다
        let reloadButton = app.buttons["다시 조회"]
        XCTAssertTrue(reloadButton.waitForExistence(timeout: 3), "조회 후 다시 조회 버튼이 보여야 합니다")
        reloadButton.tap()
        XCTAssertTrue(
            app.staticTexts["계단 오르기"].waitForExistence(timeout: 5),
            "다시 조회 후에도 운동 기록이 보여야 합니다")

        // 아래로 당겨 새로고침
        app.scrollViews.firstMatch.swipeDown()
        sleep(2)
        XCTAssertTrue(
            app.staticTexts["계단 오르기"].waitForExistence(timeout: 5),
            "새로고침 후에도 운동 기록이 보여야 합니다")
        attachScreen(name: "after-refresh")

        // 캐시 확인: 다른 기간에 갔다가 돌아와도 조회한 운동이 유지되어야 한다
        app.swipeLeft()
        sleep(1)
        app.swipeRight()
        sleep(2)
        XCTAssertTrue(
            app.staticTexts["운동 1건"].waitForExistence(timeout: 5),
            "조회했던 운동 기록이 캐시로 유지되어야 합니다")
        attachScreen(name: "cached-workouts")

        // 차트 탭으로 값 선택
        func zoomTargetForSelection() -> XCUIElement {
            let chart = app.otherElements["glucoseChart"].firstMatch
            return chart.exists ? chart : app.scrollViews.firstMatch
        }
        // Swift Charts의 annotation은 접근성 트리에 노출되지 않아
        // 단언 대신 스크린샷으로 확인한다.
        zoomTargetForSelection().tap()
        sleep(1)
        attachScreen(name: "selection")
        zoomTargetForSelection().tap()  // 같은 지점 다시 탭하면 해제
        sleep(1)

        // 핀치 줌 인/아웃
        func zoomTarget() -> XCUIElement {
            let chart = app.otherElements["glucoseChart"].firstMatch
            return chart.exists ? chart : app.scrollViews.firstMatch
        }
        zoomTarget().pinch(withScale: 4.0, velocity: 2.0)
        sleep(1)
        attachScreen(name: "zoomed-in")
        zoomTarget().doubleTap()
        sleep(1)
        attachScreen(name: "zoom-reset")

        // 주 단위 화면 확인
        let weekSegment = app.buttons["주"]
        if weekSegment.waitForExistence(timeout: 3) {
            weekSegment.tap()
            sleep(2)
            attachScreen(name: "timeline-week")
        }

        // 앱을 다시 켜도 조회했던 운동 기록을 기억하고 있어야 한다
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(queryButton.waitForExistence(timeout: 5))
        queryButton.tap()
        XCTAssertTrue(app.buttons["주"].waitForExistence(timeout: 10), "타임라인 화면이 나타나야 합니다")
        app.swipeRight()
        sleep(2)
        XCTAssertTrue(
            app.buttons["다시 조회"].waitForExistence(timeout: 5),
            "재실행 후에도 버튼을 누르지 않고 운동 기록이 보여야 합니다")
        attachScreen(name: "relaunch-remembered")
    }

    @MainActor
    private func attachScreen(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
