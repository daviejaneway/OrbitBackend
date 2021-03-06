//
//  TypeResolver.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 28/02/2018.
//

import Foundation
import OrbitFrontend
import OrbitCompilerUtils
import SwiftyJSON

extension ConstructorCallExpression : RValueExpression {}

extension PhaseAnnotation {
    public init(expression: AnnotationExpression, identifier: String) {
        self.annotationExpression = expression
        self.identifier = identifier
    }
}

public protocol DebuggableAnnotation : Annotation {
    func dump() -> String
}

extension PhaseAnnotation : DebuggableAnnotation {
    public func dump() -> String {
        return "@PhaseAnnotation -> \(self.annotationExpression.annotationName.value)"
    }
}

public class AbstractTypeRecord : Equatable, APIMapExportable, Hashable {
    public let hashValue: Int
    
    static let API_MAP_KEY_FULL_NAME = "full_name"
    static let API_MAP_KEY_SHORT_NAME = "short_name"
    
    public let shortName: String
    public let fullName: String
    
    var isImported = false
    
    public init(shortName: String, fullName: String) {
        self.shortName = shortName
        self.fullName = fullName
        self.hashValue = fullName.hashValue
    }
    
    public static func ==(lhs: AbstractTypeRecord, rhs: AbstractTypeRecord) -> Bool {
        return lhs.shortName == rhs.shortName || lhs.fullName == rhs.fullName
    }
    
    public func exportBody() -> JSON {
        return [
            AbstractTypeRecord.API_MAP_KEY_FULL_NAME: self.fullName,
            AbstractTypeRecord.API_MAP_KEY_SHORT_NAME: self.shortName
        ]
    }
}

public class TypeRecord : AbstractTypeRecord, APIMapImportable {
    // TODO: All of these boostrap types should be defined by the CallingConvention
    static let unit = TypeRecord(shortName: "()", fullName: "Orb.Core.Types.Unit")
    static let int = TypeRecord(shortName: "Int", fullName: "Orb.Core.Types.Int")
    static let real = TypeRecord(shortName: "Real", fullName: "Orb.Core.Types.Real")
    static let op = TypeRecord(shortName: "Operator", fullName: "Orb.Core.Operators.Operator")
    static let list = TypeRecord(shortName: "List", fullName: "Orb.Core.Types.Collections.List")
    
    public class func `import`<T>(body: JSON, type: T.Type) throws -> T {
        let body = body["body"]
        
        guard let fname = body[AbstractTypeRecord.API_MAP_KEY_FULL_NAME].string else {
            throw OrbitError.missingAPIMapKey(key: AbstractTypeRecord.API_MAP_KEY_FULL_NAME)
        }
        
        guard let sname = body[AbstractTypeRecord.API_MAP_KEY_SHORT_NAME].string else {
            throw OrbitError.missingAPIMapKey(key: AbstractTypeRecord.API_MAP_KEY_SHORT_NAME)
        }
        
        return TypeRecord(shortName: sname, fullName: fname) as! T
    }
}

public class CompoundTypeRecord : TypeRecord {
    public let memberTypes: [AbstractTypeRecord]
    
    public init(shortName: String, fullName: String, memberTypes: [AbstractTypeRecord]) {
        self.memberTypes = memberTypes
        super.init(shortName: shortName, fullName: fullName)
    }
}

public class GenericTypeRecord : AbstractTypeRecord {
    let baseType: AbstractTypeRecord
    let typeParameters: [AbstractTypeRecord]
    
    init(baseType: AbstractTypeRecord, typeParameters: [AbstractTypeRecord]) {
        self.typeParameters = typeParameters
        self.baseType = baseType
        
        let sName = "\(baseType.shortName).\(typeParameters.map { $0.shortName }.joined(separator: "."))"
        let fName = "\(baseType.fullName).\(typeParameters.map { $0.fullName }.joined(separator: "."))"
        
        super.init(shortName: sName, fullName: fName)
    }
}

public class AbstractListTypeRecord : AbstractTypeRecord {}

//public class ListTypeRecord : AbstractListTypeRecord, GenericTypeRecord {
//    public let typeParameters: [AbstractTypeRecord]
//
//    init(elementType: AbstractTypeRecord) {
//        self.typeParameters = [elementType]
//        super.init(shortName: "List.\(elementType.shortName)", fullName: "Orb.Core.Types.Collections.List.\(elementType.fullName)")
//    }
//}
//
//public class EmptyListTypeRecord : AbstractListTypeRecord {
//    init() {
//        super.init(shortName: "List", fullName: "Orb.Core.Types.Collections.List")
//    }
//}

