//
//  TypeSystem.swift
//  OrbitBackend
//
//  Created by Davie Janeway on 05/07/2017.
//
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend
import LLVM

extension OrbitError {
    static func unresolvableExpression(expression: Expression) -> OrbitError {
        return OrbitError(message: "Could not resolve type of expression: \(expression)")
    }
}

func ==(lhs: TypeProtocol, rhs: TypeProtocol) -> Bool {
    return lhs.name == rhs.name && type(of: lhs) == type(of: rhs)
}

public protocol TypeProtocol {
    var name: String { get }
    var scope: Scope { get }
}

extension TypeProtocol {
    
    func absoluteName() throws -> String {
        return try self.scope.absolutise(relativeName: self.name)
    }
    
    func fullName() throws -> Name {
        return try Name(relativeName: self.name, absoluteName: self.absoluteName())
    }
}

extension Expression {
    func assignType(type: TypeProtocol, env: TypeResolver) {
        env.expressionTypeMap[self.hashValue] = type
    }
}

public class UnitType : TypeProtocol {
    public let name: String
    public let scope: Scope
    
    public init(name: String, scope: Scope) {
        self.name = name
        self.scope = scope
    }
}

class ListType : UnitType {
    public let elementType: TypeProtocol
    
    public init(elementType: TypeProtocol, scope: Scope) {
        self.elementType = elementType
        
        super.init(name: elementType.name, scope: scope)
    }
}

public protocol CompoundType : TypeProtocol {}

public struct SignatureType : CompoundType {
    public let receiverType: TypeProtocol
    public let argumentTypes: [TypeProtocol]
    public let returnType: TypeProtocol?
    public let name: String
    public let scope: Scope
    
    init(receiverType: TypeProtocol, argumentTypes: [TypeProtocol], returnType: TypeProtocol?, scope: Scope) {
        self.receiverType = receiverType
        self.argumentTypes = argumentTypes
        self.returnType = returnType
        self.name = "(\(receiverType.name))(\(argumentTypes.map { $0.name }.joined(separator: ",")))(\(returnType?.name ?? ""))"
        self.scope = scope
    }
}

public struct BinaryOperatorType : CompoundType {
    public let leftType: TypeProtocol
    public let rightType: TypeProtocol
    public let op: Operator
    public let scope: Scope
    public let name: String
    
    init(leftType: TypeProtocol, rightType: TypeProtocol, op: Operator, scope: Scope) {
        self.leftType = leftType
        self.rightType = rightType
        self.op = op
        self.scope = scope
        self.name = op.symbol
    }
}

public protocol StatementType : TypeProtocol {}

public struct TypeDefType : StatementType {
    public let name: String
    public let propertyTypes: [TypeProtocol]
    public let scope: Scope
}

public enum ScopeType {
    case TopLevel
    case API(apiName: String)
    case Method
}

public class Scope {
    public static let programScope = Scope(enclosingScope: nil, scopeType: .TopLevel)
    
    private(set) public var bindings: [String : TypeProtocol] = [:]
    private(set) public var variables: [String : IRBinding] = [:]
    
    public var enclosingScope: Scope?
    public let scopeType: ScopeType
    
    private init() {
        self.enclosingScope = Scope.programScope
        self.scopeType = .TopLevel
    }
    
    public init(enclosingScope: Scope? = nil, scopeType: ScopeType) {
        self.enclosingScope = enclosingScope
        self.scopeType = scopeType
    }
    
    public func absolutise(relativeName: String) throws -> String {
        if case let ScopeType.API(apiName) = self.scopeType {
            return "\(Mangler.mangle(name: apiName)).\(relativeName)"
        }
        
        guard let parent = self.enclosingScope else {
            return relativeName
        }
        
        return try parent.absolutise(relativeName: relativeName)
    }
    
    public func bind(name: String, type: TypeProtocol) throws {
        guard !self.bindings.keys.contains(name) else { throw OrbitError(message: "Attempting to redeclare \(name) as \(type.name)") }
        
        self.bindings[name] = type
    }
    
    public func defineVariable(named: String, binding: IRBinding) throws {
        guard !self.variables.keys.contains(named) else { throw OrbitError(message: "Attempting to redefine variable \(named)") }
        
        self.variables[named] = binding
    }
    
