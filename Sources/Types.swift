//
//  Types.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 09/11/2017.
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend

class BuiltIn {
    static let specialTypes: [Qualified] = [
        QualifiedUnit(name: "Orb.Core.Types.Unit", underlyingType: Unit(name: "()", properties: [], adoptedTraits: []), propertyTypes: [], adoptedTraits: [], isTrait: false)
    ]
}

protocol Type {
    var name: String { get }
    
    func debug(level: Int) -> String
}

struct HashableType : Hashable {
    let type: Type
    
    var hashValue: Int {
        return type.name.hashValue
    }
    
    static func ==(lhs: HashableType, rhs: HashableType) -> Bool {
        return lhs.type == rhs.type
    }
}

func ==(lhs: Type, rhs: Type) -> Bool {
    switch (lhs, rhs) {
        case is (Qualified, Type):
            return lhs.name == rhs.name || (lhs as! Qualified).underlyingType == rhs
        
        case is (Type, Qualified):
            return lhs.name == rhs.name || (rhs as! Qualified).underlyingType == lhs
        
        default:
            return lhs.name == rhs.name
    }
}

extension Type {
    
    func debugIndentation(level: Int = 0) -> String {
        return String(repeating: "\t", count: level)
    }
}

struct None : Type, RValType {
    
    
    let name = "()"
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))()"
    }
}

struct Attribute : Type {
    let name: String
    let type: Type
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))ATTRIBUTE \(self.name) of \(self.type.debug(level: 0))"
    }
}

struct Trait : Type {
    let name: String
    let attributes: [Attribute]
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))TRAIT \(self.name){\n\(self.attributes.map { $0.debug(level: level + 1) }.joined(separator: "\n") )\n\(debugIndentation(level: level))}"
    }
}

// Represents a the space where a concrete type will be
struct PlaceHolder : Type {
    let name: String
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))PLACEHOLDER: \(self.name)"
    }
    
    static func ==(lhs: PlaceHolder, rhs: PlaceHolder) -> Bool {
        return lhs.name == rhs.name
    }
}

class Qualified : Type {
    let name: String
    let underlyingType: Type
    let isTrait: Bool
    
    init(name: String, underlyingType: Type, isTrait: Bool = false) {
        self.name = name
        self.underlyingType = underlyingType
        self.isTrait = isTrait
    }
    
    func debug(level: Int) -> String {
        let traitStr = (self.isTrait) ? " TRAIT" : ""
        return "\(debugIndentation(level: level))QUALIFIED\(traitStr): \(self.name) {\n\(self.underlyingType.debug(level: level + 1))\n\(debugIndentation(level: level))}"
    }
}

class QualifiedUnit : Qualified {
    let propertyTypes: [Qualified]
    let adoptedTraits: [Qualified]
    
    init(name: String, underlyingType: Type, propertyTypes: [Qualified], adoptedTraits: [Qualified], isTrait: Bool) {
        self.propertyTypes = propertyTypes
        self.adoptedTraits = adoptedTraits
        
        super.init(name: name, underlyingType: underlyingType, isTrait: isTrait)
    }
    
    override func debug(level: Int) -> String {
        let traitStr = (self.isTrait) ? " TRAIT" : ""
        return "\(debugIndentation(level: level))QUALIFIED\(traitStr): \(self.name)(\(self.propertyTypes.map { $0.name }.joined(separator: ",")))\n\(debugIndentation(level: level + 1))ADOPTS:\n\(adoptedTraits.map { $0.debug(level: level + 2) }.joined(separator: "\n"))"
    }
}

func ==(lhs: Qualified, rhs: Type) -> Bool {
    return lhs.name == rhs.name || (lhs.underlyingType == rhs)
}

// A concrete type, as defined by a typeDef expression
class Unit : Type {
    // Info from the first pass, contains type name
    let name: String
    let properties: [Type]
    let adoptedTraits: [Type]
    // TODO: Traits
    
    init(name: String, properties: [Type], adoptedTraits: [Type] = []) {
        self.name = name
        self.properties = properties
        self.adoptedTraits = adoptedTraits
    }
    
    func debug(level: Int) -> String {
        let props = self.properties.map { $0.debug(level: 0) }.joined(separator: ",")
        return "\(debugIndentation(level: level))UNIT: \(self.name)(\(props))"
    }
}

protocol StatementType : Type {}
protocol RValType : Type {}

