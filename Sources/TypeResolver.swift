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

public class AbstractTypeRecord : Equatable {
    public let shortName: String
    public let fullName: String
    
    public init(shortName: String, fullName: String) {
        self.shortName = shortName
        self.fullName = fullName
    }
    
    public static func ==(lhs: AbstractTypeRecord, rhs: AbstractTypeRecord) -> Bool {
        return lhs.shortName == rhs.shortName || lhs.fullName == rhs.fullName
    }
}

public class TypeRecord : AbstractTypeRecord {
    // TODO: All of these boostrap types should be defined by the CallingConvention
    static let unit = TypeRecord(shortName: "()", fullName: "Orb.Core.Types.Unit")
    static let int = TypeRecord(shortName: "Int", fullName: "Orb.Core.Types.Int")
    static let real = TypeRecord(shortName: "Real", fullName: "Orb.Core.Types.Real")
    static let op = TypeRecord(shortName: "Operator", fullName: "Orb.Core.Types.Operator")
}

public class ListTypeRecord : AbstractTypeRecord {
    public override init(shortName: String, fullName: String) {
        super.init(shortName: "[\(shortName)]", fullName: "[\(fullName)]")
    }
}

public class SignatureTypeRecord : AbstractTypeRecord {
    static let intPrefixPlus = SignatureTypeRecord(shortName: "+", receiver: TypeRecord.op, ret: TypeRecord.int, args: [TypeRecord.int])
    
    static let intInfixPlus = SignatureTypeRecord(shortName: "+", receiver: TypeRecord.op, ret: TypeRecord.int, args: [TypeRecord.int, TypeRecord.int])
    
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
}

public class MethodTypeRecord : AbstractTypeRecord {
    static let intPrefixPlus = MethodTypeRecord(shortName: "+", signature: SignatureTypeRecord.intPrefixPlus)
    static let intInfixPlus = MethodTypeRecord(shortName: "+", signature: SignatureTypeRecord.intInfixPlus)
    
    public let signature: SignatureTypeRecord
    
    public init(shortName: String, signature: SignatureTypeRecord) {
        self.signature = signature
        
        super.init(shortName: shortName, fullName: signature.fullName)
    }
}

public struct TypeRecordAnnotation : DebuggableAnnotation {
    public let typeRecord: AbstractTypeRecord
    
    public func dump() -> String {
        return "@Type -> \(self.typeRecord.fullName)"
    }
}

public struct ScopeAnnotation : DebuggableAnnotation {
    public let scope: Scope
    
    public func dump() -> String {
        return "@Scope -> \(self.scope)"
    }
}

public class TypeExtractor : CompilationPhase {
    public typealias InputType = RootExpression
    public typealias OutputType = [TypeRecord]
    
    public let session: OrbitSession
    
    private var types = [TypeRecord]()
    
    public required init(session: OrbitSession) {
        self.session = session
    }
    
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

public class Scope {
    private(set) static var global: Scope? = nil
    private static var typeMap = [AbstractTypeRecord]()
    
    private let parentScope: Scope?
    private var bindings = [String : AbstractTypeRecord]()
    
    private init() {
        self.parentScope = nil
    }
    
    init(parentScope: Scope) {
        self.parentScope = parentScope
    }
    
    func declare(type: AbstractTypeRecord) {
        Scope.typeMap.append(type)
    }
    
    func bind(name: String, toType: AbstractTypeRecord) {
        self.bindings[name] = toType
    }
    
    func lookup(bindingForName name: String) -> AbstractTypeRecord? {
        // If the name isn't bound in the current scope, go up the chain
        return self.bindings[name] ?? self.parentScope?.lookup(bindingForName: name)
    }
    
    func findType(named: String, customError: OrbitError? = nil) throws -> AbstractTypeRecord {
        let types = Scope.typeMap.filter { $0.fullName == named || $0.shortName == named }
        
        guard types.count > 0 else {
            throw customError ?? OrbitError(message: "Unknown type: \(named)")
        }
        
        guard types.count < 2 else {
            throw OrbitError(message: "Multiple types named \(named)")
        }
        
        return types[0]
    }
    
    static func initGlobalScope(typeMap: [TypeRecord]) {
        self.global = Scope()
        Scope.typeMap = typeMap
    }
}

public class TypeResolver : CompilationPhase {
    public typealias InputType = (RootExpression, [TypeRecord])
    public typealias OutputType = RootExpression
    
    public let session: OrbitSession
    
    public required init(session: OrbitSession) {
        self.session = session
    }
    
