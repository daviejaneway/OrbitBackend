//
//  linking.swift
//  OrbitBackend
//
//  Created by Davie Janeway on 04/08/2017.
//
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend
import LLVM

func +<T>( lhs: [T], rhs: T) -> [T] {
    var lhs = lhs
    lhs.append(rhs)
    
    return lhs
}

public class CompilationContext {
    private(set) public var typeNameMap = [Name]() // Maps a type's relative name to its fully resolved name
    
    public var apis = [APIExpression]()
    private(set) public var hasMain: Bool = false
    
    public init() {
        self.typeNameMap.append(Name(relativeName: "Int", absoluteName: "Int"))
        self.typeNameMap.append(Name(relativeName: "Int8", absoluteName: "Int8"))
        self.typeNameMap.append(Name(relativeName: "Int16", absoluteName: "Int16"))
        self.typeNameMap.append(Name(relativeName: "Int32", absoluteName: "Int32"))
        self.typeNameMap.append(Name(relativeName: "Int64", absoluteName: "Int64"))
        self.typeNameMap.append(Name(relativeName: "Int128", absoluteName: "Int128"))
        
        self.typeNameMap.append(Name(relativeName: "Real", absoluteName: "Real"))
        self.typeNameMap.append(Name(relativeName: "String", absoluteName: "String"))
    }
    
    public func mapTypeName(relativeName: String, absoluteName: String) throws {
        let name = Name(relativeName: relativeName, absoluteName: absoluteName)
        
        guard !self.typeNameMap.contains(name) else {
            throw OrbitError(message: "Attempting to redefine '\(relativeName)' as '\(absoluteName)'")
        }
        
        self.typeNameMap.append(name)
    }
    
    public func absoluteName(relativeName: String) throws -> String {
        let matches = self.typeNameMap.filter { $0.relativeName == relativeName }
        
        guard matches.count > 0 else {
            throw OrbitError(message: "Undefined type '\(relativeName)'")
        }
        
        guard matches.count < 2 else {
            throw OrbitError(message: "Type '\(relativeName)' is ambigious. Potential matches:\n\t\(matches.map { $0.absoluteName }.joined(separator: "\n\t"))")
        }
        
        return matches[0].absoluteName
    }
    
    public func absoluteName(type: TypeIdentifierExpression) throws -> String {
        guard !type.absolutised else {
            // No lookup needed as the type is already fully qualified
            return type.value
        }
        
        return try absoluteName(relativeName: type.value)
    }
    
    public func mergeAPIs() throws -> APIExpression {
        let mains = self.apis.filter { $0.name.value.hasSuffix(".Main") || $0.name.value == "Main" }
        
        guard mains.count < 2 else { throw OrbitError(message: "This module declares more than one Main api, which is not legal") }
        
        self.hasMain = mains.count == 1
        
        let typeDefs = self.apis.flatMap { $0.body.filter { $0 is TypeDefExpression } }
        let methods = self.apis.flatMap { $0.body.filter { $0 is MethodExpression } }
        
        return APIExpression(name: "API", body: typeDefs + methods)
    }
}

public class NameResolver : CompilationPhase {
    public typealias InputType = [APIExpression]
    public typealias OutputType = CompilationContext
    
    private var apiExpressions = [APIExpression]()
    private var relativeNames = [String]()
    
    private var context = CompilationContext()
    
    func resolveTypeDefs(api: APIExpression) throws {
        let typeDefs = api.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        
        for typeDef in typeDefs {
            if !typeDef.absolutised {
                let absoluteName = "\(api.name.value).\(typeDef.name.value)"
                
                try self.context.mapTypeName(relativeName: typeDef.name.value, absoluteName: absoluteName)
                
                typeDef.absolutise(absoluteName: absoluteName)
                
                try typeDef.properties.forEach { property in
                    let propertyType = try self.context.absoluteName(type: property.type)
                    
                    property.type.absolutise(absoluteName: propertyType)
                }
            }
        }
    }
    
    func resolveStaticCall(expr: StaticCallExpression) throws {
        let receiverTypeName = try self.context.absoluteName(type: expr.receiver)
        
        expr.receiver.absolutise(absoluteName: receiverTypeName)
    }
    
//    func resolveInstanceCall(expr: InstanceCallExpression) throws {
//        let receiverTypeName = try self.context.absoluteName(type: expr.receiver)
//    }
    
