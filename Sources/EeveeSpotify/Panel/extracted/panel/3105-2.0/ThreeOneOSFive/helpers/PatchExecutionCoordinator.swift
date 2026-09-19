import Foundation

enum PatchExecutionCoordinator {
    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
#if PANEL_HOST
        let result = try send(project: project, operation: .apply)
        guard result.success else { throw PatchPackageError.applyFailed }
        return hostReceipt(for: project.id)
#else
        return try DevicePatchService.apply(project: project)
#endif
    }

    static func inspectRestore(project: PatchProject) throws -> PatchRestoreInspection {
#if PANEL_HOST
        let result = try send(project: project, operation: .inspectRestore)
        guard result.success else { throw PatchPackageError.restoreFailed }
        return PatchRestoreInspection(changedTargets: result.changedTargets.map { PatchTargetChange(bundleID: $0.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "", relativePath: $0.split(separator: "/", maxSplits: 1).dropFirst().joined(separator: "/"), kind: .modified) })
#else
        return try DevicePatchService.inspectRestore(receipt: latestReceipt(projectID: project.id)!)
#endif
    }

    static func restore(project: PatchProject, allowChangedTargets: Bool = false) throws {
#if PANEL_HOST
        let result = try send(project: project, operation: .restore)
        guard result.success else { throw PatchPackageError.restoreFailed }
#else
        guard let receipt = DevicePatchService.latestReceipt(projectID: project.id) else { throw PatchPackageError.restoreFailed }
        try DevicePatchService.restore(receipt: receipt, allowChangedTargets: allowChangedTargets)
#endif
    }

    static func resetToAppliedState(receipt: PatchTransactionReceipt, project: PatchProject) throws {
#if PANEL_HOST
        let result = try send(project: project, operation: .resetToAppliedState)
        guard result.success else { throw PatchPackageError.resetFailed }
#else
        try DevicePatchService.resetToAppliedState(receipt: receipt, project: project)
#endif
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
#if PANEL_HOST
        guard UserDefaults.standard.bool(forKey: activeKey(projectID)) else { return nil }
        return hostReceipt(for: projectID)
#else
        return DevicePatchService.latestReceipt(projectID: projectID)
#endif
    }

#if PANEL_HOST
    private static func send(project: PatchProject, operation: Panel3105Bridge.Operation) throws -> Panel3105Bridge.Response {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let projectData = try encoder.encode(project)
        guard let targetBundleID = project.allBundleIdentifiers.first else { throw PatchPackageError.invalidBundleIdentifier }
        let semaphore = DispatchSemaphore(value: 0)
        var response: Panel3105Bridge.Response?
        Panel3105Bridge.shared.send(projectData: projectData, bundleID: targetBundleID, operation: operation) { result in
            response = result
            if result.success && operation == .apply { UserDefaults.standard.set(true, forKey: activeKey(project.id)) }
            if result.success && operation == .restore { UserDefaults.standard.set(false, forKey: activeKey(project.id)) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 185) == .success, let response else { throw PatchPackageError.applyFailed }
        return response
    }
    private static func activeKey(_ projectID: UUID) -> String { "Panel3105Bridge.active." + projectID.uuidString }
    private static func hostReceipt(for projectID: UUID) -> PatchTransactionReceipt { PatchTransactionReceipt(id: projectID, projectID: projectID, journalURL: URL(fileURLWithPath: "/dev/null")) }
#endif
}
