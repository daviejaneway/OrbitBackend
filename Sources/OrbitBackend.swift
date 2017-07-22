import Foundation
import OrbitCompilerUtils
import OrbitFrontend
import LLVM

public struct IRBinding {
    let ref: IRValue
    
    let read: () -> IRValue
    let write: (IRValue) -> IRValue
    
    static func create(builder: IRBuilder, type: IRType, name: String, initial: IRValue, isFunctionParameter: Bool = false) -> IRBinding {
        let alloca = builder.buildAlloca(type: type, name: name)
        
        builder.buildStore(initial, to: alloca)
        
        let read = { builder.buildLoad(alloca) }
        let write = { builder.buildStore($0, to: alloca) }
        
        return IRBinding(ref: alloca, read: read, write: write)
    }
}

class BuiltIn {
    static let NativeIntType = IntType(width: MemoryLayout<Int>.size * 8)
    static let NativeRealType = FloatType.double
    
    static let IntIntPlusFn = FunctionType(argTypes: [BuiltIn.NativeIntType, BuiltIn.NativeIntType], returnType: BuiltIn.NativeIntType)
    
//    static let availableTypes = [
//        "Int": BuiltIn.NativeIntType,
//        "Real": BuiltIn.NativeRealType
//    ]
    
    static func generateIntIntPlusFn(builder: IRBuilder) -> Function {
        let fn = builder.addFunction("+", type: IntIntPlusFn)
        
        let entry = fn.appendBasicBlock(named: "entry")
        
        builder.positionAtEnd(of: entry)
        
        let x = fn.parameter(at: 0)!
        let y = fn.parameter(at: 1)!
        let z = builder.buildAdd(x, y)
        
        _ = builder.buildRet(z)
        
        return fn
    }
}

struct Name : Hashable {
    let relativeName: String
    let absoluteName: String
    
    var hashValue: Int {
        return relativeName.hashValue ^ absoluteName.hashValue &* 16777619
    }
    
    static func ==(lhs: Name, rhs: Name) -> Bool {
        return lhs.absoluteName == rhs.absoluteName || lhs.relativeName == rhs.relativeName
    }
}

public class Mangler {
    
    public static func mangle(name: String) -> String {
        return name.replacingOccurrences(of: ":", with: ".")
    }
}

public class LLVMGenerator : CompilationPhase {
    public typealias InputType = (typeMap: [Int : TypeProtocol], ast: APIExpression)
    public typealias OutputType = Module
    
    private let builder: IRBuilder
    private let module: Module
    
    private var typeMap: [Int : TypeProtocol] = [:]
    private var llvmTypeMap: [Name : IRType] = [
        Name(relativeName: "Int", absoluteName: "Int") : BuiltIn.NativeIntType,
        Name(relativeName: "Real", absoluteName: "Real") : BuiltIn.NativeRealType
    ]
    
    public init(apiName: String) {
        self.module = Module(name: apiName)
        self.builder = IRBuilder(module: self.module)
        
        // BUILT-INS
        _ = BuiltIn.generateIntIntPlusFn(builder: self.builder)
    }
    
    func mangle(name: String) -> String {
        return Mangler.mangle(name: name)
    }
    
    func defineLLVMType(type: TypeProtocol, llvmType: IRType) throws {
        let relativeNames = self.llvmTypeMap.keys.map { $0.relativeName }
        guard !relativeNames.contains(type.name) else { throw OrbitError(message: "Attempted to redefine type '\(type.name)'") }
        
        let absoluteNames = self.llvmTypeMap.keys.map { $0.absoluteName }
        guard !absoluteNames.contains(type.name) else { throw OrbitError(message: "Attempted to redefine type '\(type.name)'") }
        
        try self.llvmTypeMap[Name(relativeName: type.name, absoluteName: type.absoluteName())] = llvmType
    }
    
    func lookupType(expr: Expression) throws -> TypeProtocol {
        guard let type = self.typeMap[expr.hashValue] else { throw OrbitError(message: "Type of expression '\(expr)' could not be deduced") }
        
        return type
    }
    
    func lookupLLVMType(type: TypeProtocol) throws -> IRType {
        guard let t = self.llvmTypeMap[try type.fullName()] else {
            throw OrbitError(message: "Unknown type: \(type.name)")
        }
        
        return t
    }
    
    func lookupFunction(named: String) throws -> Function {
        guard let fn = self.module.function(named: named) else { throw OrbitError(message: "Undefined function: \(named)") }
        
        return fn
    }
    
    func lookupLLVMType(hashValue: Int) throws -> IRType {
        guard let type = self.typeMap[hashValue] else { throw OrbitError(message: "FATAL") }
        
        return try self.lookupLLVMType(type: type)
    }
    
    func generateTypeDef(expr: TypeDefExpression) throws {
        let type = try self.lookupType(expr: expr)
        
        let irType = self.builder.createStruct(name: type.name)
        
        try self.defineLLVMType(type: type, llvmType: irType)
    }
    
    func generateIntValue(expr: IntLiteralExpression) throws -> IRValue {
        return BuiltIn.NativeIntType.constant(expr.value)
    }
    
    func generateRealValue(expr: RealLiteralExpression) throws -> IRValue {
        return FloatType.double.constant(expr.value)
    }
    
