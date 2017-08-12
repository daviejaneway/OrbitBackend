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

extension Array where Element == Name {
    subscript(index: String, mode: NameMode) -> [Element] {
        get {
            if mode == .Absolute {
                return self.filter { $0.absoluteName == index }
            } else {
                return self.filter { $0.relativeName == index }
            }
        } set(newValue) {
            
        }
    }
}

public class CompilationContext {
    private(set) public var typeNameMap = [Name]() // Maps a type's relative name to its fully resolved name
    
    public var methodNameMap = [Name]() // Maps a method's absolute name to its relative name
    
    public var apis = [APIExpression]()
    private(set) public var hasMain: Bool = false
    
    public var typeMethodMaps = [TypeMethodMap]()
    public var traitMethodMaps = [TraitMethodMap]()
    
    public var generatedMethods = [Expression]()
    
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
    
    public func mapTypeName(relativeName: String, absoluteName: String, position: SourcePosition) throws {
        let name = Name(relativeName: relativeName, absoluteName: absoluteName)
        
        guard !self.typeNameMap.contains(name) else {
            throw OrbitError(message: "Attempting to redefine '\(relativeName)' as '\(absoluteName)'", position: position)
        }
        
        self.typeNameMap.append(name)
    }
    
    public func absoluteName(relativeName: String, position: SourcePosition) throws -> String {
        let matches = self.typeNameMap.filter { $0.relativeName == relativeName }
        
        guard matches.count > 0 else {
            throw OrbitError(message: "Undefined type '\(relativeName)'", position: position)
        }
        
        guard matches.count < 2 else {
            throw OrbitError(message: "Type '\(relativeName)' is ambigious. Potential matches:\n\t\(matches.map { $0.absoluteName }.joined(separator: "\n\t"))", position: position)
        }
        
        return matches[0].absoluteName
    }
    
    public func absoluteName(type: TypeIdentifierExpression) throws -> String {
        guard !type.absolutised else {
            // No lookup needed as the type is already fully qualified
            return type.value
        }
        
        return try absoluteName(relativeName: type.value, position: type.startToken.position)
    }
    
    public func mergeAPIs() throws -> APIExpression {
        let mains = self.apis.filter { $0.name.value.hasSuffix(".Main") || $0.name.value == "Main" }
        
        guard mains.count < 2 else {
            let position = mains[0].startToken.position
            throw OrbitError(message: "This module declares more than one Main api, which is not legal", position: position)
        }
        
        self.hasMain = mains.count == 1
        
        let traitDefs = self.apis.flatMap { $0.body.filter { $0 is TraitDefExpression } }
        let typeDefs = self.apis.flatMap { $0.body.filter { $0 is TypeDefExpression } }
        let methods = self.apis.flatMap { $0.body.filter { $0 is MethodExpression } }
        
        // Order is important here
        let body = traitDefs + typeDefs + generatedMethods + methods
        return APIExpression(name: "API", body: body, startToken: self.apis[0].startToken)
    }
}

public class NameResolver : CompilationPhase {
    public typealias InputType = [APIExpression]
    public typealias OutputType = CompilationContext
    
    private var apiExpressions = [APIExpression]()
    private var relativeNames = [String]()
    
    private var context = CompilationContext()
    
    public init() {}
    
    func resolveTypeDefs(api: APIExpression) throws {
        let typeDefs = api.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        
        for typeDef in typeDefs {
            if !typeDef.absolutised {
                let absoluteName = "\(api.name.value).\(typeDef.name.value)"
                
                try self.context.mapTypeName(relativeName: typeDef.name.value, absoluteName: absoluteName, position: typeDef.startToken.position)
                
                typeDef.absolutise(absoluteName: absoluteName)
                
                try typeDef.properties.forEach { property in
                    let propertyType = try self.context.absoluteName(type: property.type)
                    
                    property.type.absolutise(absoluteName: propertyType)
                }
                
                try typeDef.adoptedTraits.forEach { trait in
                    let traitName = try self.context.absoluteName(type: trait)
                    
                    trait.absolutise(absoluteName: traitName)
                }
            }
        }
    }
    
    func resolveTraitDefs(api: APIExpression) throws {
        let traitDefs = api.body.filter { $0 is TraitDefExpression } as! [TraitDefExpression]
        
        for traitDef in traitDefs {
            if !traitDef.absolutised {
                let absoluteName = "\(api.name.value).\(traitDef.name.value)"
                
                try self.context.mapTypeName(relativeName: traitDef.name.value, absoluteName: absoluteName, position: traitDef.startToken.position)
                
                traitDef.absolutise(absoluteName: absoluteName)
                
                try traitDef.properties.forEach { property in
                    let propertyType = try self.context.absoluteName(type: property.type)
                    
                    property.type.absolutise(absoluteName: propertyType)
                }
            }
        }
    }
    
    func resolveStaticCall(expr: StaticCallExpression) throws {
        let receiverTypeName = try self.context.absoluteName(type: expr.receiver)
        
        try expr.args.forEach {
            try resolveValueExpression(expr: $0)
        }
        
        expr.receiver.absolutise(absoluteName: receiverTypeName)
    }
    
//    func resolveInstanceCall(expr: InstanceCallExpression) throws {
//        let receiverTypeName = try self.context.absoluteName(type: expr.receiver)
//    }
    
    func resolveListExpression(expr: ListExpression) throws {
        try expr.value.forEach {
            try resolveValueExpression(expr: $0)
        }
    }
    
    func resolveValueExpression(expr: Expression) throws {
        // TODO - Fill in the missing expressions types here
        
        switch expr {
            case is StaticCallExpression: try resolveStaticCall(expr: expr as! StaticCallExpression)
            case is ListExpression: try resolveListExpression(expr: expr as! ListExpression)
            
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
            
            // Return type is not part of the signature name
            let signatureName = "\(absoluteReceiverTypeName).\(signature.name.value).\(parameterTypeNames)"
            
            // Abusing names to make looking up signatures easier further down the line
            context.methodNameMap.append(Name(relativeName: signatureName, absoluteName: signature.name.value))
            
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
            guard within != api.name.value else { throw OrbitError(message: "Attempting to export API '\(within)' into itself", position: api.startToken.position) }
            
            // Check the api exists in the given api list
            let matches = self.apiExpressions.filter { $0.name.value == within }
            
            guard matches.count > 0 else {
                throw OrbitError(message: "Could not find an API named '\(within)'", position: api.startToken.position)
            }
            
            guard matches.count < 2 else {
                throw OrbitError(message: "The name '\(within)' refers to multiple APIs", position: matches[0].startToken.position)
            }
            
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
        
        try resolveTraitDefs(api: api)
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