    public func lookupBinding(named: String) throws -> TypeProtocol {
        guard let type = self.bindings[named] else { throw OrbitError(message: "Binding '\(named)' does not exist in the current scope") }
        
        return type
    }
    
    public func lookupVariable(named: String) throws -> IRBinding {
        guard let variable = self.variables[named] else { throw OrbitError(message: "Variable '\(named)' does not exist in the current scope") }
        
        return variable
    }
}

public struct MethodType : StatementType {
    public let name: String
    public let signatureType: SignatureType
    public let scope: Scope
    
    public init(name: String, signatureType: SignatureType, enclosingScope: Scope) {
        self.name = name
        self.signatureType = signatureType
        self.scope = Scope(enclosingScope: enclosingScope, scopeType: .Method)
    }
}

public struct APIType : CompoundType {
    public var exportableTypes: [TypeProtocol]
    public let name: String
    public let scope: Scope
    
    init(name: String, exportableTypes: [StatementType] = []) {
        self.name = name
        self.exportableTypes = exportableTypes
        self.scope = Scope(enclosingScope: Scope.programScope, scopeType: .API(apiName: name))
    }
    
    public func qualifyName(name: String) -> String {
        return "\(self.name)::\(name)"
    }
}

public struct ProgramType : CompoundType {
    public let topLevelTypes: [TypeProtocol]
    public let name: String = "Program"
    public let scope = Scope.programScope
}

public struct VoidType : TypeProtocol {
    public var name: String = "Void"
    public let scope: Scope
}

public struct Anything : TypeProtocol {
    public static let shared = Anything(name: "Any", scope: Scope.programScope)
    
    public var name: String = "Any"
    public let scope: Scope
}

public struct ValueType : TypeProtocol {
    public static let IntType = ValueType(name: "Int", width: MemoryLayout<Int>.size * 8, scope: Scope.programScope)
    public static let RealType = ValueType(name: "Real", width: MemoryLayout<Double>.size * 8, scope: Scope.programScope)
    
    public var name: String
    public let width: Int
    public let scope: Scope
}

/**
    This compilation phase traverses the AST and tags each expression with basic type info.
    A type map is created for this API and any imported APIs. When an expression resolves to a
    type, the compiler checks that the given type exists.
 */
public class TypeResolver : CompilationPhase {
    public typealias InputType = RootExpression
    public typealias OutputType = [Int : TypeProtocol]
    
    private(set) var declaredTypes: [String : TypeProtocol] = [:]
    private(set) var declaredOperatorTypes: [String : TypeProtocol] = [:] // operator name against its return type
    var expressionTypeMap : [Int : TypeProtocol] = [:]
    
    
    init() {
        self.declaredTypes["Int"] = ValueType.IntType
        self.declaredTypes["Real"] = ValueType.RealType
        
        self.declaredOperatorTypes["Int.+.Int"] = ValueType.IntType
    }
    
    func declareType(name: String, type: TypeProtocol, enclosingAPI: APIType) throws {
        let qualifiedName = enclosingAPI.qualifyName(name: name)
        guard !self.declaredTypes.keys.contains(qualifiedName) else { throw OrbitError(message: "Attempting to redeclare type: \(name)") }
        
        self.declaredTypes[qualifiedName] = type
    }
    
    func lookupType(name: String, enclosingAPI: APIType) throws -> TypeProtocol {
        // TODO - Remove the special cases once imports & built-in types are working
        switch name {
            case "Int": return self.declaredTypes["Int"]!
            case "Real": return self.declaredTypes["Real"]!
            
            default:
                guard let type = self.declaredTypes[enclosingAPI.qualifyName(name: name)] else {
                    throw OrbitError(message: "Unknown type: \(name)")
                }
                
                return type
        }
    }
    
    func resolveTypeIdentifier(expr: TypeIdentifierExpression, enclosingAPI: APIType) throws -> TypeProtocol {
        let type = try self.lookupType(name: expr.value, enclosingAPI: enclosingAPI)
        
        guard expr.isList else {
            expr.assignType(type: type, env: self)
            return type
        }
        
        let listType = ListType(elementType: type, scope: enclosingAPI.scope)
        
        expr.assignType(type: listType, env: self)
        
        return listType
    }
    