public class SignatureTypeRecord : AbstractTypeRecord, APIMapImportable {
    private static let API_MAP_KEY_NAME = "name"
    private static let API_MAP_KEY_RECEIVER = "receiver"
    private static let API_MAP_KEY_ARGS = "args"
    private static let API_MAP_KEY_RETURN = "return"
    
    //static let intPrefixPlus = SignatureTypeRecord(shortName: "+", receiver: TypeRecord.op, ret: TypeRecord.int, args: [TypeRecord.int])
    
    //static let intInfixPlus = SignatureTypeRecord(shortName: "+", receiver: TypeRecord.op, ret: TypeRecord.int, args: [TypeRecord.int, TypeRecord.int])
    
    let receiver: AbstractTypeRecord
    let ret: AbstractTypeRecord
    let args: [AbstractTypeRecord]
    
    public init(shortName: String, receiver: AbstractTypeRecord, ret: AbstractTypeRecord?, args: [AbstractTypeRecord]) {
        let fullName = "\(receiver.fullName).\(shortName).\(args.map { $0.fullName }.joined(separator: "."))"
        
        self.receiver = receiver
        self.ret = ret ?? TypeRecord.unit
        self.args = args
        
        super.init(shortName: shortName, fullName: fullName)
    }
    
    func stringValue() -> String {
        return "(\(self.receiver.fullName) \(self.shortName) (\(self.args.map { $0.fullName }.joined(separator: ","))) (\(self.ret.fullName))"
    }
    
    override public func exportBody() -> JSON {
        return [
            SignatureTypeRecord.API_MAP_KEY_NAME: self.fullName,
            SignatureTypeRecord.API_MAP_KEY_RECEIVER: self.receiver.export(),
            SignatureTypeRecord.API_MAP_KEY_ARGS: self.args.map { $0.export() },
            SignatureTypeRecord.API_MAP_KEY_RETURN: self.ret.export()
        ]
    }
    
    public static func `import`<T>(body: JSON, type: T.Type) throws -> T {
        let body = body["body"]
        
        guard let name = body[SignatureTypeRecord.API_MAP_KEY_NAME].string else {
            throw OrbitError.missingAPIMapKey(key: SignatureTypeRecord.API_MAP_KEY_NAME)
        }
        guard let arg = body[SignatureTypeRecord.API_MAP_KEY_ARGS].array else { throw OrbitError.missingAPIMapKey(key: SignatureTypeRecord.API_MAP_KEY_ARGS) }
        
        let rec = body[SignatureTypeRecord.API_MAP_KEY_RECEIVER]
        let ret = body[SignatureTypeRecord.API_MAP_KEY_RETURN]
        
        let recType = try TypeRecord.import(body: rec)
        let argType = try arg.map { try TypeRecord.import(body: $0) }
        let retType = try TypeRecord.import(body: ret)
        
        return SignatureTypeRecord(shortName: name, receiver: recType, ret: retType, args: argType) as! T
    }
}

public class MethodTypeRecord : AbstractTypeRecord {
    public let signature: SignatureTypeRecord
    
    public init(shortName: String, signature: SignatureTypeRecord) {
        self.signature = signature
        
        super.init(shortName: shortName, fullName: signature.fullName)
    }
}

public class TypeAnnotation : DebuggableAnnotation {
    public let typeRecord: AbstractTypeRecord
    public let identifier = "Orb.Compiler.Backend.Annotations.Type"
    
    init(typeRecord: AbstractTypeRecord) {
        self.typeRecord = typeRecord
    }
    
    public func equal(toOther annotation: Annotation) -> Bool {
        guard let other = annotation as? TypeAnnotation else { return false }
        
        return (self.identifier == annotation.identifier) &&
            (self.typeRecord.fullName == other.typeRecord.fullName)
    }
    
    public func dump() -> String {
        return "@Type -> \(self.typeRecord.fullName)"
    }
}

public class CompoundTypeAnnotation : TypeAnnotation {
    public let memberTypes: [TypeAnnotation]
    
    init(typeRecord: AbstractTypeRecord, memberTypes: [TypeAnnotation]) {
        self.memberTypes = memberTypes
        super.init(typeRecord: typeRecord)
    }
    
    public override func dump() -> String {
        return "@Type -> \(self.typeRecord.fullName)(\(self.memberTypes.map { $0.dump() }.joined(separator: ",")))"
    }
}

public struct ScopeAnnotation : DebuggableAnnotation {
    public let scope: Scope
    public let identifier = "Orb.Compiler.Backend.Annotations.Scope"
    
    public func equal(toOther annotation: Annotation) -> Bool {
        return self.identifier == annotation.identifier
    }
    
    public func dump() -> String {
        return "@Scope -> \(self.scope)"
    }
}