    func resolve(typeId: TypeIdentifierExpression, scope: Scope) throws -> AbstractTypeRecord {
        var type: AbstractTypeRecord = try scope.findType(named: typeId.value)
        
        if typeId is ListTypeIdentifierExpression {
            type = ListTypeRecord(shortName: type.shortName, fullName: type.fullName)
        }
        
        typeId.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(pair: PairExpression, scope: Scope) throws -> AbstractTypeRecord {
        let type = try scope.findType(named: pair.type.value)
        let annotation = TypeRecordAnnotation(typeRecord: type)
        
        pair.type.annotate(annotation: annotation)
        pair.name.annotate(annotation: annotation)
        pair.annotate(annotation: annotation)
        
        return type
    }
    
    func resolve(typeDef: TypeDefExpression, scope: Scope) throws {
        let type = try scope.findType(named: typeDef.name.value)
        
        typeDef.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
        
        try typeDef.properties.forEach { pair in
            _ = try resolve(pair: pair, scope: scope)
        }
    }
    
    func resolve(intLiteral: IntLiteralExpression) throws -> AbstractTypeRecord {
        // TODO: The fundamental types should be defined in the CallingConvention,
        // which should be passed through to this phase
        return TypeRecord.int
    }
    
    func resolve(realLiteral: RealLiteralExpression) throws -> AbstractTypeRecord {
        return TypeRecord.real
    }
    
    func resolve(unary: UnaryExpression, scope: Scope) throws -> AbstractTypeRecord {
        let valueType = try resolve(value: unary.value as! RValueExpression, scope: scope)
        // Rewrite as static call. e.g. -1 = Int.-.Int
        let opFuncName = "\(valueType.fullName).\(unary.op.symbol).\(valueType.fullName)"
        
        // TODO: This is actually a form of type checking. Error message should be more useful
        let error = OrbitError(message: "Prefix Operator function '\(unary.op.symbol)' is not defined with parameter type '\(valueType.fullName)'")
        let opFunc = try scope.findType(named: opFuncName, customError: error) as! MethodTypeRecord
        
        let type = opFunc.signature.ret
        
        unary.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(binary: BinaryExpression, scope: Scope) throws -> AbstractTypeRecord {
        let leftType = try resolve(value: binary.left as! RValueExpression, scope: scope)
        let rightType = try resolve(value: binary.right as! RValueExpression, scope: scope)
        
        let opFuncName = "\(TypeRecord.op.fullName).\(binary.op.symbol).\(leftType.fullName).\(rightType.fullName)"
        let error = OrbitError(message: "Infix Operator function '\(binary.op.symbol)' is not defined with parameter types (\(leftType.fullName), \(rightType.fullName))")
        let opFunc = try scope.findType(named: opFuncName, customError: error) as! MethodTypeRecord
        
        let type = opFunc.signature.ret
        
        binary.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(staticCall: StaticCallExpression, scope: Scope) throws -> AbstractTypeRecord {
        let receiver = try resolve(typeId: staticCall.receiver, scope: scope)
        let args = try staticCall.args.map { try resolve(value: $0, scope: scope).fullName }
        let fname = "\(receiver.fullName).\(staticCall.methodName.value).\(args.joined(separator: "."))"
        
        let error = OrbitError(message: "Method '\(fname)' not declared in current scope")
        let fn = try scope.findType(named: fname, customError: error) as! MethodTypeRecord
        
        let annotation = TypeRecordAnnotation(typeRecord: fn.signature.ret)
        
        staticCall.annotate(annotation: annotation)
        staticCall.methodName.annotate(annotation: annotation)
        
        return fn.signature.ret
    }
    
    func resolve(identifier: IdentifierExpression, scope: Scope) throws -> AbstractTypeRecord {
        guard let type = scope.lookup(bindingForName: identifier.value) else {
            throw OrbitError(message: "Name '\(identifier.value)' not bound in current scope")
        }
        
        identifier.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
        
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
            
            default: throw OrbitError(message: "Could not resolve type of expression: \(value)")
        }
    }
    
    func resolve(block: BlockExpression, scope: Scope) throws {
        guard let ret = block.returnStatement else {
            let annotation = TypeRecordAnnotation(typeRecord: TypeRecord.unit)
            
            block.annotate(annotation: annotation)
            
            return
        }
        
        let retType = try resolve(value: ret.value as! RValueExpression, scope: scope)
        let annotation = TypeRecordAnnotation(typeRecord: retType)
        
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
        
        signature.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
        
        return type
    }
    
    func resolve(method: MethodExpression, scope: Scope) throws {
        let sig = try resolve(signature: method.signature, scope: scope)
        let methodScope = Scope(parentScope: scope)
        
        let type = MethodTypeRecord(shortName: method.signature.name.value, signature: sig)
        
        scope.declare(type: type)
        //scope.bind(name: type.fullName, toType: type)
        
        method.signature.parameters.enumerated().forEach { (idx, pair) in
            methodScope.bind(name: pair.name.value, toType: sig.args[idx])
        }
        
        try resolve(block: method.body, scope: methodScope)
        
        method.annotate(annotation: TypeRecordAnnotation(typeRecord: type))
    }
    
    func resolve(api: APIExpression, scope: Scope) throws {
        let typeDefs = api.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        try typeDefs.forEach { try resolve(typeDef: $0, scope: scope) }
        
        let methods = api.body.filter { $0 is MethodExpression } as! [MethodExpression]
        try methods.forEach { try resolve(method: $0, scope: scope) }
    }
    
    public func execute(input: (RootExpression, [TypeRecord])) throws -> RootExpression {
        let prog = input.0.body[0] as! ProgramExpression
        let apis = prog.apis
        
        Scope.initGlobalScope(typeMap: input.1)
        
        Scope.global?.declare(type: TypeRecord.unit)
        Scope.global?.declare(type: TypeRecord.int)
        Scope.global?.declare(type: TypeRecord.real)
        Scope.global?.declare(type: TypeRecord.op)
        Scope.global?.declare(type: TypeRecord.unit)
        
        Scope.global?.declare(type: MethodTypeRecord.intInfixPlus)
        Scope.global?.declare(type: MethodTypeRecord.intPrefixPlus)
        
        try apis.forEach { try resolve(api: $0, scope: Scope.global!) }
        
        return input.0
    }
}
