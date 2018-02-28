//
//  TypeResolver.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 28/02/2018.
//

import Foundation
import OrbitFrontend
import OrbitCompilerUtils

public protocol DebuggableAnnotation : ExpressionAnnotation {
    func dump() -> String
}

public struct TypeRecord : Equatable {
    let shortName: String
    let fullName: String
    
    public static func ==(lhs: TypeRecord, rhs: TypeRecord) -> Bool {
        return lhs.shortName == rhs.shortName || lhs.fullName == rhs.fullName
    }
}

public struct TypeRecordAnnotation : DebuggableAnnotation {
    public let typeRecord: TypeRecord
    
    public func dump() -> String {
        return "@Type -> \(self.typeRecord.fullName)"
    }
}

public class TypeExtractor : CompilationPhase {
    public typealias InputType = RootExpression
    public typealias OutputType = [TypeRecord]
    
    private var types = [TypeRecord]()
    
    public init() {}
    
    func extractTypes(fromApi api: APIExpression) throws {
        let typeDefs = api.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        
        try typeDefs.forEach { td in
            let qualifiedName = "\(api.name.value).\(td.name.value)"
            let tr = TypeRecord(shortName: td.name.value, fullName: qualifiedName)

            if types.contains(tr) {
                throw OrbitError(message: "Duplicate type: \(td.name.value)")
            }
            
            types.append(tr)
        }
    }
    
    public func execute(input: RootExpression) throws -> [TypeRecord] {
        let prog = input.body[0] as! ProgramExpression
        let apis = prog.apis
        
        try apis.forEach { try extractTypes(fromApi: $0) }
        
        return types
    }
}

public class TypeResolver : CompilationPhase {
    public typealias InputType = (RootExpression, [TypeRecord])
    public typealias OutputType = RootExpression
    
    public init() {}
    
    func findType(named: String, types: [TypeRecord]) throws -> TypeRecord {
        let types = types.filter { $0.shortName == named }
        
        guard types.count > 0 else { throw OrbitError(message: "Unknown type: \(named)") }
        guard types.count < 2 else { throw OrbitError(message: "Multiple types named \(named)") }
        
        return types[0]
    }
    
    func resolve(typeId: TypeIdentifierExpression, types: [TypeRecord]) throws {
        let type = try findType(named: typeId.value, types: types)
        
        typeId.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
    }
    
    func resolve(pair: PairExpression, types: [TypeRecord]) throws {
        let type = try findType(named: pair.type.value, types: types)
        let annotation = TypeRecordAnnotation(typeRecord: type)
        
        pair.type.annotate(annotation: annotation)
        pair.name.annotate(annotation: annotation)
        pair.annotate(annotation: annotation)
    }
    
    func resolve(typeDef: TypeDefExpression, types: [TypeRecord]) throws {
        let type = try findType(named: typeDef.name.value, types: types)
        
        typeDef.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
        
        try typeDef.properties.forEach { pair in
            try resolve(pair: pair, types: types)
        }
    }
    
    func resolve(api: APIExpression, types: [TypeRecord]) throws {
        let typeDefs = api.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        try typeDefs.forEach { try resolve(typeDef: $0, types: types) }
    }
    
    public func execute(input: (RootExpression, [TypeRecord])) throws -> RootExpression {
        let prog = input.0.body[0] as! ProgramExpression
        let apis = prog.apis
        
        try apis.forEach { try resolve(api: $0, types: input.1) }
        
        return input.0
    }
}