public struct MetaDataAnnotation : DebuggableAnnotation {
    public let identifier = "Orb.Compiler.Backend.Annotations.MetaData"
    public let data: [String : AnyHashable]
    
    public func equal(toOther annotation: Annotation) -> Bool {
        return self.identifier == annotation.identifier
    }
    
    public func dump() -> String {
        return "@MetaData -> \(self.data.map { "\($0.key): \($0.value)" })"
    }
}

class InsertTypeExtension : PhaseExtension {
    let extensionName = "Orb.Compiler.Backend.TypeExtractor.InsertType"
    let parameterTypes: [AbstractExpression.Type] = []
    
    func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        let typeName = annotation.parameters[0] as! IdentifierExpression
        let typeId = TypeIdentifierExpression(value: typeName.value, startToken: annotation.startToken)
        let typeDef = TypeDefExpression(name: typeId, properties: [], propertyOrder: [:], constructorSignatures: [], adoptedTraits: [], startToken: annotation.startToken)
        
        let typeExtractor = phase as! TypeExtractor
        
        typeExtractor.types.append(TypeRecord(shortName: typeName.value, fullName: typeName.value))
        
        return typeDef
    }
}

public class APIMap {
    public static let VERSION = 0
    
    static let API_MAP_KEY_CANONICAL_NAME = "canonical_name"
    static let API_MAP_KEY_EXPORTED_TYPES = "exported_types"
    static let API_MAP_KEY_EXPORTED_METHODS = "exported_methods"
    
    private(set) public var exportedMethods: [SignatureTypeRecord] = []
    private(set) public var exportedTypes: [TypeRecord] = []
    
    public let canonicalName: String
    
    var isImported: Bool = false
    
    init(canonicalName: String) {
        self.canonicalName = canonicalName
    }
    
    public func findType(named: String) throws -> TypeRecord? {
        let results = self.exportedTypes.filter { $0.shortName == named || $0.fullName == named }
        
        guard results.count > 0 else { return nil }
        
        return results[0]
    }
    
    public func export(type: TypeRecord) {
        guard !self.exportedTypes.contains(where: { $0.fullName == type.fullName }) else { return }
        
        self.exportedTypes.append(type)
    }
    
    public func export(method: SignatureTypeRecord) {
        self.exportedMethods.append(method)
    }
    
    public func importAll(fromAPI api: APIMap) {
        api.exportedTypes.forEach { $0.isImported = true }
        api.exportedMethods.forEach { $0.isImported = true }
        
        api.exportedTypes.forEach { type in
            guard !self.exportedTypes.contains(type) else { return }
            self.exportedTypes.insert(type, at: 0)
        }
        
        api.exportedMethods.forEach { method in
            guard !self.exportedMethods.contains(method) else { return }
            self.exportedMethods.insert(method, at: 0)
        }
        
//        self.exportedTypes.insert(contentsOf: api.exportedTypes, at: 0)
//        self.exportedMethods.insert(contentsOf: api.exportedMethods, at: 0)
    }
    
    static func mergeAll(apis: [APIMap]) -> APIMap {
        let nMap = APIMap(canonicalName: "")
        
        apis.forEach { nMap.importAll(fromAPI: $0) }
        
        return nMap
    }
}

public class TypeExtractor : ExtendablePhase {
    public typealias InputType = RootExpression
    public typealias OutputType = [APIMap]
    
    public let extensions: [String : PhaseExtension] = [
        "Orb.Compiler.Backend.TypeExtractor.InsertType" : InsertTypeExtension()
    ]
    
    public let identifier = "Orb.Compiler.Backend.TypeExtractor"
    public let phaseName = "Orb.Compiler.Backend.TypeExtractor"
    public let session: OrbitSession
    
    fileprivate var types = [TypeRecord]()
    private var apiMaps = [APIMap]()
    
    public required init(session: OrbitSession, identifier: String = "") {
        self.session = session
    }
    
