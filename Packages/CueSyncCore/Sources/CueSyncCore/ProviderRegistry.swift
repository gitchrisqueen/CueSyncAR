//
//  ProviderRegistry.swift
//  CueSyncCore
//
//  Composition root helper: the app registers one implementation per provider
//  protocol at startup; consumers resolve by protocol type. Swapping Roboflow
//  for Core ML, or Claude for on-device models, is a registration change only.
//

import Foundation

public actor ProviderRegistry {
    public enum RegistryError: Error, Equatable {
        case notRegistered(String)
    }

    private var providers: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    /// Register `provider` as the implementation of protocol `type`.
    /// Re-registering replaces the previous provider (last one wins).
    public func register<P: Sendable>(_ provider: P, as type: P.Type = P.self) {
        providers[ObjectIdentifier(type)] = provider
    }

    /// Resolve the registered implementation of `type`.
    public func resolve<P: Sendable>(_ type: P.Type = P.self) throws -> P {
        guard let provider = providers[ObjectIdentifier(type)] as? P else {
            throw RegistryError.notRegistered(String(describing: type))
        }
        return provider
    }

    /// Resolve, or nil when nothing is registered for `type`.
    public func resolveIfRegistered<P: Sendable>(_ type: P.Type = P.self) -> P? {
        providers[ObjectIdentifier(type)] as? P
    }
}
