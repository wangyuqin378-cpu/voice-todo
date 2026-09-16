import XCTest
@testable import VoiceTodoCore

final class CompletionEvidenceTests: XCTestCase {
    private func apply(_ input: String, title: String = "交材料", evidence: String? = nil,
                       kind: ProposedAction.Kind = .complete) throws -> Workspace {
        let task = TodoItem(id: "task", title: title)
        let action = ProposedAction(kind: kind, taskID: kind == .complete ? task.id : nil,
                                    title: title, candidates: kind == .complete ? [task.id] : [],
                                    evidence: evidence ?? input)
        return try TaskReducer.apply(.init(actions: [action]), to: .init(tasks: kind == .complete ? [task] : []),
                                     inputID: UUID().uuidString, input: input).workspace
    }

    func testFutureStatementsCannotCompleteOrLogCompleted() {
        for text in ["明天完成材料", "明天把材料交了", "下周就已经完成了", "今晚交材料", "材料明早就交好了", "准备把材料交了", "我计划明天完成材料", "材料做完了再休息"] {
            for kind in [ProposedAction.Kind.complete, .logCompleted] {
                XCTAssertThrowsError(try apply(text, kind: kind), text)
            }
        }
    }

    func testCompletedPlanningAndPreparationAreValidTasks() throws {
        for (title, text) in [("写项目计划", "项目计划已经写好了"), ("面试准备", "面试准备做完了"),
                              ("写旅行计划", "旅行计划书已完成"), ("面试准备工作", "面试准备工作已经做好了")] {
            XCTAssertTrue(try apply(text, title: title).tasks[0].isCompleted, text)
            XCTAssertTrue(try apply(text, title: title, kind: .logCompleted).tasks[0].isCompleted, text)
        }
    }

    func testFutureDateInCompletedTaskNameIsAllowed() throws {
        XCTAssertTrue(try apply("明天的计划已经写好了", title: "写明天的计划").tasks[0].isCompleted)
        XCTAssertThrowsError(try apply("明天的计划我明天完成", title: "写明天的计划"))
    }

    func testQuestionPunctuationCannotComplete() {
        for text in ["材料交了？", "材料交好了?", "材料已完成？"] {
            XCTAssertThrowsError(try apply(text), text)
        }
    }

    func testTaskNameAndUnrelatedLeCharacterAreNotCompletion() {
        for text in ["完成报销", "了解交材料的流程", "为了交材料"] {
            XCTAssertThrowsError(try apply(text), text)
        }
    }

    func testQuestionOrFutureInAnotherClauseDoesNotBlockCompletion() throws {
        for text in ["材料交好了，明天再买牛奶", "牛奶买了？材料交好了", "材料交好了，牛奶买了？"] {
            XCTAssertTrue(try apply(text, evidence: "材料交好了").tasks[0].isCompleted, text)
        }
    }

    func testCorrectionToFutureDoesNotCompleteEarlierStatement() {
        XCTAssertThrowsError(try apply("材料交好了，不对，明天才交", evidence: "材料交好了"))
    }
}