    func resolvePairType(expr: PairExpression, enclosingAPI: APIType) throws -> TypeProtocol {
        let type = try self.resolveTypeIdentifier(expr: expr.type, enclosingAPI: enclosingAPI)
        
        expr.name.assignType(type: type, env: self)
        
        return type
    }
    
    func resolveTypeDefType(expr: TypeDefExpression, enclosingAPI: APIType) throws -> StatementType {
        let propertyTypes = try expr.properties.map { try self.resolvePairType(expr: $0, enclosingAPI: enclosingAPI) }
        
        let td = TypeDefType(name: expr.name.value, propertyTypes: propertyTypes, scope: enclosingAPI.scope)
        
        try self.declareType(name: expr.name.value, type: td, enclosingAPI: enclosingAPI)
        
        expr.assignType(type: td, env: self)
        
        return td
    }
    
    func resolveInstanceCallType(expr: InstanceCallExpression, enclosingScope: Scope) throws -> TypeProtocol {
        return try self.resolveCallType(expr: expr, receiver: expr.receiver, enclosingScope: enclosingScope)
    }
    
    func resolveStaticCallType(expr: StaticCallExpression, enclosingScope: Scope) throws -> TypeProtocol {
        return try self.resolveCallType(expr: expr, receiver: expr.receiver, enclosingScope: enclosingScope)
    }
    
    func resolveCallType(expr: CallExpression, receiver: Expression, enclosingScope: Scope) throws -> TypeProtocol {
        // Resolve the callee method's type
        guard let signatureType = try enclosingScope.lookupBinding(named: expr.methodName.value) as? SignatureType else {
            throw OrbitError(message: "Call expressions are not permitted outside of method body")
        }
        
        let argTypes = try expr.args.map { try self.resolveValueType(expr: $0, enclosingScope: enclosingScope) }
        let expectedArgs = signatureType.argumentTypes
        
        // 1st check: Does the receiver type match the type of the actual receiver
        let actualReceiverType = try self.resolveValueType(expr: receiver, enclosingScope: enclosingScope)
        
        // TODO - There's probably a better way to say this!
        guard actualReceiverType == signatureType.receiverType else { throw OrbitError(message: "Method \(signatureType.name) does not belong to type \(actualReceiverType.name)") }
        
        // 2nd check: have we received the correct number of args
        guard argTypes.count == expectedArgs.count else { throw OrbitError(message: "'\(signatureType.name)' expects \(expectedArgs.count) arguments, found \(argTypes.count)") }
        
        // 3rd check: are the args in the correct order (by type only, not name)
        _ = try zip(expectedArgs, argTypes).forEach { (l, r) in
            guard l == r else {
                throw OrbitError(message: "'\(signatureType.name)' expectd argument of \(l.name), found \(r.name)")
            }
        }
        
        /*
            This is about as much as we can check for now.
            When type annotations are added on the lhs of assignments,
            we can check the rhs return type against the lhs expected type.
         */
        
        let type = signatureType.returnType ?? VoidType(name: "Void", scope: enclosingScope)
        
        expr.assignType(type: type, env: self)
        
        return type
    }
    
    func resolveListLiteralType(expr: ListExpression, enclosingScope: Scope) throws -> ListType {
        // For now, we only have homogenous lists. When generics are working, we must revisit.
        // TODO - Redo with working generics
        
        guard expr.value.count > 0 else {
            let type = ListType(elementType: Anything.shared, scope: enclosingScope)
            
            expr.assignType(type: type, env: self)
            
            return type
        }
        
        // List element type is type of first element
        let elementType = try self.resolveValueType(expr: expr.value[0], enclosingScope: enclosingScope)
        
        try expr.value.forEach {
            let type = try self.resolveValueType(expr: $0, enclosingScope: enclosingScope)
            
            guard type == elementType else { throw OrbitError(message: "Type must be the same for every element of a list. Expected \(elementType.name), found \(type.name)") }
        }
        
        let type = ListType(elementType: elementType, scope: enclosingScope)
        
        expr.assignType(type: type, env: self)
        
        return type
    }
    