protocol IntegralType : RValType {
    static var width: Int { get }
}

struct IntType : IntegralType {
    static let width: Int = 64
    let name = "Int"
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))INT"
    }
}

struct AssignmentType : StatementType {
    let name: String
    let type: RValType
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))\(debugIndentation(level: level + 1))\(self.name) = \(self.type.debug(level: 0))"
    }
}

struct CallType : StatementType, RValType {
    let name: String
    let receiverType: Type
    let args: [Type]
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))CALL: \(self.name) (\(self.args.map { $0.debug(level: 0) }.joined(separator: ",")))"
    }
}

struct Block : Type {
    let name = "<BLOCK>"
    let statements: [StatementType]
    let returnType: Type
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))BLOCK: \(self.statements.map { $0.debug(level: level + 1) }.joined(separator: "\n"))\n\(debugIndentation(level: level + 1))RETURN: \(self.returnType.debug(level: 0))"
    }
}

struct Signature : Type {
    let name: String
    let receiverType: Type
    let argTypes: [String : Type]
    let returnType: Type
    
    func debug(level: Int) -> String {
        let tabs = debugIndentation(level: level + 1)
        let args = self.argTypes.map { $0.value }.map { $0.debug(level: 0) }.joined(separator: ",")
        return "\(debugIndentation(level: level))SIGNATURE:\n\(tabs)RECEIVER: \(self.receiverType.debug(level: 0))\n\(tabs)ARGS: (\(args))\n\(tabs)RETURN: \(self.returnType.debug(level: 0))"
    }
}

struct Method : Type {
    let name: String
    let receiverType: Type
    let argTypes: [String : Type]
    let returnType: Type
    let body: Block
    
    func debug(level: Int) -> String {
        let tabs = debugIndentation(level: level + 1)
        let args = self.argTypes.map { $0.value }.map { $0.debug(level: 0) }.joined(separator: ",")
        return "\(debugIndentation(level: level))METHOD:\n\(tabs)RECEIVER: \(self.receiverType.debug(level: 0))\n\(tabs)ARGS: (\(args))\n\(tabs)RETURN: \(self.returnType.debug(level: 0))\n\(debugIndentation(level: level + 1))BODY:\n\(self.body.debug(level: level + 2))"
    }
}

struct API : Type {
    let name: String
    // Methods & typeDefs
    let declaredTypes: [Type]
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))API \(self.name)\n\(self.declaredTypes.map { $0.debug(level: level + 1) }.joined(separator: "\n"))"
    }
}

struct ProgramType : Type {
    let name = "<PROGRAM>"
    let apis: [API]
    
    func debug(level: Int) -> String {
        return "\(debugIndentation(level: level))PROGRAM:\n\(self.apis.map { $0.debug(level: level + 1) }.joined(separator: "\n"))"
    }
}

class Environment {
    private(set) var types = [Type]()
    private let parent: Environment?
    
    // Holds variables
    private var bindings = [String : Type]()
    
    private let name: String

    var qualifiedName: String {
        return (self.parent?.qualifiedName ?? "") + self.name
    }
    
    init(parent: Environment?, name: String) {
        self.parent = parent
        self.name = (parent?.name ?? "") + name
    }

    func bind(name: String, toType: Type) {
        // TODO: Check here for resused names
        self.bindings[name] = toType
    }
    
    func resolveBinding(forName: String) throws -> Type {
        guard let binding = self.bindings[forName] else { throw OrbitError(message: "FATAL Unknown binding: \(forName)") }
        
        return binding
    }
    
    func qualify(unit: Type) -> Qualified {
        return Qualified(name: self.qualifiedName + "." + unit.name, underlyingType: unit, isTrait: unit is Trait)
    }
    
    func qualify(method: Method) -> Qualified {
        return Qualified(name: self.qualifiedName + "." + method.name, underlyingType: method)
    }
}

struct TypeAnnotation : ExpressionAnnotation {
    let type: Type
}

protocol ExpressionTyperProtocol {}

protocol ExpressionTyper : ExpressionTyperProtocol {
    associatedtype ExpressionType: Expression

    func generateType(forExpression expression: ExpressionType, environment: Environment) throws -> Type
}

class RootExpressionType : ExpressionTyper {
    typealias ExpressionType = RootExpression

