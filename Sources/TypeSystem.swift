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
}

public class UnitType : TypeProtocol {
    public let name: String
    
    public init(name: String) {
        self.name = name
    }
}

class ListType : UnitType {
    public let elementType: TypeProtocol
    
    public init(elementType: TypeProtocol) {
        self.elementType = elementType
        
        super.init(name: elementType.name)
    }
}

public protocol CompoundType : TypeProtocol {}

public struct SignatureType : CompoundType {
    public let receiverType: TypeProtocol
    public let argumentTypes: [TypeProtocol]
    public let returnType: TypeProtocol?
    public let name: String
    
    init(receiverType: TypeProtocol, argumentTypes: [TypeProtocol], returnType: TypeProtocol?) {
        self.receiverType = receiverType
        self.argumentTypes = argumentTypes
        self.returnType = returnType
        self.name = "(\(receiverType.name))(\(argumentTypes.map { $0.name }.joined(separator: ",")))(\(returnType?.name ?? ""))"
    }
}

public protocol StatementType : TypeProtocol {}

public struct TypeDefType : StatementType {
    public let name: String
    public let propertyTypes: [TypeProtocol]
}

public class Scope {
    public static let programScope = Scope(enclosingScope: nil)
    
    private(set) public var bindings: [String : TypeProtocol] = [:]
    
    public let enclosingScope: Scope!
    
    private init() {
        self.enclosingScope = Scope.programScope
    }
    
    public init(enclosingScope: Scope? = nil) {
        self.enclosingScope = enclosingScope
    }
    
    public func bind(name: String, type: TypeProtocol) throws {
        guard !self.bindings.keys.contains(name) else { throw OrbitError(message: "Attempting to redeclare \(name) as \(type.name)") }
        
        self.bindings[name] = type
    }
    
    public func lookupBinding(named: String) throws -> TypeProtocol {
        guard let type = self.bindings[named] else { throw OrbitError(message: "Binding '\(named)' does not exist in the current scope") }
        
        return type
    }
}

protocol ScopeAware {
    var scope: Scope { get }
}

public struct MethodType : StatementType, ScopeAware {
    public let name: String
    public let signatureType: SignatureType
    public let scope: Scope
    
    public init(name: String, signatureType: SignatureType, enclosingScope: Scope) {
        self.name = name
        self.signatureType = signatureType
        self.scope = Scope(enclosingScope: enclosingScope)
    }
}

public struct APIType : CompoundType, ScopeAware {
    public var exportableTypes: [TypeProtocol]
    public let name: String
    public let scope: Scope
    
    init(name: String, exportableTypes: [StatementType] = []) {
        self.name = name
        self.exportableTypes = exportableTypes
        self.scope = Scope(enclosingScope: Scope.programScope)
    }
    
    public func qualifyName(name: String) -> String {
        return "\(self.name)::\(name)"
    }
}

public struct ProgramType : CompoundType, ScopeAware {
    public let topLevelTypes: [TypeProtocol]
    public let name: String = "Program"
    public let scope = Scope.programScope
}

public struct VoidType : TypeProtocol {
    public var name: String = "Void"
}

public struct Anything : TypeProtocol {
    public static let shared = Anything()
    
    public var name: String = "Any"
}

public struct ValueType : TypeProtocol {
    public var name: String
    public let width: Int
}

/**
    This compilation phase traverses the AST and tags each expression with basic type info.
    A type map is created for this API and any imported APIs. When an expression resolves to a
    type, the compiler checks that the given type exists.
 */
public class TypeResolver : CompilationPhase {
    public typealias InputType = RootExpression
    public typealias OutputType = ProgramType
    
    var declaredTypes: [String : TypeProtocol] = [:]
    
    init() {
        self.declaredTypes["Orb::Core::Int"] = ValueType(name: "Orb::Core::Int", width: MemoryLayout<Int>.size)
        self.declaredTypes["Orb::Core::Real"] = ValueType(name: "Orb::Core::Real", width: MemoryLayout<Double>.size)
    }
    
    func declareType(name: String, type: TypeProtocol, enclosingAPI: APIType) throws {
        let qualifiedName = enclosingAPI.qualifyName(name: name)
        guard !self.declaredTypes.keys.contains(qualifiedName) else { throw OrbitError(message: "Attempting to redeclare type: \(name)") }
        
        self.declaredTypes[qualifiedName] = type
    }
    
