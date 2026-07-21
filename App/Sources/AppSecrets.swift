//
//  AppSecrets.swift
//  CueSync AR
//
//  SecretsProviding backed by Info.plist keys, which are fed from the
//  untracked App/Config/Secrets.xcconfig (see Secrets.example.xcconfig).
//  No MVP feature requires a secret; adapters that need one must degrade
//  gracefully when this returns nil.
//

import CueSyncCore
import Foundation

struct AppSecrets: SecretsProviding {
    func secret(for key: SecretKey) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key.rawValue) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") // unexpanded build setting
        else {
            return EnvironmentSecrets().secret(for: key)
        }
        return value
    }
}
