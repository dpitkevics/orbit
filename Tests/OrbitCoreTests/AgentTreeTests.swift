import Foundation
import Testing
@testable import OrbitCore

@Suite("Agent Node")
struct AgentNodeTests {
    @Test("AgentNode initializes with correct defaults")
    func nodeInit() {
        let node = AgentNode(task: "analyze data", project: "test")
        #expect(node.parentID == nil)
        #expect(node.depth == 0)
        #expect(node.maxDepth == 5)
        #expect(node.status == .pending)
        #expect(node.children.isEmpty)
        #expect(node.trace.isEmpty)
        #expect(node.usage == .zero)
        #expect(node.result == nil)
        #expect(node.endTime == nil)
    }

    @Test("AgentNode spawn creates child with correct parent link")
    func nodeSpawn() throws {
        let parent = AgentNode(task: "parent task", project: "test")
        let child = try parent.spawn(task: "child task")

        #expect(child.parentID == parent.id)
        #expect(child.depth == 1)
        #expect(child.project == "test")
        #expect(parent.children.count == 1)
        #expect(parent.children[0].id == child.id)
    }

    @Test("AgentNode spawn respects depth limit")
    func nodeSpawnDepthLimit() throws {
        let root = AgentNode(task: "root", project: "test", maxDepth: 2)
        let child = try root.spawn(task: "child")
        let grandchild = try child.spawn(task: "grandchild")

        #expect(grandchild.depth == 2)

        #expect(throws: AgentError.self) {
            try grandchild.spawn(task: "too deep")
        }
    }

    @Test("AgentNode status transitions")
    func nodeStatusTransitions() {
        let node = AgentNode(task: "test", project: "test")
        #expect(node.status == .pending)

        node.markRunning()
        #expect(node.status == .running)

        node.markCompleted(output: "done", usage: TokenUsage(inputTokens: 10, outputTokens: 5))
        #expect(node.status == .completed)
        #expect(node.result?.output == "done")
        #expect(node.result?.success == true)
        #expect(node.usage.inputTokens == 10)
        #expect(node.endTime != nil)
    }

    @Test("AgentNode failed status")
    func nodeFailedStatus() {
        let node = AgentNode(task: "test", project: "test")
        node.markRunning()
        node.markFailed(error: "something went wrong")

        #expect(node.status == .failed)
        #expect(node.result?.success == false)
        #expect(node.result?.output.contains("something went wrong") == true)
        #expect(node.endTime != nil)
    }

    @Test("AgentNode cancelled status")
    func nodeCancelledStatus() {
        let node = AgentNode(task: "test", project: "test")
        node.markRunning()
        node.markCancelled()

        #expect(node.status == .cancelled)
        #expect(node.endTime != nil)
    }

    @Test("AgentNode records trace entries")
    func nodeTrace() {
        let node = AgentNode(task: "test", project: "test")
        node.recordTrace(.toolCall, content: "Calling bash")
        node.recordTrace(.toolResult, content: "Output: hello")

        #expect(node.trace.count == 2)
        #expect(node.trace[0].type == .toolCall)
        #expect(node.trace[1].type == .toolResult)
    }

    @Test("AgentNode child inherits maxDepth")
    func nodeChildInheritsMaxDepth() throws {
        let parent = AgentNode(task: "root", project: "test", maxDepth: 3)
        let child = try parent.spawn(task: "child")
        #expect(child.maxDepth == 3)
    }

    @Test("AgentNode duration calculation")
    func nodeDuration() {
        let node = AgentNode(task: "test", project: "test")
        node.markRunning()
        // Immediately complete — duration should be very small but >= 0
        node.markCompleted(output: "done", usage: .zero)
        #expect(node.duration >= 0)
    }

    @Test("MemoryAccessLevel values")
    func memoryAccessLevels() {
        let levels: [MemoryAccessLevel] = [.full, .readOnly, .none]
        #expect(levels.count == 3)
    }
}

@Suite("Agent Tree")
struct AgentTreeTests {
    @Test("AgentTree tracks root node")
    func treeRoot() async {
        let root = AgentNode(task: "root", project: "test")
        let tree = AgentTree(root: root)

        let r = await tree.root
        #expect(r.id == root.id)
    }

    @Test("AgentTree registers spawned nodes")
    func treeRegistersNodes() async throws {
        let root = AgentNode(task: "root", project: "test")
        let tree = AgentTree(root: root)

        let child = try root.spawn(task: "child")
        await tree.register(child)

        let allNodes = await tree.allNodeCount
        #expect(allNodes == 2) // root + child
    }

    @Test("AgentTree totalCost aggregates across all nodes")
    func treeTotalCost() async throws {
        let root = AgentNode(task: "root", project: "test")
        root.markRunning()
        root.markCompleted(output: "done", usage: TokenUsage(inputTokens: 100, outputTokens: 50))

        let child = try root.spawn(task: "child")
        child.markRunning()
        child.markCompleted(output: "done", usage: TokenUsage(inputTokens: 200, outputTokens: 75))

        let tree = AgentTree(root: root)
        await tree.register(child)

        let total = await tree.totalCost()
        #expect(total.inputTokens == 300)
        #expect(total.outputTokens == 125)
    }

    @Test("AgentTree failedNodes returns only failed")
    func treeFailedNodes() async throws {
        let root = AgentNode(task: "root", project: "test")
        root.markRunning()
        root.markCompleted(output: "ok", usage: .zero)

        let child = try root.spawn(task: "child")
        child.markRunning()
        child.markFailed(error: "oops")

        let tree = AgentTree(root: root)
        await tree.register(child)

        let failed = await tree.failedNodes()
        #expect(failed.count == 1)
        #expect(failed[0].id == child.id)
    }

    @Test("AgentTree nodesAtDepth filters correctly")
    func treeNodesAtDepth() async throws {
        let root = AgentNode(task: "root", project: "test")
        let child1 = try root.spawn(task: "child1")
        let child2 = try root.spawn(task: "child2")
        let grandchild = try child1.spawn(task: "grandchild")

        let tree = AgentTree(root: root)
        await tree.register(child1)
        await tree.register(child2)
        await tree.register(grandchild)

        let depth0 = await tree.nodesAtDepth(0)
        let depth1 = await tree.nodesAtDepth(1)
        let depth2 = await tree.nodesAtDepth(2)

        #expect(depth0.count == 1)
        #expect(depth1.count == 2)
        #expect(depth2.count == 1)
    }

    @Test("AgentTree totalDuration")
    func treeDuration() async {
        let root = AgentNode(task: "root", project: "test")
        root.markRunning()
        root.markCompleted(output: "ok", usage: .zero)

        let tree = AgentTree(root: root)
        let duration = await tree.totalDuration()
        #expect(duration >= 0)
    }
}
