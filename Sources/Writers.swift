//
//  Wrtiers.swift
//  LLVM
//
//  Created by Davie Janeway on 16/07/2018.
//

import OrbitCompilerUtils
import OrbitFrontend
import SwiftyJSON

extension OrbitError {
    static func missingAPIMapKey(key: String) -> OrbitError {
        return OrbitError(message: "API Map missing key: \(key)")
    }
}

protocol APIMapExportable {
    static var exportTypeKey: String { get }
    static var exportVersion: Int { get }
    
    func exportBody() -> JSON
    func exportMeta() -> JSON
    func export() -> JSON
}

protocol APIMapImportable {
    static func `import`<T>(body: JSON, type: T.Type) throws -> T
}

extension APIMapImportable {
    static func `import`(body: JSON) throws -> Self {
        return try `import`(body: body, type: self)
    }
}

extension APIMapExportable {
    static var exportTypeKey: String {
        return String(describing: Self.self)
    }
    
    static var exportVersion: Int {
        return APIMap.VERSION
    }
    
    func exportMeta() -> JSON {
        return [
            "type": Self.exportTypeKey,
            "version": Self.exportVersion
        ]
    }
    
    func export() -> JSON {
        return [
            "meta": self.exportMeta(),
            "body": self.exportBody()
        ]
    }
}

extension APIMap : APIMapExportable {
    func exportBody() -> JSON {
        return [
            APIMap.API_MAP_KEY_CANONICAL_NAME: self.canonicalName,
            APIMap.API_MAP_KEY_EXPORTED_TYPES: self.exportedTypes.map { $0.export() },
            APIMap.API_MAP_KEY_EXPORTED_METHODS: self.exportedMethods.map { $0.export() }
        ]
    }
}

extension APIMap : APIMapImportable {
    static func `import`<T>(body: JSON, type: T.Type) throws -> T {
        guard let name = body[APIMap.API_MAP_KEY_CANONICAL_NAME].string else { throw OrbitError.missingAPIMapKey(key: APIMap.API_MAP_KEY_CANONICAL_NAME) }
        guard let types = body[APIMap.API_MAP_KEY_EXPORTED_TYPES].array else { throw OrbitError.missingAPIMapKey(key: APIMap.API_MAP_KEY_EXPORTED_TYPES) }
        guard let methods = body[APIMap.API_MAP_KEY_EXPORTED_METHODS].array else { throw OrbitError.missingAPIMapKey(key: APIMap.API_MAP_KEY_EXPORTED_METHODS) }
        
        
        let tTypes = try types.map { try TypeRecord.import(body: $0) }
        let mTypes = try methods.map { try SignatureTypeRecord.import(body: $0) }
        
        let apiMap = APIMap(canonicalName: name)
        
        tTypes.forEach { apiMap.export(type: $0) }
        mTypes.forEach { apiMap.export(method: $0) }
        
        return apiMap as! T
    }
}

class APIMapWriter : CompilationPhase {
    typealias InputType = APIMap
    typealias OutputType = JSON
    
    let identifier: String
    let session: OrbitSession
    
    required init(session: OrbitSession, identifier: String) {
        self.session = session
        self.identifier = identifier
    }
    
    convenience init(session: OrbitSession) {
        self.init(session: session, identifier: "Orb.Compiler.Backend.APIMapWriter")
    }
    
    func execute(input: APIMap) throws -> JSON {
        return input.export()
    }
}

class APIMapReader : CompilationPhase {
    typealias InputType = JSON
    typealias OutputType = APIMap
    
    let identifier: String
    let session: OrbitSession
    
    required init(session: OrbitSession, identifier: String) {
        self.session = session
        self.identifier = identifier
    }
    
    convenience init(session: OrbitSession) {
        self.init(session: session, identifier: "Orb.Compiler.Backend.APIMapReader")
    }
    
    func execute(input: JSON) throws -> APIMap {
        let body = input["body"]
        
        return try APIMap.import(body: body)
    }
}