    func lookupType(name: String, enclosingAPI: APIType) throws -> TypeProtocol {
        // TODO - Remove the special cases once imports & built-in types are working
        switch name {
            case "Int": return self.declaredTypes["Orb::Core::Int"]!
            case "Real": return self.declaredTypes["Orb::Core::Real"]!
            
            default:
                guard let type = self.declaredTypes[enclosingAPI.qualifyName(name: name)] else {
                    throw OrbitError(message: "Unknown type: \(name)")
                }
                
                return type
        }
    }
    
    func resolveTypeIdentifier(expr: TypeIdentifierExpression, enclosingAPI: APIType) throws -> TypeProtocol {
        let type = try self.lookupType(name: expr.value, enclosingAPI: enclosingAPI)
        
        guard expr.isList else { return type }
        
        return ListType(elementType: type)
    }
    
    func resolvePairType(expr: PairExpression, enclosingAPI: APIType) throws -> TypeProtocol {
        return try self.resolveTypeIdentifier(expr: expr.type, enclosingAPI: enclosingAPI)
    }
    
    func resolveTypeDefType(expr: TypeDefExpression, enclosingAPI: APIType) throws -> StatementType {
        let propertyTypes = try expr.properties.map { try self.resolvePairType(expr: $0, enclosingAPI: enclosingAPI) }
        
        let td = TypeDefType(name: expr.name.value, propertyTypes: propertyTypes)
        
        try self.declareType(name: expr.name.value, type: td, enclosingAPI: enclosingAPI)
        
        return td
    }
    
    func resolveInstanceCallType(expr: InstanceCallExpression, enclosingScope: ScopeAware) throws -> TypeProtocol {
        return try self.resolveCallType(expr: expr, receiver: expr.receiver, enclosingScope: enclosingScope)
    }
    
    func resolveStaticCallType(expr: StaticCallExpression, enclosingScope: ScopeAware) throws -> TypeProtocol {
        return try self.resolveCallType(expr: expr, receiver: expr.receiver, enclosingScope: enclosingScope)
    }
    