    private func findDependency(named: String) throws -> ([APIMap], [OrbitAPI]) {
        // 1. Search for referenced API in file scope (multiple apis per file is allowed)
        let matches = self.apiMaps.filter { $0.canonicalName == named }
        
        if matches.count == 0 {
            // 2. Search known Orb paths for .orb or .api file
            
            let path = try self.session.findOrbitFile(named: named)
            let source = SourceResolver(session: self.session)
            
            if path.format == .API {
                // Dependency is precompiled, import the .api map
                let json = OrbitJsonConverter(session: self.session)
                let chain1 = CompilationChain(inputPhase: source, outputPhase: json)
                let reader = APIMapReader(session: self.session)
                let chain2 = CompilationChain(inputPhase: chain1, outputPhase: reader)
                
                let apiMap = try chain2.execute(input: path.url.path)
                
                apiMap.isImported = true
                
                return ([apiMap], [])
            } else {
                // Dependency is source file, recursively compile
                let lexer = Lexer(session: self.session)
                let parser = ParseContext.bootstrapParser(session: self.session)
                let chain1 = CompilationChain(inputPhase: lexer, outputPhase: parser)
                let chain2 = CompilationChain(inputPhase: source, outputPhase: chain1)
                let ast = try chain2.execute(input: path.url.path)
                
                let root = ast as! RootExpression
                var prog = root.body[0] as! ProgramExpression
                
                let dependencyGraph = DependencyGraph(session: session)
                let ordered = try dependencyGraph.execute(input: root)
                
                prog = ProgramExpression(apis: ordered, startToken: prog.startToken)
                root.body = [prog]
                let apis = try self.execute(input: root)
                
                let typeResolver = TypeResolver(session: session)
                let result = try typeResolver.execute(input: (ast as! RootExpression, apis))
                
                let typeChecker = TypeChecker(session: session)
                let verified = try typeChecker.execute(input: result)
                
                let llvm = LLVMGen(session: self.session)
                let libs = try llvm.execute(input: (verified, apis))
                
                return (apis, libs)
            }
        } else if matches.count > 1 {
            throw OrbitError(message: "Multiple dependencies found for name '\(named)'")
        }
        
        guard matches.count > 0 else { throw OrbitError(message: "Dependency '\(named)' not found") }
        
        return (matches, [])
    }
    
    func extractTypes(fromApi api: APIExpression) throws -> APIMap {
        let typeDefs = api.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        
        let apiMap: APIMap
        
        if let within = api.within {
            _ = try findDependency(named: within.apiRef.value)
            
            apiMap = APIMap(canonicalName: "\(within.apiRef.value).\(api.name.value)")
        } else {
            apiMap = APIMap(canonicalName: api.name.value)
        }
        
        if let with = api.with {
            for w in with.withs {
                let deps = try findDependency(named: w.value)
                
                deps.0.forEach {
                    apiMap.importAll(fromAPI: $0)
                }
                
                api.annotate(annotation: OrbitAPIAnnotation(apis: deps.1))
            }
        }
        
        try typeDefs.forEach { td in
            let qualifiedName = "\(apiMap.canonicalName).\(td.name.value)"
            
            let propertyTypes = try td.properties.map { pair in
                return try findType(named: pair.type.value)
            }
            
            let tr: TypeRecord
            
            if propertyTypes.isEmpty {
                tr = TypeRecord(shortName: td.name.value, fullName: qualifiedName)
            } else {
                tr = CompoundTypeRecord(shortName: td.name.value, fullName: qualifiedName, memberTypes: propertyTypes)
            }
            
            if self.types.contains(tr) {
                throw OrbitError(message: "Duplicate type: \(td.name.value)")
            }
            
            apiMap.export(type: tr)
        }
        
        func findType(named: String) throws -> AbstractTypeRecord {
            guard let type = try apiMap.findType(named: named) else { throw OrbitError(message: "Type '\(named)' not found") }
            
            return type
        }
        
        // TODO - Encapsulate this for all ExtendablePhases
        let annotations = (api.body.filter { $0 is AnnotationExpression } as! [AnnotationExpression]).filter {
            $0.annotationName.value.starts(with: self.identifier)
        }
        
        try annotations.forEach { ann in
            guard let ext = self.extensions[ann.annotationName.value] else {
                throw OrbitError(message: "No extension named \(ann.annotationName.value) found for Phase \(self.identifier)")
            }
            
            let result = try ext.execute(phase: self, annotation: ann)
            
            try api.rewriteChildExpression(childExpressionHash: ann.hashValue, input: result)
        }
        
        let methods = api.body.filter { $0 is MethodExpression } as! [MethodExpression]
        
        try methods.forEach { mthd in
            let sig = mthd.signature
            
            let recType = try findType(named: sig.receiverType.value)
            let argTypes = try sig.parameters.map { try findType(named: $0.type.value) }
            let retType = try (sig.returnType == nil) ? TypeRecord.unit : findType(named: sig.returnType!.value)
            
            let sigType = SignatureTypeRecord(shortName: sig.name.value, receiver: recType, ret: retType, args: argTypes)
            
            apiMap.export(method: sigType)
        }
        
        return apiMap
    }
    
    public func execute(input: RootExpression) throws -> [APIMap] {
        let prog = input.body[0] as! ProgramExpression
        let apis = prog.apis
        
        for api in apis {
            let apiMap = try extractTypes(fromApi: api)
            
            self.apiMaps.append(apiMap)
        }
        
        return self.apiMaps
    }
}