    func generateType(forExpression expression: RootExpression, environment: Environment) throws -> Type {
        let apiTyper = APIExpressionTyper()
        
        let prog = expression.body[0] as! ProgramExpression
        
        let apiTypes = try (prog.apis).map {
            try apiTyper.generateType(forExpression: $0, environment: environment)
        }

        return ProgramType(apis: apiTypes as! [API])
    }
}

class SimpleTyper : CompilationPhase {
    typealias InputType = RootExpression
    typealias OutputType = Type

    func execute(input: RootExpression) throws -> Type {
        return try RootExpressionType().generateType(forExpression: input, environment: Environment(parent: nil, name: ""))
    }
}

protocol TypeExpanderProtocol {
    func expand(type: Type) throws -> Type
}

class QualifiedTypeExpander : TypeExpanderProtocol {
    private(set) var visibleTypes: [Qualified]
    
    init(visibleTypes: [Qualified]) {
        self.visibleTypes = visibleTypes
    }
    
    // To allow recursion, we need to cheat
    func temporarilyInject(type: Qualified, action: () throws -> Type) throws -> Type {
        self.visibleTypes.append(type)
        
        let result = try action()
        
        self.visibleTypes.removeLast()
        
        return result
    }
    
    func resolve(type: Type) throws -> Qualified {
        // TODO: There will be a better way of doing this
        let matches = (self.visibleTypes + BuiltIn.specialTypes).filter { t in
            //print("\(t) == \(type)")
            return t == type
        }
        
        guard !matches.isEmpty else {
            throw OrbitError(message: "FATAL Undefined type: \(type.name)")
        }
        
        guard matches.count == 1 else {
            throw OrbitError(message: "FATAL Ambiguous type: \(type.name)")
        }
        
        let resolvedType = matches[0]
        
        if let unit = resolvedType.underlyingType as? Unit {
            let expandedPropertyTypes = try unit.properties.map { try resolve(type: $0) }
            let expandedAdoptedTraits = try unit.adoptedTraits.map { try resolve(type: $0) }
            
            let result = Unit(name: unit.name, properties: expandedPropertyTypes)
            
            return QualifiedUnit(name: resolvedType.name, underlyingType: result, propertyTypes: expandedPropertyTypes, adoptedTraits: expandedAdoptedTraits, isTrait: false)
        }
        
        return resolvedType
    }
    
    func expand(type: Type) throws -> Type {
        guard let qual = type as? Qualified else { throw OrbitError(message: "FATAL: Type is not qualified: \(type)") }
        
        // TODO: Recursive type defs.
        // e.g. type Foo(f Foo)
        
        // TODO: These two cases should be unified.
        // A trait and a unit(concrete type) are siblings, underlying data structures should reflect that.
        // Should have a 'CompoundType' protocol that is adopted by both Unit & Trait
        if qual.underlyingType is Unit {
            let unit = (type as! Qualified).underlyingType as! Unit
            let qualified = try unit.properties.map { it in
                try self.resolve(type: it)
            }
            
            let qualifiedTraits = try unit.adoptedTraits.map { it in
                try self.resolve(type: it)
            }
            
            return QualifiedUnit(name: type.name, underlyingType: unit, propertyTypes: qualified, adoptedTraits: qualifiedTraits, isTrait: false)
        } else if qual.underlyingType is Trait {
            let unit = (type as! Qualified).underlyingType as! Trait
            let qualified = try unit.attributes.map { try self.resolve(type: $0) }
            // TODO: Trait inheritence
            
            return QualifiedUnit(name: type.name, underlyingType: unit, propertyTypes: qualified, adoptedTraits: [], isTrait: true)
        }
        
        throw OrbitError(message: "FATAL: Cannot qualify type: \(qual.underlyingType)")
    }
}

protocol QualifiedTypeAwareTypeExpander : TypeExpanderProtocol {
    var qualifiedTypeExpander: QualifiedTypeExpander { get }
    
    init(qualifiedTypeExpander: QualifiedTypeExpander)
}

class CallExpander : QualifiedTypeAwareTypeExpander {
    let qualifiedTypeExpander: QualifiedTypeExpander
    
    required init(qualifiedTypeExpander: QualifiedTypeExpander) {
        self.qualifiedTypeExpander = qualifiedTypeExpander
    }
    