    func generateBinaryExpression(expr: BinaryExpression, scope: Scope) throws -> IRValue {
        /*
            NOTE - I'm implementing binary operators as function calls for now.
            When the time comes to start optimising, we can definitely save some
            cycles here by specialising the math operators, as LLVM has built in support for them.
            Or maybe we give operators the ability to generate LLVM code directly, sort of like asm in C.
         */
        
        let left = try self.generateValue(expr: expr.left, scope: scope)
        let right = try self.generateValue(expr: expr.right, scope: scope)
        
        // We must quote the operator symbol for LLVM
        // We might generate ASCII aliases for operators in the future, not sure I like quoted identifiers
        let opName = "\(expr.op.symbol)"
        
        let fn = try self.lookupFunction(named: opName)
        let call = self.builder.buildCall(fn, args: [left, right])
        
        // `call` holds the result of `left op right` (really `op(left, right)`)
        return call
    }
    
    func generateVariableRef(expr: IdentifierExpression, enclosingScope: Scope) throws -> IRValue {
        // TODO - For now, all variables are pointers.
        // Copying value types will come later.
        
        let ptr = try enclosingScope.lookupVariable(named: expr.value)
        
        return ptr.read()
    }
    
    func generateValue(expr: Expression, scope: Scope) throws -> IRValue {
        switch expr {
            case is IdentifierExpression: return try self.generateVariableRef(expr: expr as! IdentifierExpression, enclosingScope: scope)
            case is IntLiteralExpression: return try self.generateIntValue(expr: expr as! IntLiteralExpression)
            case is RealLiteralExpression: return try self.generateRealValue(expr: expr as! RealLiteralExpression)
            case is BinaryExpression: return try self.generateBinaryExpression(expr: expr as! BinaryExpression, scope: scope)
            
            default: throw OrbitError(message: "Expression \(expr) does not yield a value")
        }
    }
    
    func generateReturn(expr: ReturnStatement, scope: Scope) throws -> IRValue {
        let retVal = try self.generateValue(expr: expr.value, scope: scope)
        
        return self.builder.buildRet(retVal)
    }
    
    func generate(expr: Expression, scope: Scope) throws -> IRValue? {
        switch expr {
            case is ValueExpression: return try self.generateValue(expr: expr, scope: scope)
            case is ReturnStatement: return try self.generateReturn(expr: expr as! ReturnStatement, scope: scope)
            
            default: throw OrbitError(message: "Could not evaluate expression: \(expr)")
        }
    }
    
    func generateStaticMethod(expr: MethodExpression<StaticSignatureExpression>) throws {
        // Sanity check to ensure receiver type actually exists
        _ = try self.lookupLLVMType(hashValue: expr.signature.receiverType.hashValue)
        let sigType = try self.lookupType(expr: expr.signature)
        
        let argTypes = try expr.signature.parameters.map { param in
            return try self.lookupLLVMType(hashValue: param.type.hashValue)
        }
        
        var retType: IRType = LLVM.VoidType()
        
        if let ret = expr.signature.returnType {
            retType = try self.lookupLLVMType(hashValue: ret.hashValue)
        }
        
        let funcType = FunctionType(argTypes: argTypes, returnType: retType)
        let recName = self.mangle(name: "\(expr.signature.receiverType.value)")
        let funcName = self.mangle(name: "\(recName).\(expr.signature.name.value)")
        
        let fn = self.builder.addFunction(funcName, type: funcType)
        let entry = fn.appendBasicBlock(named: "entry")
        
        self.builder.positionAtEnd(of: entry)
        
        try expr.signature.parameters.enumerated().forEach { (offset, element) in
            let type = try self.lookupLLVMType(hashValue: element.type.hashValue)
            let binding = IRBinding.create(builder: self.builder, type: type, name: element.name.value, initial: fn.parameters[offset])
            
            try sigType.scope.defineVariable(named: element.name.value, binding: binding)
        }
        
        try expr.body.forEach { statement in
            _ = try self.generate(expr: statement, scope: sigType.scope)
        }
        
//        if let _ = expr.signature.returnType, let _ = expr.body.last as? ReturnStatement {
//            // Method declares a return type & the method body ends with a return statement, success.
//            // Could check actual return type matches expected return type.
//            return
//        }
    }
    
    func generateInstanceMethod(expr: MethodExpression<InstanceSignatureExpression>) throws {
        let funcType = FunctionType(argTypes: [], returnType: LLVM.VoidType()) // TODO
        
        let recName = self.mangle(name: "\(expr.signature.receiverType.type.value)")
        let funcName = self.mangle(name: "\(recName).\(expr.signature.name.value)")
        
        _ = self.builder.addFunction(funcName, type: funcType)
    }
    
    public func execute(input: (typeMap: [Int : TypeProtocol], ast: APIExpression)) throws -> Module {
        self.typeMap = input.typeMap
        
        let typeDefs = input.ast.body.filter { $0 is TypeDefExpression }
        let staticMethodDefs = input.ast.body.filter { $0 is MethodExpression<StaticSignatureExpression> }
        let instanceMethodDefs = input.ast.body.filter { $0 is MethodExpression<InstanceSignatureExpression> }
        
        try typeDefs.forEach { try self.generateTypeDef(expr: $0 as! TypeDefExpression) }
        try staticMethodDefs.forEach { try self.generateStaticMethod(expr: $0 as! MethodExpression<StaticSignatureExpression>) }
        try instanceMethodDefs.forEach { try self.generateInstanceMethod(expr: $0 as! MethodExpression<InstanceSignatureExpression>) }
        
        return self.module
    }
}