public class Scope {
    private(set) static var global = Scope()
    
    private var typeMap = [AbstractTypeRecord]()
    private var aliases = [String : AbstractTypeRecord]()
    
    private let parentScope: Scope?
    private var bindings = [String : AbstractTypeRecord]()
    
    private init() {
        self.parentScope = nil
    }
    
    init(parentScope: Scope, typeMap: [AbstractTypeRecord]? = nil) {
        self.parentScope = parentScope
        
        // A new scope level should always know about the types above
        self.typeMap = typeMap ?? parentScope.typeMap
        
        //self.declare(type: MethodTypeRecord.intInfixPlus)
    }
    
    func declare(type: AbstractTypeRecord) {
        self.typeMap.append(type)
    }
    
    func bind(name: String, toType: AbstractTypeRecord) {
        self.bindings[name] = toType
    }
    
    func lookup(bindingForName name: String) -> AbstractTypeRecord? {
        // If the name isn't bound in the current scope, go up the chain
        return self.bindings[name] ?? self.parentScope?.lookup(bindingForName: name)
    }
    
    func findType(named: String, customError: OrbitError? = nil) throws -> AbstractTypeRecord {
        if let alias = self.aliases[named] {
            return alias
        }
        
        let types = self.typeMap.filter { $0.fullName == named || $0.shortName == named }
        
        guard types.count > 0 else {
            throw customError ?? OrbitError(message: "Unknown type: \(named)")
        }
        
        if types.count > 1 {
            let identical = types.reduce((true, types[0])) { (arg0, type) -> (Bool, AbstractTypeRecord) in
                let (result, initial) = arg0
                
                return (result && (initial.fullName == type.fullName), type)
            }
            
            guard identical.0 else {
                let unique = Array(Set<AbstractTypeRecord>(types))
                
                let errorMessage = "PROBLEM:\n\tMultiple types found for name '\(named)':\n\t\t\(unique.map { $0.fullName }.joined(separator: "\n\t\t"))\n\nSOLUTION:\n\tPrepend namespace to resolve conflict"
                
                throw OrbitError(message: errorMessage)
            }
        }
        
        return types[0]
    }
}

class AliasTypeExtension : PhaseExtension {
    let extensionName = "Orb.Compiler.Backend.TypeResolver.AliasType"
    let parameterTypes: [AbstractExpression.Type] = []
    
    func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        let scope = try TypeUtils.extractScope(fromExpression: annotation).scope
        let sourceId = annotation.parameters[0] as! IdentifierExpression
        let targetId = annotation.parameters[1] as! TypeIdentifierExpression
        
        scope.declare(type: TypeRecord(shortName: sourceId.value, fullName: targetId.value))
        
        return annotation
    }
}

public class Specialisation : PhaseExtension {
    public let extensionName = "Special"
    
    public let parameterTypes = [AbstractExpression.Type]()
    
    public func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        // TODO - Good errors
        let genericTypeId = annotation.parameters[0] as! TypeIdentifierExpression
        let scope = try TypeUtils.extractScope(fromExpression: annotation)
        let genericType = try scope.scope.findType(named: genericTypeId.value)
        
        // TODO - Check genericType is actually generic
        // TODO - Check number of params matchs expected number of type parameters for genericType
        let specialTypes = try annotation.parameters[1...].map { try scope.scope.findType(named: ($0 as! TypeIdentifierExpression).value) }
        
        let specialised = GenericTypeRecord(baseType: genericType, typeParameters: specialTypes)
        
        scope.scope.declare(type: specialised)
        
        let typeDef = TypeDefExpression(name: TypeIdentifierExpression(value: specialised.fullName, startToken: annotation.startToken), properties: [], propertyOrder: [:], constructorSignatures: [], adoptedTraits: [], startToken: annotation.startToken)
        
        typeDef.annotate(annotation: TypeAnnotation(typeRecord: specialised))
        
        return typeDef
    }
}

public class TypeResolver : ExtendablePhase {
    public typealias InputType = (RootExpression, [APIMap])
    public typealias OutputType = RootExpression
    
    public let identifier = "Orb.Compiler.Backend.TypeResolver"
    public let phaseName = "Orb.Compiler.Backend.TypeResolver"
    public let session: OrbitSession
    
    public var extensions: [String : PhaseExtension] = [
        "Orb.Compiler.Backend.TypeResolver.AliasType": AliasTypeExtension(),
        "Special": Specialisation()
    ]
    
    public required init(session: OrbitSession, identifier: String = "") {
        self.session = session
    }
    