    func resolveCallType(expr: CallExpression, receiver: Expression, enclosingScope: ScopeAware) throws -> TypeProtocol {
        // Resolve the callee method's type
        guard let signatureType = try enclosingScope.scope.lookupBinding(named: expr.methodName.value) as? SignatureType else {
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
        
        return signatureType.returnType ?? VoidType()
    }
    
    func resolveListLiteralType(expr: ListExpression, enclosingScope: ScopeAware) throws -> ListType {
        // For now, we only have homogenous lists. When generics are working, we must revisit.
        // TODO - Redo with workign generics
        
        guard expr.value.count > 0 else {
            return ListType(elementType: Anything.shared)
        }
        
        // List element type is type of first element
        let elementType = try self.resolveValueType(expr: expr.value[0], enclosingScope: enclosingScope)
        
        try expr.value.forEach {
            let type = try self.resolveValueType(expr: $0, enclosingScope: enclosingScope)
            
            guard type == elementType else { throw OrbitError(message: "Type must be the same for every element of a list. Expected \(elementType.name), found \(type.name)") }
        }
        
        return ListType(elementType: elementType)
    }
    
    func resolveValueType(expr: Expression, enclosingScope: ScopeAware) throws -> TypeProtocol {
        switch expr {
            case is IntLiteralExpression: return self.declaredTypes["Orb::Core::Int"]! // TODO - This is gross! We can fix once imports are working
            case is RealLiteralExpression: return self.declaredTypes["Orb::Core::Real"]!
            case is IdentifierExpression: return try enclosingScope.scope.lookupBinding(named: (expr as! IdentifierExpression).value)
            case is InstanceCallExpression: return try resolveInstanceCallType(expr: expr as! InstanceCallExpression, enclosingScope: enclosingScope)
            case is StaticCallExpression: return try resolveStaticCallType(expr: expr as! StaticCallExpression, enclosingScope: enclosingScope)
            case is ListExpression: return try resolveListLiteralType(expr: expr as! ListExpression, enclosingScope: enclosingScope)
            
            // TODO - Other literals, property & indexed access
            
            default: throw OrbitError(message: "Could not resolve type of \(expr)")
        }
    }
    
    func resolveInstanceSignature(expr: InstanceSignatureExpression, enclosingAPI: APIType) throws -> SignatureType {
        let receiverType = try self.resolveTypeIdentifier(expr: expr.receiverType.type, enclosingAPI: enclosingAPI)
        let argumentTypes = try expr.parameters.map { $0.type }.map { try self.resolveTypeIdentifier(expr: $0, enclosingAPI: enclosingAPI) }
        
        guard let ret = expr.returnType else {
            return SignatureType(receiverType: receiverType, argumentTypes: argumentTypes, returnType: nil)
        }
        
        let returnType = try self.resolveTypeIdentifier(expr: ret, enclosingAPI: enclosingAPI)
        
        return SignatureType(receiverType: receiverType, argumentTypes: argumentTypes, returnType: returnType)
    }
    
    func resolveStaticSignature(expr: StaticSignatureExpression, enclosingAPI: APIType) throws -> SignatureType {
        let receiverType = try self.resolveTypeIdentifier(expr: expr.receiverType, enclosingAPI: enclosingAPI)
        let argumentTypes = try expr.parameters.map { $0.type }.map { try self.resolveTypeIdentifier(expr: $0, enclosingAPI: enclosingAPI) }
        
        guard let ret = expr.returnType else {
            return SignatureType(receiverType: receiverType, argumentTypes: argumentTypes, returnType: nil)
        }
        
        let returnType = try self.resolveTypeIdentifier(expr: ret, enclosingAPI: enclosingAPI)
        
        return SignatureType(receiverType: receiverType, argumentTypes: argumentTypes, returnType: returnType)
    }
    
    func resolveMethodType<T: SignatureExpression>(expr: MethodExpression<T>, enclosingAPI: APIType) throws -> MethodType {
        let signatureType = try (T.self == StaticSignatureExpression.self) ? self.resolveStaticSignature(expr: expr.signature as! StaticSignatureExpression, enclosingAPI: enclosingAPI) : self.resolveInstanceSignature(expr: expr.signature as! InstanceSignatureExpression, enclosingAPI: enclosingAPI)
        
        try enclosingAPI.scope.bind(name: expr.signature.name.value, type: signatureType)
        
        let method = MethodType(name: expr.signature.name.value, signatureType: signatureType, enclosingScope: enclosingAPI.scope)
        
        if let inst = expr.signature as? InstanceSignatureExpression {
            // Inject receiver as self binding into current scope
            try enclosingAPI.scope.bind(name: inst.receiverType.name.value, type: signatureType.receiverType)
        }
        
        for (idx, e) in expr.body.enumerated() {
            if let rt = signatureType.returnType, idx == expr.body.count - 1 {
                if let ret = e as? ReturnStatement {
                    let retType = try self.resolveValueType(expr: ret.value, enclosingScope: method)
                    
                    guard retType.name == rt.name else { throw OrbitError(message: "Method \(signatureType.name) should return a value of type \(rt.name), found \(retType.name)") }
                    
                    break
                }
            }
            
            _ = try self.resolveStatementType(expr: e, enclosingType: enclosingAPI)
        }
        
        return method
    }
    
    func resolveAssignmentType(expr: AssignmentStatement, enclosingMethod: MethodType) throws -> TypeProtocol {
        let rhsType = try self.resolveValueType(expr: expr.value, enclosingScope: enclosingMethod)
        
        try enclosingMethod.scope.bind(name: expr.name.value, type: rhsType)
        
        return rhsType
    }
    
    func resolveStatementType(expr: Expression, enclosingType: TypeProtocol & ScopeAware) throws -> TypeProtocol {
        switch expr {
            case is TypeDefExpression: return try self.resolveTypeDefType(expr: expr as! TypeDefExpression, enclosingAPI: enclosingType as! APIType)
            
            case is MethodExpression<InstanceSignatureExpression>: return try self.resolveMethodType(expr: expr as! MethodExpression<InstanceSignatureExpression>, enclosingAPI: enclosingType as! APIType)
            
            case is MethodExpression<StaticSignatureExpression>: return try self.resolveMethodType(expr: expr as! MethodExpression<StaticSignatureExpression>, enclosingAPI: enclosingType as! APIType)
            
            case is AssignmentStatement: return try self.resolveAssignmentType(expr: expr as! AssignmentStatement, enclosingMethod: enclosingType as! MethodType)
            
            case is InstanceCallExpression: return try self.resolveInstanceCallType(expr: expr as! InstanceCallExpression, enclosingScope: enclosingType)
            case is StaticCallExpression: return try self.resolveStaticCallType(expr: expr as! StaticCallExpression, enclosingScope: enclosingType)
            
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
    
    public func execute(input: RootExpression) throws -> ProgramType {
        var topLevelTypes: [TypeProtocol] = []
        for expr in input.body {
            let type = try self.resolveTopLevelType(expr: expr)
            
            topLevelTypes.append(type)
        }
        
        return ProgramType(topLevelTypes: topLevelTypes)
    }
}