    func resolveValueExpression(expr: Expression) throws {
        switch expr {
            case is StaticCallExpression: try resolveStaticCall(expr: expr as! StaticCallExpression)
            
            default: break
        }
    }
    
    func resolveReturnStatement(expr: ReturnStatement) throws {
        try resolveValueExpression(expr: expr.value)
    }
    
    func resolveAssignment(expr: AssignmentStatement) throws {
        try resolveValueExpression(expr: expr.value)
    }
    
    func resolveMethodBody(expr: MethodExpression) throws {
        try expr.body.forEach { statement in
            switch statement {
                case is ReturnStatement: try resolveReturnStatement(expr: statement as! ReturnStatement)
                case is AssignmentStatement: try resolveAssignment(expr: statement as! AssignmentStatement)
                case is StaticCallExpression: try resolveStaticCall(expr: statement as! StaticCallExpression)
                
                default: break
            }
        }
    }
    
    func resolveSignatures(api: APIExpression) throws {
        let methodDefs = api.body.filter { $0 is MethodExpression } as! [MethodExpression]
        let signatures = methodDefs.map { $0.signature }
        
        for signature in signatures {
            let absoluteReceiverTypeName = try self.context.absoluteName(type: signature.receiverType)
            
            signature.receiverType.absolutise(absoluteName: absoluteReceiverTypeName)
            
            let parameterTypeNames = try signature.parameters.map { param in
                let absoluteName = try self.context.absoluteName(type: param.type)
                
                param.absolutise(absoluteName: absoluteName)
                
                return absoluteName
            }.joined(separator: ".")
            
            if let ret = signature.returnType {
                let absoluteReturnTypeName = try self.context.absoluteName(type: ret)
                
                ret.absolutise(absoluteName: absoluteReturnTypeName)
            }
            
            let signatureName = "\(absoluteReceiverTypeName).\(signature.name.value).\(parameterTypeNames)"
            
            signature.absolutise(absoluteName: signatureName)
        }
        
        try methodDefs.forEach { methodDef in
            try resolveMethodBody(expr: methodDef)
        }
    }
    
    func resolveHierarchy(api: APIExpression) throws -> String {
        if api.importPaths.count > 0 {
            let source = SourceResolver()
            
            try api.importPaths.forEach { with in
                let path = with.value
                let code = try source.execute(input: path)
                
                let lexer = Lexer()
                let parser = Parser()
                let lexParseChain = CompilationChain(inputPhase: lexer, outputPhase: parser)
                
                let ast = try lexParseChain.execute(input: code)
                let apis = ast.body as! [APIExpression]
                
                try apis.forEach {
                    _ = try resolveHierarchy(api: $0)
                    self.context.apis.append($0)
                }
            }
        }
        
        if let within = api.within?.value {
            guard within != api.name.value else { throw OrbitError(message: "Attempting to export API '\(within)' into itself") }
            
            // Check the api exists in the given api list
            let matches = self.apiExpressions.filter { $0.name.value == within }
            
            guard matches.count > 0 else {
                throw OrbitError(message: "Could not find an API named '\(within)'")
            }
            
            guard matches.count < 2 else { throw OrbitError(message: "The name '\(within)' refers to multiple APIs") }
            
            let parentAPI = matches[0]
            
            var parentName = parentAPI.name.value
            
            if !parentAPI.absolutised {
                parentName = try resolveHierarchy(api: parentAPI)
            }
            
            let absoluteName = "\(parentName).\(api.name.value)"
            
            api.absolutise(absoluteName: absoluteName)
            
            try resolveTypeDefs(api: api)
            try resolveSignatures(api: api)
            
            return absoluteName
        }
        
        try resolveTypeDefs(api: api)
        try resolveSignatures(api: api)
        
        // API has no parent
        return api.name.value
    }
    
    public func execute(input: [APIExpression]) throws -> CompilationContext {
        self.apiExpressions = input
        
        try input.forEach { api in
            self.relativeNames.append(api.name.value)
            
            let absoluteName = try resolveHierarchy(api: api)
            
            api.absolutise(absoluteName: absoluteName)
            
            self.context.apis.append(api)
        }
        
        return self.context
    }
}