    func resolveBinaryExpression(expr: BinaryExpression, enclosingScope: Scope) throws -> TypeProtocol {
        let leftType = try resolveValueType(expr: expr.left, enclosingScope: enclosingScope)
        let rightType = try resolveValueType(expr: expr.right, enclosingScope: enclosingScope)
        
        let fullName = "\(leftType.name).\(expr.op.symbol).\(rightType.name)"
        
        guard let retType = self.declaredOperatorTypes[fullName] else { throw OrbitError(message: "Operator '\(fullName)' does not exist") }
        
        return retType
    }
    
    func resolveValueType(expr: Expression, enclosingScope: Scope) throws -> TypeProtocol {
        switch expr {
            case is IntLiteralExpression: return self.declaredTypes["Int"]! // TODO - This is gross! We can fix once imports are working
            case is RealLiteralExpression: return self.declaredTypes["Real"]!
            case is IdentifierExpression: return try enclosingScope.lookupBinding(named: (expr as! IdentifierExpression).value)
            case is InstanceCallExpression: return try resolveInstanceCallType(expr: expr as! InstanceCallExpression, enclosingScope: enclosingScope)
            case is StaticCallExpression: return try resolveStaticCallType(expr: expr as! StaticCallExpression, enclosingScope: enclosingScope)
            case is ListExpression: return try resolveListLiteralType(expr: expr as! ListExpression, enclosingScope: enclosingScope)
            case is BinaryExpression: return try resolveBinaryExpression(expr: expr as! BinaryExpression, enclosingScope: enclosingScope)
            
            // TODO - Other literals, property & indexed access
            
            default: throw OrbitError(message: "Could not resolve type of \(expr)")
        }
    }
    
    func resolveInstanceSignature(expr: InstanceSignatureExpression, enclosingAPI: APIType) throws -> SignatureType {
        let receiverType = try self.resolveTypeIdentifier(expr: expr.receiverType.type, enclosingAPI: enclosingAPI)
        let argumentTypes = try expr.parameters.map { $0.type }.map { try self.resolveTypeIdentifier(expr: $0, enclosingAPI: enclosingAPI) }
        
        guard let ret = expr.returnType else {
            let type = SignatureType(receiverType: receiverType, argumentTypes: argumentTypes, returnType: nil, scope: enclosingAPI.scope)
            
            expr.assignType(type: type, env: self)
            
            return type
        }
        
        let returnType = try self.resolveTypeIdentifier(expr: ret, enclosingAPI: enclosingAPI)
        
        let type = SignatureType(receiverType: receiverType, argumentTypes: argumentTypes, returnType: returnType, scope: enclosingAPI.scope)
        
        expr.assignType(type: type, env: self)
        
        return type
    }
    
    func resolveStaticSignature(expr: StaticSignatureExpression, enclosingAPI: APIType) throws -> SignatureType {
        let receiverType = try self.resolveTypeIdentifier(expr: expr.receiverType, enclosingAPI: enclosingAPI)
        let argumentTypes = try expr.parameters.map { $0.type }.map { try self.resolveTypeIdentifier(expr: $0, enclosingAPI: enclosingAPI) }
        
        guard let ret = expr.returnType else {
            let type = SignatureType(receiverType: receiverType, argumentTypes: argumentTypes, returnType: nil, scope: enclosingAPI.scope)
            
            expr.assignType(type: type, env: self)
            
            return type
        }
        
        let returnType = try self.resolveTypeIdentifier(expr: ret, enclosingAPI: enclosingAPI)
        
        let type = SignatureType(receiverType: receiverType, argumentTypes: argumentTypes, returnType: returnType, scope: enclosingAPI.scope)
        
        expr.assignType(type: type, env: self)
        
        return type
    }
    
