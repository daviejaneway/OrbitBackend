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

extension Dictionary {
    public init(keyValuePairs: [(Key, Value)]) {
        self.init()
        for pair in keyValuePairs {
            self[pair.0] = pair.1
        }
    }
}

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

protocol CollectionType : CompoundType {
    var elementType: TypeProtocol { get }
}

class ListType : CollectionType {
    public let elementType: TypeProtocol
    public let size: Int
    
    public let name: String
    public let scope: Scope
    
    public init(elementType: TypeProtocol, size: Int, scope: Scope) {
        self.elementType = elementType
        self.size = size
        self.name = elementType.name
        self.scope = scope
        
        //super.init(name: elementType.name, scope: scope)
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
    public let propertyTypes: [String : TypeProtocol]
    public let propertyOrder: [String : Int]
    public var constructorTypes: [SignatureType]
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
        guard let type = self.bindings[named] else {
            throw OrbitError(message: "Binding '\(named)' does not exist in the current scope")
        }
        
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
    public let enclosingAPI: APIType
    
    public init(name: String, signatureType: SignatureType, enclosingAPI: APIType, enclosingScope: Scope) {
        self.name = name
        self.signatureType = signatureType
        self.enclosingAPI = enclosingAPI
        self.scope = Scope(enclosingScope: enclosingScope, scopeType: .Method)
    }
}

public struct APIType : CompoundType {
    public static let Base = APIType(name: "__Base__")
    
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

public struct PropertyAccessType : CompoundType {
    public let name: String = "PropertyAccess"
    
    public let receiverType: TypeDefType
    public let propertyType: TypeProtocol
    
    public let scope: Scope
}

public struct IndexAccessType : CompoundType {
    public let name: String = "IndexAccess"
    
    public let receiverType: TypeProtocol
    public let indexTypes: [TypeProtocol]
    public let elementType: TypeProtocol
    
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
    
    private var currentAPI: APIType = APIType.Base
    
    public init() {
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
        
        // TODO - Array size in type e.g. `[Int, 2]`
        let listType = ListType(elementType: type, size: 0, scope: enclosingAPI.scope)
        
        expr.assignType(type: listType, env: self)
        
        return listType
    }
    
    func resolvePairType(expr: PairExpression, enclosingAPI: APIType) throws -> TypeProtocol {
        let type = try self.resolveTypeIdentifier(expr: expr.type, enclosingAPI: enclosingAPI)
        
        expr.name.assignType(type: type, env: self)
        
        return type
    }
    
    func resolveTypeDefType(expr: TypeDefExpression, enclosingAPI: APIType) throws -> StatementType {
        let propertyTypes = try expr.properties.map { try ($0.name.value, self.resolvePairType(expr: $0, enclosingAPI: enclosingAPI)) }
        
        var td = TypeDefType(name: expr.name.value, propertyTypes: Dictionary(keyValuePairs: propertyTypes), propertyOrder: expr.propertyOrder, constructorTypes: [], scope: enclosingAPI.scope)
        
        try self.declareType(name: expr.name.value, type: td, enclosingAPI: enclosingAPI)
        
        expr.assignType(type: td, env: self)
        
        let constructorTypes = try expr.constructorSignatures.map { try self.resolveStaticSignature(expr: $0, enclosingAPI: enclosingAPI) }
        
        td.constructorTypes = constructorTypes
        
        try td.constructorTypes.enumerated().forEach { constructor in
            let constructorExpression = expr.constructorSignatures[constructor.offset]
            try enclosingAPI.scope.bind(name: "\(expr.name.value).\(constructorExpression.name.value)", type: constructor.element)
        }
        
        return td
    }
    
