import FileCore
import HomeServicesConnection
import SwiftUI

struct FilesPiConnection: View {
    @Environment(AppModel.self) private var model
    private let marker = "piConnection.profile.v1"
    var body: some View {
        PiConnectionHost(preset: "files-backups", keychainService: "com.zacharysturman.filesbackups.pi") { credential in
            if let credential {
                let id = AppModel.defaults.string(forKey: marker).flatMap(UUID.init(uuidString:)) ?? UUID()
                AppModel.defaults.set(id.uuidString, forKey: marker)
                var profile = model.connections.first { $0.id == id }
                    ?? ConnectionProfile(id: id, kind: .homeServices, name: credential.connection.token.name)
                profile.baseURL = credential.base_url
                // Never use the default upload folder as a provider root/ACL.
                profile.rootPath = ""
                let savedSecret = try model.credentials.secret(for: id)
                if model.connections.first(where: { $0.id == id }) != profile || savedSecret != credential.token {
                    try model.save(profile, secret: credential.token)
                }
                AppModel.defaults.set(credential.connection.preferences["upload_folder"], forKey: "piConnection.uploadFolder.v1")
            } else if let raw = AppModel.defaults.string(forKey: marker), let id = UUID(uuidString: raw) {
                if let profile = model.connections.first(where: { $0.id == id }) { try model.remove(profile) }
                AppModel.defaults.removeObject(forKey: marker)
                AppModel.defaults.removeObject(forKey: "piConnection.uploadFolder.v1")
            }
        }
    }
}

extension AppModel {
    func initialFolder(for connection: ConnectionProfile) -> RemotePath {
        guard AppModel.defaults.string(forKey: "piConnection.profile.v1") == connection.id.uuidString,
              let folder = AppModel.defaults.string(forKey: "piConnection.uploadFolder.v1") else { return .root }
        return (try? RemotePath(folder)) ?? .root
    }
}