    func resolve(typeId: TypeIdentifierExpression, scope: Scope) throws -> AbstractTypeRecord {
        var type: AbstractTypeRecord = try scope.findType(named: typeId.value)
        
        if typeId is ListTypeIdentifierExpression {
            type = GenericTypeRecord(baseType: TypeRecord.list, typeParameters: [type])
        }
        
        typeId.annotate(annotation: TypeAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(pair: PairExpression, scope: Scope) throws -> AbstractTypeRecord {
        let type = try scope.findType(named: pair.type.value)
        let annotation = TypeAnnotation(typeRecord: type)
        
        pair.type.annotate(annotation: annotation)
        pair.name.annotate(annotation: annotation)
        pair.annotate(annotation: annotation)
        
        return type
    }
    
    func resolve(typeDef: TypeDefExpression, scope: Scope, apiName: String) throws {
        let memberTypes: [AbstractTypeRecord] = try typeDef.properties.map { pair in
            let typeRecord = try self.resolve(pair: pair, scope: scope)
            
            pair.annotate(annotation: TypeAnnotation(typeRecord: typeRecord))
            
            return typeRecord
        }
        
        let type = try self.resolve(typeId: typeDef.name, scope: scope)
        
        typeDef.annotate(annotation: TypeAnnotation(typeRecord: type))
    }
    
    func resolve(intLiteral: IntLiteralExpression) throws -> AbstractTypeRecord {
        return TypeRecord.int
    }
    
    func resolve(realLiteral: RealLiteralExpression) throws -> AbstractTypeRecord {
        return TypeRecord.real
    }
    
    func resolve(listLiteral: ListLiteralExpression, scope: Scope) throws -> AbstractTypeRecord {
        let innerTypes = try listLiteral.value.map { try resolve(value: $0 as! RValueExpression, scope: scope) }
        
        // TODO - Product types
        
        return GenericTypeRecord(baseType: TypeRecord.list, typeParameters: innerTypes)
    }
    
    func resolve(unary: UnaryExpression, scope: Scope) throws -> AbstractTypeRecord {
        let valueType = try resolve(value: unary.value as! RValueExpression, scope: scope)
        // Rewrite as static call. e.g. -1 = Int.-.Int
        let opFuncName = "\(valueType.fullName).\(unary.op.symbol).\(valueType.fullName)"
        
        // TODO: This is actually a form of type checking. Error message should be more useful
        let error = OrbitError(message: "Prefix Operator function '\(unary.op.symbol)' is not defined with parameter type '\(valueType.fullName)'")
        let opFunc = try scope.findType(named: opFuncName, customError: error) as! MethodTypeRecord
        
        let type = opFunc.signature.ret
        
        unary.annotate(annotation: TypeAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(binary: BinaryExpression, scope: Scope) throws -> AbstractTypeRecord {
        let leftType = try resolve(value: binary.left as! RValueExpression, scope: scope)
        let rightType = try resolve(value: binary.right as! RValueExpression, scope: scope)
        
        let opFuncName = "\(TypeRecord.op.fullName).\(binary.op.symbol).\(leftType.fullName).\(rightType.fullName)"
        let error = OrbitError(message: "Infix Operator function '\(binary.op.symbol)' is not defined with parameter types (\(leftType.fullName), \(rightType.fullName))")
        
        let opFunc = try scope.findType(named: opFuncName, customError: error)
        
        let type: AbstractTypeRecord
        
        if opFunc is MethodTypeRecord {
            type = (opFunc as! MethodTypeRecord).signature.ret
        } else {
            type = (opFunc as! SignatureTypeRecord).ret
        }
        
        binary.annotate(annotation: TypeAnnotation(typeRecord: type))
        binary.annotate(annotation: MetaDataAnnotation(data: ["OperatorFunction": opFunc]))
        
        return type
    }
    
    func resolve(assignment: AssignmentStatement, scope: Scope) throws -> AbstractTypeRecord {
        let rhs = try resolve(value: assignment.value as! RValueExpression, scope: scope)
        
        if let lhsType = assignment.type {
            let type = try resolve(typeId: lhsType, scope: scope)
            // Dirty hack to allow annotations to skip type checking
            let ignore = assignment.value is AnnotationExpression
            
            if !ignore && rhs != type {
                throw OrbitError(message: "Assignment declares '\(assignment.name.value)' of type '\(type.fullName)', but right-hand side value is type '\(rhs.fullName)'")
            }
            
            assignment.annotate(annotation: TypeAnnotation(typeRecord: type))
            
            scope.bind(name: assignment.name.value, toType: type)
            
            return type
        }
        
        assignment.annotate(annotation: TypeAnnotation(typeRecord: rhs))
        
        scope.bind(name: assignment.name.value, toType: rhs)
        
        return rhs
    }
    
    func resolve(staticCall: StaticCallExpression, scope: Scope) throws -> AbstractTypeRecord {
        let receiver = try resolve(typeId: staticCall.receiver, scope: scope)
        let args = try staticCall.args.map { try resolve(value: $0, scope: scope).fullName }
        let fname = "\(receiver.fullName).\(staticCall.methodName.value).\(args.joined(separator: "."))"
        
        let error = OrbitError(message: "Method '\(fname)' not declared in current scope")
        let fn = try scope.findType(named: fname, customError: error)
        
        let type: AbstractTypeRecord
        
        if fn is MethodTypeRecord {
            type = (fn as! MethodTypeRecord).signature.ret
        } else {
            type = (fn as! SignatureTypeRecord).ret
        }
        
        let annotation = TypeAnnotation(typeRecord: type)
        
        staticCall.annotate(annotation: annotation)
        staticCall.methodName.annotate(annotation: annotation)
        
        staticCall.annotate(annotation: MetaDataAnnotation(data: ["ExpandedMethodName": fname]))
        
        return type
    }
    
    func resolve(identifier: IdentifierExpression, scope: Scope) throws -> AbstractTypeRecord {
        guard let type = scope.lookup(bindingForName: identifier.value) else {
            throw OrbitError(message: "Name '\(identifier.value)' not bound in current scope")
        }
        
        identifier.annotate(annotation: TypeAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(constructor: ConstructorCallExpression, scope: Scope) throws -> AbstractTypeRecord {
        let type = try self.resolve(typeId: constructor.receiver, scope: scope)
        
        let argTypes: [AbstractTypeRecord] = try constructor.args.map { arg in
            let value = try self.resolve(value: arg, scope: scope)
            
            (arg as! AbstractExpression).annotate(annotation: TypeAnnotation(typeRecord: value))
            
            return value
        }
        
        if let comp = type as? CompoundTypeRecord {
            // Type check parameters
            guard comp.memberTypes.count == argTypes.count else {
                throw OrbitError(message: "Constructor for type '\(comp.fullName)' expects \(comp.memberTypes.count) parameter(s), found \(constructor.args.count)")
            }
            
            // Ensure each param is expected type
            let zipped = zip(comp.memberTypes, argTypes)
            
            // TODO - Named parameters instead of positional
            try zipped.enumerated().forEach { item in
                guard TypeChecker.checkEquality(typeA: item.element.0, typeB: item.element.1) else {
                    throw OrbitError(message: "Expected parameter of type '\(item.element.0.fullName)' in constructor call at position \(item.offset)")
                }
            }
        }
        
        constructor.annotate(annotation: TypeAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(value: RValueExpression, scope: Scope) throws -> AbstractTypeRecord {
        switch value {
            case is IntLiteralExpression: return try resolve(intLiteral: value as! IntLiteralExpression)
            case is RealLiteralExpression: return try resolve(realLiteral: value as! RealLiteralExpression)
            case is IdentifierExpression: return try resolve(identifier: value as! IdentifierExpression, scope: scope)
            case is TypeIdentifierExpression: return try resolve(typeId: value as! TypeIdentifierExpression, scope: scope)
            case is StaticCallExpression: return try resolve(staticCall: value as! StaticCallExpression, scope: scope)
            case is UnaryExpression: return try resolve(unary: value as! UnaryExpression, scope: scope)
            case is BinaryExpression: return try resolve(binary: value as! BinaryExpression, scope: scope)
            case is AnnotationExpression: return try resolve(annotation: value as! AnnotationExpression, scope: scope)
            case is ListLiteralExpression: return try resolve(listLiteral: value as! ListLiteralExpression, scope: scope)
            case is ConstructorCallExpression: return try resolve(constructor: value as! ConstructorCallExpression, scope: scope)
            
            default: throw OrbitError(message: "Could not resolve type of expression: \(value)")
        }
    }
    
    func resolve(statement: AbstractExpression, scope: Scope) throws -> AbstractTypeRecord {
        switch statement {
            case is StaticCallExpression: return try resolve(staticCall: statement as! StaticCallExpression, scope: scope)
            case is AnnotationExpression: return try resolve(annotation: statement as! AnnotationExpression, scope: scope)
            case is AssignmentStatement: return try resolve(assignment: statement as! AssignmentStatement, scope: scope)
            
            default: throw OrbitError(message: "FATAL Unsupport statement \(statement)")
        }
    }
    
    func resolve(block: BlockExpression, scope: Scope) throws {
        try block.body.forEach {
            _ = try resolve(statement: ($0 as AbstractExpression), scope: scope)
        }
        
        guard let ret = block.returnStatement else {
            let annotation = TypeAnnotation(typeRecord: TypeRecord.unit)
            
            block.annotate(annotation: annotation)
            
            return
        }
        
        let retType = try resolve(value: ret.value as! RValueExpression, scope: scope)
        let annotation = TypeAnnotation(typeRecord: retType)
        
        ret.annotate(annotation: annotation)
        block.annotate(annotation: annotation)
    }
    
    func resolve(signature: StaticSignatureExpression, scope: Scope) throws -> SignatureTypeRecord {
        let rec = try resolve(typeId: signature.receiverType, scope: scope)
        var ret: AbstractTypeRecord? = nil
        
        if signature.returnType != nil {
            ret = try resolve(typeId: signature.returnType!, scope: scope)
        }
        
        let args = try signature.parameters.map { try resolve(pair: $0, scope: scope) }
        let type = SignatureTypeRecord(shortName: signature.name.value, receiver: rec, ret: ret, args: args)
        
        signature.annotate(annotation: TypeAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(method: MethodExpression, scope: Scope) throws {
        let sig = try resolve(signature: method.signature, scope: scope)
        let methodScope = Scope(parentScope: scope)
        
        let type = MethodTypeRecord(shortName: method.signature.name.value, signature: sig)
        
        scope.declare(type: type)
        
        method.signature.parameters.enumerated().forEach { (idx, pair) in
            methodScope.bind(name: pair.name.value, toType: sig.args[idx])
        }
        
        try resolve(block: method.body, scope: methodScope)
        
        method.annotate(annotation: TypeAnnotation(typeRecord: type))
    }
    
    func resolve(api: APIExpression, scope: Scope) throws {
        let qualifiedName: String
        
        if let within = api.within {
            qualifiedName = "\(within.apiRef.value).\(api.name.value)"
        } else {
            qualifiedName = api.name.value
        }
        
        let type = TypeRecord(shortName: api.name.value, fullName: qualifiedName)
        
        let typeDefs = api.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        try typeDefs.forEach { try resolve(typeDef: $0, scope: scope, apiName: qualifiedName) }
        
        let methods = api.body.filter { $0 is MethodExpression } as! [MethodExpression]
        try methods.forEach { try resolve(method: $0, scope: scope) }
        
        let annotations = api.body.filter { $0 is AnnotationExpression } as! [AnnotationExpression]
        try annotations.forEach { _ = try resolve(annotation: $0, scope: scope) }
        
        try annotations.forEach { ann in
            guard let ext = self.extensions[ann.annotationName.value] else { return }
            
            let result = try ext.execute(phase: self, annotation: ann)
            
            try api.rewriteChildExpression(childExpressionHash: ann.hashValue, input: result)
        }
        
        api.annotate(annotation: TypeAnnotation(typeRecord: type))
    }
    
    func resolve(annotation: AnnotationExpression, scope: Scope) throws -> AbstractTypeRecord {
        try annotation.parameters.forEach {
            try resolve(expression: $0, scope: scope)
        }
        
        annotation.annotate(annotation: ScopeAnnotation(scope: scope))
        
        return AbstractTypeRecord(shortName: "", fullName: "")
    }
    
    func resolve(expression: AbstractExpression, scope: Scope) throws {
        switch expression {
            case is MethodExpression: try resolve(method: expression as! MethodExpression, scope: scope)
            case is StaticSignatureExpression: _ = try resolve(signature: expression as! StaticSignatureExpression, scope: scope)
            case is BlockExpression: try resolve(block: expression as! BlockExpression, scope: scope)
            case is Statement: _ = try resolve(statement: expression, scope: scope)
            case is RValueExpression: _ = try resolve(value: expression as! RValueExpression, scope: scope)
            case is PairExpression: _ = try resolve(pair: expression as! PairExpression, scope: scope)
            case is TypeDefExpression: try resolve(typeDef: expression as! TypeDefExpression, scope: scope, apiName: "")
            case is APIExpression: try resolve(api: expression as! APIExpression, scope: scope)
            
            default: throw OrbitError(message: "FATAL Cannot resolve expression \(expression)")
        }
    }
    
    public func execute(input: (RootExpression, [APIMap])) throws -> RootExpression {
        let prog = input.0.body[0] as! ProgramExpression
        let apis = prog.apis
        
        let apiMap = APIMap.mergeAll(apis: input.1)
        
        try apis.forEach { api in
            let exports = (apiMap.exportedTypes as [AbstractTypeRecord]) + (apiMap.exportedMethods as [AbstractTypeRecord])
            
            try resolve(api: api, scope: Scope(parentScope: Scope.global, typeMap: exports))
        }
        
        return input.0
    }
}