    func resolveInstanceCallType(expr: InstanceCallExpression, enclosingScope: Scope) throws -> TypeProtocol {
        let receiver = expr.receiver
        let receiverType = try resolveValueType(expr: receiver, enclosingScope: enclosingScope)
        
        let name = Mangler.mangle(name: "\(receiverType.name).\(expr.methodName.value)")
        guard let signatureType = try enclosingScope.enclosingScope?.lookupBinding(named: name) as? SignatureType else { // expr.methodName.value
            throw OrbitError(message: "Call expressions are not permitted outside of method body")
        }

        let argTypes = try expr.args.map { try self.resolveValueType(expr: $0, enclosingScope: enclosingScope) }
        let expectedArgs = signatureType.argumentTypes

        // TODO - There's probably a better way to say this!
        guard receiverType == signatureType.receiverType else { throw OrbitError(message: "Method \(signatureType.name) does not belong to type \(receiverType.name)") }

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
    
    func resolveStaticCallType(expr: StaticCallExpression) throws -> TypeProtocol {
        let receiver = expr.receiver
        
        // Resolve the callee method's type
        
        let name = Mangler.mangle(name: "\(receiver.value).\(expr.methodName.value)")
        guard let signatureType = try self.currentAPI.scope.lookupBinding(named: name) as? SignatureType else { // expr.methodName.value
            throw OrbitError(message: "Call expressions are not permitted outside of method body")
        }
        
        let argTypes = try expr.args.map { try self.resolveValueType(expr: $0, enclosingScope: self.currentAPI.scope) }
        let expectedArgs = signatureType.argumentTypes
        
        // 1st check: Does the receiver type match the type of the actual receiver
        let actualReceiverType = try self.resolveTypeIdentifier(expr: receiver, enclosingAPI: self.currentAPI)
        
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
        
        let type = signatureType.returnType ?? VoidType(name: "Void", scope: self.currentAPI.scope)
        
        expr.assignType(type: type, env: self)
        
        return type
    }
    
//    func resolveCallType(expr: CallExpression, receiver: Expression, enclosingScope: Scope) throws -> TypeProtocol {
//        // Resolve the callee method's type
//        
//        let name = Mangler.mangle(name: "\(staticCall.receiver.value).\(expr.methodName.value)")
//        guard let signatureType = try enclosingScope.enclosingScope?.lookupBinding(named: name) as? SignatureType else { // expr.methodName.value
//            throw OrbitError(message: "Call expressions are not permitted outside of method body")
//        }
//        
//        let argTypes = try expr.args.map { try self.resolveValueType(expr: $0, enclosingScope: enclosingScope) }
//        let expectedArgs = signatureType.argumentTypes
//        
//        // 1st check: Does the receiver type match the type of the actual receiver
//        let actualReceiverType = try self.resolveValueType(expr: receiver, enclosingScope: enclosingScope)
//        
//        // TODO - There's probably a better way to say this!
//        guard actualReceiverType == signatureType.receiverType else { throw OrbitError(message: "Method \(signatureType.name) does not belong to type \(actualReceiverType.name)") }
//        
//        // 2nd check: have we received the correct number of args
//        guard argTypes.count == expectedArgs.count else { throw OrbitError(message: "'\(signatureType.name)' expects \(expectedArgs.count) arguments, found \(argTypes.count)") }
//        
//        // 3rd check: are the args in the correct order (by type only, not name)
//        _ = try zip(expectedArgs, argTypes).forEach { (l, r) in
//            guard l == r else {
//                throw OrbitError(message: "'\(signatureType.name)' expectd argument of \(l.name), found \(r.name)")
//            }
//        }
//        
//        /*
//            This is about as much as we can check for now.
//            When type annotations are added on the lhs of assignments,
//            we can check the rhs return type against the lhs expected type.
//         */
//        
//        let type = signatureType.returnType ?? VoidType(name: "Void", scope: enclosingScope)
//        
//        expr.assignType(type: type, env: self)
//        
//        return type
//    }
    
    func resolveListLiteralType(expr: ListExpression, enclosingScope: Scope) throws -> ListType {
        // For now, we only have homogenous lists. When generics are working, we must revisit.
        // TODO - Redo with working generics
        
        guard expr.value.count > 0 else {
            let type = ListType(elementType: Anything.shared, size: 0, scope: enclosingScope)
            
            expr.assignType(type: type, env: self)
            
            return type
        }
        
        // List element type is type of first element
        let elementType = try self.resolveValueType(expr: expr.value[0], enclosingScope: enclosingScope)
        
        try expr.value.forEach {
            let type = try self.resolveValueType(expr: $0, enclosingScope: enclosingScope)
            
            guard type == elementType else { throw OrbitError(message: "Type must be the same for every element of a list. Expected \(elementType.name), found \(type.name)") }
        }
        
        let type = ListType(elementType: elementType, size: expr.value.count, scope: enclosingScope)
        
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
    
    func resolvePropertyAccessType(expr: PropertyAccessExpression, enclosingScope: Scope) throws -> TypeProtocol {
        guard let receiverType = try resolveValueType(expr: expr.receiver, enclosingScope: enclosingScope) as? TypeDefType else {
            throw OrbitError(message: "INTERNAL ERROR: Type '\(expr.receiver)' is not a type def")
        }
        
        guard let propertyType = receiverType.propertyTypes[expr.propertyName.value] else {
            throw OrbitError(message: "Type '\(receiverType.name)' has no properties named '\(expr.propertyName.value)'")
        }
        
        let type = PropertyAccessType(receiverType: receiverType, propertyType: propertyType, scope: enclosingScope)
        
        expr.assignType(type: type, env: self)
        
        return type
    }
    
    func resolveIndexAccessType(expr: IndexAccessExpression, enclosingScope: Scope) throws -> TypeProtocol {
        let rType = try resolveValueType(expr: expr.receiver, enclosingScope: enclosingScope)
        
        guard let receiverType = rType as? CollectionType else {
            throw OrbitError(message: "Attempting to index non collection type '\(rType.name)'")
        }
        
        let indexTypes = try expr.indices.map { try resolveValueType(expr: $0, enclosingScope: enclosingScope) }
        let type = IndexAccessType(receiverType: receiverType, indexTypes: indexTypes, elementType: receiverType, scope: enclosingScope)
        
        expr.assignType(type: type, env: self)
        
        return type
    }
    
    func resolveValueType(expr: Expression, enclosingScope: Scope) throws -> TypeProtocol {
        switch expr {
            case is IntLiteralExpression: return self.declaredTypes["Int"]! // TODO - This is gross! We can fix once imports are working
            case is RealLiteralExpression: return self.declaredTypes["Real"]!
            case is IdentifierExpression: return try enclosingScope.lookupBinding(named: (expr as! IdentifierExpression).value)
            case is InstanceCallExpression: return try resolveInstanceCallType(expr: expr as! InstanceCallExpression, enclosingScope: enclosingScope)
            case is StaticCallExpression: return try resolveStaticCallType(expr: expr as! StaticCallExpression)
            case is ListExpression: return try resolveListLiteralType(expr: expr as! ListExpression, enclosingScope: enclosingScope)
            case is BinaryExpression: return try resolveBinaryExpression(expr: expr as! BinaryExpression, enclosingScope: enclosingScope)
            case is PropertyAccessExpression: return try resolvePropertyAccessType(expr: expr as! PropertyAccessExpression, enclosingScope: enclosingScope)
            case is IndexAccessExpression: return try resolveIndexAccessType(expr: expr as! IndexAccessExpression, enclosingScope: enclosingScope)
            
            // TODO - Other literals, property & indexed access
            
            default: throw OrbitError.unresolvableExpression(expression: expr)
        }
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
    
    func resolveMethodType(expr: MethodExpression, enclosingAPI: APIType) throws -> MethodType {
        let signatureType = try self.resolveStaticSignature(expr: expr.signature, enclosingAPI: enclosingAPI)
        
        let name = Mangler.mangle(name: "\(expr.signature.receiverType.value).\(expr.signature.name.value)")
        try enclosingAPI.scope.bind(name: name, type: signatureType) // expr.signature.name.value
        
        let method = MethodType(name: expr.signature.name.value, signatureType: signatureType, enclosingAPI: enclosingAPI, enclosingScope: enclosingAPI.scope)
        
        expr.assignType(type: method, env: self)
        
        // Inject bindings for remaining args
        for arg in expr.signature.parameters {
            let type = try self.resolveTypeIdentifier(expr: arg.type, enclosingAPI: enclosingAPI)
            try method.scope.bind(name: arg.name.value, type: type)
            
            arg.assignType(type: type, env: self)
        }
        
        for (idx, e) in expr.body.enumerated() {
            if let rt = signatureType.returnType, idx == expr.body.count - 1 {
                if let ret = e as? ReturnStatement {
                    var retType = try self.resolveValueType(expr: ret.value, enclosingScope: method.scope)
                    
                    if let access = retType as? PropertyAccessType {
                        // Cheeky hack to help maintain info about property order etc
                        retType = access.propertyType
                    } else if let access = retType as? IndexAccessType {
                        retType = access.receiverType
                    }
                    
                    guard retType.name == rt.name else {
                        throw OrbitError(message: "Method \(signatureType.name) should return a value of type \(rt.name), found \(retType.name)")
                    }
                    
                    ret.assignType(type: retType, env: self)
                    
                    break
                }
            }
            
            _ = try self.resolveStatementType(expr: e, enclosingType: method)
        }
        
        return method
    }
    
    func resolveAssignmentType(expr: AssignmentStatement, enclosingScope: Scope) throws -> TypeProtocol {
        let rhsType = try self.resolveValueType(expr: expr.value, enclosingScope: enclosingScope)
        
        try enclosingScope.bind(name: expr.name.value, type: rhsType)
        
        expr.assignType(type: rhsType, env: self)
        
        return rhsType
    }
    
    func resolveStatementType(expr: Expression, enclosingType: TypeProtocol) throws -> TypeProtocol {
        switch expr {
            case is TypeDefExpression: return try self.resolveTypeDefType(expr: expr as! TypeDefExpression, enclosingAPI: enclosingType as! APIType)
            
            case is MethodExpression: return try self.resolveMethodType(expr: expr as! MethodExpression, enclosingAPI: enclosingType as! APIType)
            
            case is AssignmentStatement: return try self.resolveAssignmentType(expr: expr as! AssignmentStatement, enclosingScope: enclosingType.scope)
            
            case is InstanceCallExpression: return try self.resolveInstanceCallType(expr: expr as! InstanceCallExpression, enclosingScope: enclosingType.scope)
            case is StaticCallExpression: return try self.resolveStaticCallType(expr: expr as! StaticCallExpression)
            
            default: throw OrbitError.unresolvableExpression(expression: expr)
        }
    }
    
    func resolveAPIType(expr: APIExpression) throws -> TypeProtocol {
        var api = APIType(name: expr.name.value, exportableTypes: [])
        
        self.currentAPI = api
        
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
