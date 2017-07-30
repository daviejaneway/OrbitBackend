import Foundation
import OrbitCompilerUtils
import OrbitFrontend
import LLVM
import cllvm

public struct IRBinding {
    let ref: IRValue
    
    let read: () -> IRValue
    let write: (IRValue) -> IRValue
    
    let type: TypeProtocol
    let irType: IRType
    
    static func create(builder: IRBuilder, type: TypeProtocol, irType: IRType, name: String, initial: IRValue, isFunctionParameter: Bool = false) -> IRBinding {
        let alloca = builder.buildAlloca(type: irType, name: name)
        
        builder.buildStore(initial, to: alloca)
        
        let read = { builder.buildLoad(alloca) }
        let write = { builder.buildStore($0, to: alloca) }
        
        return IRBinding(ref: alloca, read: read, write: write, type: type, irType: irType)
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
        if let listType = type as? ListType {
            let elementType = try lookupLLVMType(type: listType.elementType)
            
            return PointerType(pointee: elementType)
            //return ArrayType(elementType: elementType, count: listType.size)
        }
        
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
        guard let type = self.typeMap[hashValue] else {
            throw OrbitError(message: "FATAL")
        }
        
        return try self.lookupLLVMType(type: type)
    }
    
    func generateTypeDef(expr: TypeDefExpression) throws {
        let type = try self.lookupType(expr: expr)
        
        let propertyTypes = try expr.properties.map { pair in
            return try self.lookupLLVMType(hashValue: pair.type.hashValue)
        }
        
        let irType = self.builder.createStruct(name: type.name, types: propertyTypes)
        
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
    
    func generateVariableRef(expr: IdentifierExpression, dereference: Bool = true, enclosingScope: Scope) throws -> IRValue {
        // TODO - For now, all variables are pointers.
        // Value types will come later.
        
        let ptr = try enclosingScope.lookupVariable(named: expr.value)
        
        return dereference ? ptr.read() : ptr.ref
    }
    
    func generatePropertyAccess(expr: PropertyAccessExpression, enclosingScope: Scope) throws -> IRValue {
        guard let type = try self.lookupType(expr: expr) as? PropertyAccessType else { throw OrbitError(message: "FATAL") }
        
        guard let idx = type.receiverType.propertyOrder[expr.propertyName.value] else {
            throw OrbitError(message: "Property '\(expr.propertyName.value)' not found for type '\(type.receiverType.name)'")
        }
        
        let val = try self.generateValue(expr: expr.receiver, dereferencePointer: false, scope: enclosingScope)
        
        // TODO - Always dereference the GEP?
        
        let alloca = self.builder.buildStructGEP(val, index: idx)
        
        return self.builder.buildLoad(alloca)
    }
    
    func generateList(expr: ListExpression, scope: Scope) throws -> IRValue {
        let listType = try self.lookupType(expr: expr) as! ListType
        //let arrType = try self.lookupLLVMType(type: listType)
        let elementType = try self.lookupLLVMType(type: listType.elementType)
        //let elementPtrType = PointerType(pointee: elementType)
        let values = try expr.value.map { try self.generateValue(expr: $0, dereferencePointer: true, scope: scope) }
        
        let malloc = self.builder.buildMalloc(elementType, count: listType.size, name: "")
        
        values.enumerated().forEach { value in
            let idx = IntType.int64.constant(value.offset)
            let gep = self.builder.buildGEP(malloc, indices: [idx])
            
            _ = self.builder.buildStore(value.element, to: gep)
        }
        
        return malloc
    }
    
    /*
        In essence, this method returns the receiver's nth element.
        
        Under the hood, lists are just pointers. So what is really happening
        here is pointer arithmetic & dereferencing. The Type System will have
        already checked that the receiver object is indexable and that the type
        of the index value resolves to an Integer.
     */
    func generateIndexAccess(expr: IndexAccessExpression, scope: Scope) throws -> IRValue {
        let receiver = try self.generateValue(expr: expr.receiver, dereferencePointer: true, scope: scope)
        
        let indices = try expr.indices.map { try self.generateValue(expr: $0, scope: scope) }
        let alloca = self.builder.buildGEP(receiver, indices: indices)
        
        return self.builder.buildLoad(alloca)
    }
    
    func generateValue(expr: Expression, dereferencePointer: Bool = true, scope: Scope) throws -> IRValue {
        switch expr {
        case is IdentifierExpression: return try self.generateVariableRef(expr: expr as! IdentifierExpression, dereference: dereferencePointer, enclosingScope: scope)
            case is IntLiteralExpression: return try self.generateIntValue(expr: expr as! IntLiteralExpression)
            case is RealLiteralExpression: return try self.generateRealValue(expr: expr as! RealLiteralExpression)
            case is BinaryExpression: return try self.generateBinaryExpression(expr: expr as! BinaryExpression, scope: scope)
            case is PropertyAccessExpression: return try self.generatePropertyAccess(expr: expr as! PropertyAccessExpression, enclosingScope: scope)
            case is AssignmentStatement: return try self.generateAssignment(expr: expr as! AssignmentStatement, scope: scope)
            case is ListExpression: return try self.generateList(expr: expr as! ListExpression, scope: scope)
            case is IndexAccessExpression: return try self.generateIndexAccess(expr: expr as! IndexAccessExpression, scope: scope)
            
            default: throw OrbitError(message: "Expression \((expr as! GroupableExpression).dump()) does not yield a value")
        }
    }
    
    func generateReturn(expr: ReturnStatement, scope: Scope) throws -> IRValue {
        let retVal = try self.generateValue(expr: expr.value, scope: scope)
        
        return self.builder.buildRet(retVal)
    }
    
    func generateAssignment(expr: AssignmentStatement, scope: Scope) throws -> IRValue {
        // TODO - Value types
        
        let valueType = try self.lookupType(expr: expr.value)
        let irType = try self.lookupLLVMType(type: valueType)
        let value = try self.generateValue(expr: expr.value, scope: scope)
        let binding = IRBinding.create(builder: self.builder, type: valueType, irType: irType, name: expr.name.value, initial: value)
        
        try scope.defineVariable(named: expr.name.value, binding: binding)
        
        return value
    }
    
    func generateStaticCall(expr: StaticCallExpression, scope: Scope) throws -> IRValue {
        let name = Mangler.mangle(name: "\(expr.receiver.value).\(expr.methodName.value)")
        let fn = try self.lookupFunction(named: name)
        let args = try expr.args.map { try self.generateValue(expr: $0, scope: scope) }
        
        return self.builder.buildCall(fn, args: args)
    }
    
    func generate(expr: Expression, scope: Scope) throws -> IRValue? {
        switch expr {
            case is ValueExpression: return try self.generateValue(expr: expr, scope: scope)
            case is ReturnStatement: return try self.generateReturn(expr: expr as! ReturnStatement, scope: scope)
            case is AssignmentStatement: return try self.generateAssignment(expr: expr as! AssignmentStatement, scope: scope)
            case is StaticCallExpression: return try self.generateStaticCall(expr: expr as! StaticCallExpression, scope: scope)
            
            default: throw OrbitError(message: "Could not evaluate expression: \(expr)")
        }
    }
    
    func generateSharedMethodComponents(expr: MethodExpression) throws -> FunctionType {
        let argTypes = try expr.signature.parameters.map { param in
            return try self.lookupLLVMType(hashValue: param.type.hashValue)
        }
        
        var retType: IRType = LLVM.VoidType()
        
        if let ret = expr.signature.returnType {
            retType = try self.lookupLLVMType(hashValue: ret.hashValue)
        }
        
        return FunctionType(argTypes: argTypes, returnType: retType)
    }
    
    /// Creates a basic block inside the given function named "entry" and positions the IP at the end
    func generateEntryBlock(function: Function) -> BasicBlock {
        let entry = function.appendBasicBlock(named: "entry")
        
        self.builder.positionAtEnd(of: entry)
        
        return entry
    }
    
    func generateMethodParams(params: [PairExpression], function: Function, signatureType: TypeProtocol) throws {
        try params.enumerated().forEach { (offset, element) in
            let type = try self.lookupType(expr: element.type)
            let irType = try self.lookupLLVMType(hashValue: element.type.hashValue)
            let binding = IRBinding.create(builder: self.builder, type: type, irType: irType, name: element.name.value, initial: function.parameters[offset])
            
            try signatureType.scope.defineVariable(named: element.name.value, binding: binding)
        }
    }
    
    func generateMethodBody(body: [Expression], signatureType: TypeProtocol) throws {
        try body.forEach { statement in
            _ = try self.generate(expr: statement, scope: signatureType.scope)
        }
    }
    
    func generateMethod(expr: MethodExpression, signatureType: TypeProtocol, receiverName: String, functionName: String) throws {
        let funcType = try self.generateSharedMethodComponents(expr: expr)
        
        let recName = self.mangle(name: "\(receiverName)")
        let funcName = self.mangle(name: "\(recName).\(functionName)")
        
        let fn = self.builder.addFunction(funcName, type: funcType)
        _ = self.generateEntryBlock(function: fn)
        
        try self.generateMethodParams(params: expr.signature.parameters, function: fn, signatureType: signatureType)
        try self.generateMethodBody(body: expr.body, signatureType: signatureType)
        
        if expr.signature.returnType == nil {
            _ = self.builder.buildRetVoid()
        }
    }
    
    func generateStaticMethod(expr: MethodExpression) throws {
        _ = try self.lookupLLVMType(hashValue: expr.signature.receiverType.hashValue)
        let sigType = try self.lookupType(expr: expr.signature)
        
        try self.generateMethod(expr: expr, signatureType: sigType, receiverName: expr.signature.receiverType.value, functionName: expr.signature.name.value)
    }
    
    public func execute(input: (typeMap: [Int : TypeProtocol], ast: APIExpression)) throws -> Module {
        self.typeMap = input.typeMap
        
        let typeDefs = input.ast.body.filter { $0 is TypeDefExpression }
        let staticMethodDefs = input.ast.body.filter { $0 is MethodExpression }
        
        try typeDefs.forEach { try self.generateTypeDef(expr: $0 as! TypeDefExpression) }
        try staticMethodDefs.forEach { try self.generateStaticMethod(expr: $0 as! MethodExpression) }
        
        return self.module
    }
}
