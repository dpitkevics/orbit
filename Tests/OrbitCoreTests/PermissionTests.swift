import Foundation
import Testing
@testable import OrbitCore

@Suite("Permissions")
struct PermissionTests {
    @Test("PermissionMode ordering")
    func permissionModeOrdering() {
        #expect(PermissionMode.readOnly < .workspaceWrite)
        #expect(PermissionMode.workspaceWrite < .dangerFullAccess)
        #expect(PermissionMode.readOnly < .dangerFullAccess)
    }

    @Test("PermissionMode Codable roundtrip")
    func permissionModeCodable() throws {
        let data = try JSONEncoder().encode(PermissionMode.workspaceWrite)
        let decoded = try JSONDecoder().decode(PermissionMode.self, from: data)
        #expect(decoded == .workspaceWrite)
    }

    @Test("PermissionRule exact match")
    func permissionRuleExact() {
        let rule = PermissionRule(toolPattern: "bash")
        #expect(rule.matches("bash") == true)
        #expect(rule.matches("bash_tool") == false)
        #expect(rule.matches("file_read") == false)
    }

    @Test("PermissionRule prefix wildcard")
    func permissionRuleWildcard() {
        let rule = PermissionRule(toolPattern: "mcp__*")
        #expect(rule.matches("mcp__server__tool") == true)
        #expect(rule.matches("mcp__other") == true)
        #expect(rule.matches("bash") == false)
    }

    @Test("PermissionPolicy allows when mode sufficient")
    func policyAllowsByMode() {
        let policy = PermissionPolicy(activeMode: .workspaceWrite)
        let result = policy.authorize(toolName: "file_read", requiredMode: .readOnly)
        #expect(result.isAllowed)
    }

    @Test("PermissionPolicy denies when mode insufficient")
    func policyDeniesInsufficientMode() {
        let policy = PermissionPolicy(activeMode: .readOnly)
        let result = policy.authorize(toolName: "bash", requiredMode: .dangerFullAccess)
        #expect(!result.isAllowed)
    }

    @Test("PermissionPolicy deny rules override mode")
    func policyDenyRulesOverride() {
        let policy = PermissionPolicy(
            activeMode: .dangerFullAccess,
            denyRules: [PermissionRule(toolPattern: "bash")]
        )
        let result = policy.authorize(toolName: "bash", requiredMode: .dangerFullAccess)
        #expect(!result.isAllowed)
    }

    @Test("PermissionPolicy allow rules override mode")
    func policyAllowRulesOverride() {
        let policy = PermissionPolicy(
            activeMode: .readOnly,
            allowRules: [PermissionRule(toolPattern: "bash")]
        )
        let result = policy.authorize(toolName: "bash", requiredMode: .dangerFullAccess)
        #expect(result.isAllowed)
    }

    @Test("PermissionPolicy deny rules take priority over allow rules")
    func policyDenyTakesPriority() {
        let policy = PermissionPolicy(
            activeMode: .dangerFullAccess,
            allowRules: [PermissionRule(toolPattern: "bash")],
            denyRules: [PermissionRule(toolPattern: "bash")]
        )
        let result = policy.authorize(toolName: "bash", requiredMode: .dangerFullAccess)
        #expect(!result.isAllowed)
    }

    @Test("PermissionEnforcer workspace boundary check allows inside")
    func enforcerAllowsInsideWorkspace() {
        let enforcer = PermissionEnforcer(
            policy: PermissionPolicy(activeMode: .workspaceWrite),
            workspaceRoot: "/Users/test/project"
        )
        let result = enforcer.checkFileWrite(path: "/Users/test/project/src/file.swift")
        #expect(result.isAllowed)
    }

    @Test("PermissionEnforcer workspace boundary check denies outside")
    func enforcerDeniesOutsideWorkspace() {
        let enforcer = PermissionEnforcer(
            policy: PermissionPolicy(activeMode: .workspaceWrite),
            workspaceRoot: "/Users/test/project"
        )
        let result = enforcer.checkFileWrite(path: "/etc/passwd")
        #expect(!result.isAllowed)
    }

    @Test("PermissionEnforcer dangerFullAccess allows outside workspace")
    func enforcerFullAccessAllowsAnywhere() {
        let enforcer = PermissionEnforcer(
            policy: PermissionPolicy(activeMode: .dangerFullAccess),
            workspaceRoot: "/Users/test/project"
        )
        let result = enforcer.checkFileWrite(path: "/etc/hosts")
        #expect(result.isAllowed)
    }

    @Test("PermissionEnforcer readOnly denies all writes")
    func enforcerReadOnlyDeniesWrites() {
        let enforcer = PermissionEnforcer(
            policy: PermissionPolicy(activeMode: .readOnly),
            workspaceRoot: "/Users/test/project"
        )
        let result = enforcer.checkFileWrite(path: "/Users/test/project/file.txt")
        #expect(!result.isAllowed)
    }

    @Test("PermissionOutcome equality")
    func permissionOutcomeEquality() {
        #expect(PermissionOutcome.allow == PermissionOutcome.allow)
        #expect(PermissionOutcome.deny(reason: "x") == PermissionOutcome.deny(reason: "x"))
        #expect(PermissionOutcome.allow != PermissionOutcome.deny(reason: "x"))
    }
}
