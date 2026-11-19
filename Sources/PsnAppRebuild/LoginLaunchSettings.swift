import ServiceManagement

enum LoginLaunchSettings {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws -> SMAppService.Status {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
        return service.status
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    // Called only for relocation of an existing enabled login item. Using
    // SMAppService here registers the signed bundle at its new location.
    static func rebindAfterInstallation() throws -> SMAppService.Status {
        let service = SMAppService.mainApp
        if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
        try service.register()
        return service.status
    }
}