    func resolveMethodType<T: SignatureExpression>(expr: MethodExpression<T>, enclosingAPI: APIType) throws -> MethodType {
        let signatureType = try (T.self == StaticSignatureExpression.self) ? self.resolveStaticSignature(expr: expr.signature as! StaticSignatureExpression, enclosingAPI: enclosingAPI) : self.resolveInstanceSignature(expr: expr.signature as! InstanceSignatureExpression, enclosingAPI: enclosingAPI)
        
        try enclosingAPI.scope.bind(name: expr.signature.name.value, type: signatureType)
        
        let method = MethodType(name: expr.signature.name.value, signatureType: signatureType, enclosingScope: enclosingAPI.scope)
        
        expr.assignType(type: method, env: self)
        
        if let inst = expr.signature as? InstanceSignatureExpression {
            // Inject receiver as self binding into current scope
            try method.scope.bind(name: inst.receiverType.name.value, type: signatureType.receiverType)
        }
        
        // Inject bindings for remaining args
        for arg in expr.signature.parameters {
            let type = try self.resolveTypeIdentifier(expr: arg.type, enclosingAPI: enclosingAPI)
            try method.scope.bind(name: arg.name.value, type: type)
            
            arg.assignType(type: type, env: self)
        }
        
        for (idx, e) in expr.body.enumerated() {
            if let rt = signatureType.returnType, idx == expr.body.count - 1 {
                if let ret = e as? ReturnStatement {
                    let retType = try self.resolveValueType(expr: ret.value, enclosingScope: method.scope)
                    
                    guard retType.name == rt.name else {
                        throw OrbitError(message: "Method \(signatureType.name) should return a value of type \(rt.name), found \(retType.name)")
                    }
                    
                    ret.assignType(type: retType, env: self)
                    
                    break
                }
            }
            
            _ = try self.resolveStatementType(expr: e, enclosingType: enclosingAPI)
        }
        
        return method
    }
    
    func resolveAssignmentType(expr: AssignmentStatement, enclosingMethod: MethodType) throws -> TypeProtocol {
        let rhsType = try self.resolveValueType(expr: expr.value, enclosingScope: enclosingMethod.scope)
        
        try enclosingMethod.scope.bind(name: expr.name.value, type: rhsType)
        
        expr.assignType(type: rhsType, env: self)
        
        return rhsType
    }
    
    func resolveStatementType(expr: Expression, enclosingType: TypeProtocol) throws -> TypeProtocol {
        switch expr {
            case is TypeDefExpression: return try self.resolveTypeDefType(expr: expr as! TypeDefExpression, enclosingAPI: enclosingType as! APIType)
            
            case is MethodExpression<InstanceSignatureExpression>: return try self.resolveMethodType(expr: expr as! MethodExpression<InstanceSignatureExpression>, enclosingAPI: enclosingType as! APIType)
            
            case is MethodExpression<StaticSignatureExpression>: return try self.resolveMethodType(expr: expr as! MethodExpression<StaticSignatureExpression>, enclosingAPI: enclosingType as! APIType)
            
            case is AssignmentStatement: return try self.resolveAssignmentType(expr: expr as! AssignmentStatement, enclosingMethod: enclosingType as! MethodType)
            
            case is InstanceCallExpression: return try self.resolveInstanceCallType(expr: expr as! InstanceCallExpression, enclosingScope: enclosingType.scope)
            case is StaticCallExpression: return try self.resolveStaticCallType(expr: expr as! StaticCallExpression, enclosingScope: enclosingType.scope)
            
            default: throw OrbitError.unresolvableExpression(expression: expr)
        }
    }
    
    func resolveAPIType(expr: APIExpression) throws -> TypeProtocol {
        var api = APIType(name: expr.name.value, exportableTypes: [])
        
        var exportableTypes: [TypeProtocol] = []
        for e in expr.body {
            let type = try self.resolveStatementType(expr: e as! ExportableExpression, enclosingType: api)
            
            exportableTypes.append(type)
        }
        
        api.exportableTypes = exportableTypes
        
        return api
    }
    
    func resolveTopLevelType(expr: TopLevelExpression) throws -> TypeProtocol {
        switch expr {
            case is APIExpression: return try self.resolveAPIType(expr: expr as! APIExpression)
            
            default: throw OrbitError.unresolvableExpression(expression: expr)
        }
    }
    
    public func execute(input: RootExpression) throws -> [Int : TypeProtocol] {
        var topLevelTypes: [TypeProtocol] = []
        for expr in input.body {
            let type = try self.resolveTopLevelType(expr: expr)
            
            topLevelTypes.append(type)
        }
        
        return self.expressionTypeMap
    }
}
