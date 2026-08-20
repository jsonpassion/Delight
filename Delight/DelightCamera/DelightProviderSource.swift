//
//  DelightProviderSource.swift
//  CoreMediaIO에 "Delight" 가상 카메라를 알리는 공급자.
//

import Foundation
import CoreMediaIO
import os

let extensionLog = Logger(subsystem: "forgelab.aitech-gmail.com.Delight.Camera",
                          category: "extension")

class DelightProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DelightDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DelightDeviceSource(localizedName: "Delight")
        do {
            try provider.addDevice(deviceSource.device)
            extensionLog.info("Delight 가상 카메라 등록됨")
        } catch {
            extensionLog.error("장치 등록 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        extensionLog.info("클라이언트 연결: \(client.signingID ?? "?", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) { }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            result.manufacturer = "Delight"
        }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws { }
}