    func expand(type: Type) throws -> Type {
        let call = type as! CallType
        
        let expandedReceiverType = try self.qualifiedTypeExpander.resolve(type: call.receiverType)
        
        // TODO: This is hacky for now
        if call.name == "__init__" {
            // Empty constructor is autogenerated
            // If we're calling a constructor, the return type is just the constructed type
            return expandedReceiverType
        }
        
        let method = try self.qualifiedTypeExpander.resolve(type: PlaceHolder(name: call.name)).underlyingType as! Method
        let expandedReturnType = try self.qualifiedTypeExpander.resolve(type: method.returnType)
        
        let expandedArgs = try call.args.map { try self.qualifiedTypeExpander.resolve(type: $0) }
        let expandedMethod = try self.qualifiedTypeExpander.resolve(type: method)
        
        return Qualified(name: expandedMethod.name, underlyingType: CallType(name: expandedMethod.name, receiverType: expandedReturnType, args: expandedArgs))
    }
}

class ValueExpander : QualifiedTypeAwareTypeExpander {
    let qualifiedTypeExpander: QualifiedTypeExpander
    
    required init(qualifiedTypeExpander: QualifiedTypeExpander) {
        self.qualifiedTypeExpander = qualifiedTypeExpander
    }
    
    func expand(type: Type) throws -> Type {
        switch type {
            case is CallType:
                return try CallExpander(qualifiedTypeExpander: self.qualifiedTypeExpander).expand(type: type)
            
            default: return None()
        }
    }
}

class BlockExpander : QualifiedTypeAwareTypeExpander {
    let qualifiedTypeExpander: QualifiedTypeExpander
    
    required init(qualifiedTypeExpander: QualifiedTypeExpander) {
        self.qualifiedTypeExpander = qualifiedTypeExpander
    }
    
    func expand(type: Type) throws -> Type {
        let block = type as! Block
        //let returnTypeExpander =
        
        let expandedReturnType = try ValueExpander(qualifiedTypeExpander: self.qualifiedTypeExpander).expand(type: block.returnType)
        
        return Block(statements: block.statements, returnType: expandedReturnType)
    }
}

class MethodExpander : QualifiedTypeAwareTypeExpander {
    let qualifiedTypeExpander: QualifiedTypeExpander
    
    required init(qualifiedTypeExpander: QualifiedTypeExpander) {
        self.qualifiedTypeExpander = qualifiedTypeExpander
    }
    
    func expand(type: Type) throws -> Type {
        //let typeExpander = QualifiedTypeExpander(visibleTypes: self.qualifiedTypes)
        let method = type as! Method
        let expandedReceiver = try self.qualifiedTypeExpander.resolve(type: method.receiverType)
        let expandedReturnType = try self.qualifiedTypeExpander.resolve(type: method.returnType)
        var args = [String : Type]()
        try method.argTypes.forEach { try args[$0.key] = self.qualifiedTypeExpander.resolve(type: $0.value) }
        
        let blockExpander = BlockExpander(qualifiedTypeExpander: self.qualifiedTypeExpander)
        let expandedBody = try blockExpander.expand(type: method.body)
        
        let expandedName = try self.qualifiedTypeExpander.resolve(type: method)
        
        let nMethod = Method(name: method.name, receiverType: expandedReceiver, argTypes: args, returnType: expandedReturnType, body: expandedBody as! Block)
        
        return Qualified(name: expandedName.name, underlyingType: nMethod)
    }
}

class APIExpander : TypeExpanderProtocol {
    func expand(type: Type) throws -> Type {
        let qualifiedTypes: [Qualified] = (type as! API).declaredTypes.filter { $0 is Qualified } as! [Qualified]
        
        let expandedQualifiedTypes: [Qualified] = try qualifiedTypes.map { qual in
            switch qual.underlyingType {
                case is Method:
                    let qualifiedTypeExpander = QualifiedTypeExpander(visibleTypes: qualifiedTypes)
                    return try MethodExpander(qualifiedTypeExpander: qualifiedTypeExpander)
                        .expand(type: qual.underlyingType) as! Qualified
                
                default:
                    return try QualifiedTypeExpander(visibleTypes: qualifiedTypes).expand(type: qual) as! Qualified
            }
        }
        
        return API(name: type.name, declaredTypes: expandedQualifiedTypes)
    }
}

class TypeExpander : CompilationPhase {
    typealias InputType = ProgramType
    typealias OutputType = ProgramType
    
    func execute(input: ProgramType) throws -> ProgramType {
        let apiExpander = APIExpander()
        let expandedApis = try input.apis.map { try apiExpander.expand(type: $0) }
        
        return ProgramType(apis: expandedApis as! [API])
    }
}
