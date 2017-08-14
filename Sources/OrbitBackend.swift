import Foundation
import OrbitCompilerUtils
import OrbitFrontend
import LLVM
import cllvm

extension OrbitError {
    convenience init(message: String, position: SourcePosition) {
        self.init(message: "\(message)\(position)")
    }
}

public struct IRBinding {
    let ref: IRValue
    
    let read: () -> IRValue
    let write: (IRValue) -> IRValue
    
    let type: TypeProtocol
    let irType: IRType
    
    static func create(builder: IRBuilder, type: TypeProtocol, irType: IRType, name: String, initial: IRValue, isFunctionParameter: Bool = false) -> IRBinding {
        if isFunctionParameter {
            let write = { builder.buildStore($0, to: initial) }
            
            return IRBinding(ref: initial, read: { initial }, write: write, type: type, irType: irType)
        }
        
        let alloca = builder.buildAlloca(type: irType, name: name)
        
        builder.buildStore(initial, to: alloca)
        
        let read = { return isFunctionParameter ? initial : builder.buildLoad(alloca) }
        let write = { builder.buildStore($0, to: isFunctionParameter ? initial : alloca) }
        
        return IRBinding(ref: alloca, read: read, write: write, type: type, irType: irType)
    }
}

class BuiltIn {
    static let NativeIntType = IntType(width: MemoryLayout<Int>.size * 8)
    static let NativeRealType = FloatType.double
    
    static let IntIntPlusFn = FunctionType(argTypes: [BuiltIn.NativeIntType, BuiltIn.NativeIntType], returnType: BuiltIn.NativeIntType)
    static let Printf = FunctionType(argTypes: [PointerType(pointee: IntType.int8)], returnType: IntType.int32, isVarArg: true)
    
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

public enum NameMode {
    case Relative
    case Absolute
}

public struct Name : Hashable {
    public let relativeName: String
    public let absoluteName: String
    
    public var hashValue: Int {
        return relativeName.hashValue ^ absoluteName.hashValue &* 16777619
    }
    
    public static func ==(lhs: Name, rhs: Name) -> Bool {
        return lhs.absoluteName == rhs.absoluteName && lhs.relativeName == rhs.relativeName
    }
}

public class Mangler {
    
    public static func mangle(name: String) -> String {
        return name.replacingOccurrences(of: ":", with: ".")
    }
}

//public typealias GeneratorInput = (context: CompilationContext, typeMap: [Int : TypeProtocol], ast: APIExpression)

public class LLVMGenerator : CompilationPhase {
    public typealias InputType = CompilationContext
    public typealias OutputType = Module
    
    private var builder: IRBuilder!
    private(set) var module: Module!
    
    private var typeMap: [Int : TypeProtocol] = [:]
    private var llvmTypeMap: [Name : IRType] = [
        Name(relativeName: "Int", absoluteName: "Int") : BuiltIn.NativeIntType,
        Name(relativeName: "Real", absoluteName: "Real") : BuiltIn.NativeRealType,
        
        Name(relativeName: "Bool", absoluteName: "Bool") : IntType.int1,
        Name(relativeName: "Int8", absoluteName: "Int8") : IntType.int8,
        Name(relativeName: "Int16", absoluteName: "Int16") : IntType.int16,
        Name(relativeName: "Int32", absoluteName: "Int32") : IntType.int32,
        Name(relativeName: "Int64", absoluteName: "Int64") : IntType.int64,
        Name(relativeName: "Int128", absoluteName: "Int128") : IntType.int128,
        Name(relativeName: "String", absoluteName: "String") : IntType.int8
    ]
    
    public init() {}
    
    func mangle(name: String) -> String {
        return Mangler.mangle(name: name)
    }
    
    func defineLLVMType(type: TypeProtocol, llvmType: IRType, position: SourcePosition) throws {
        let relativeNames = self.llvmTypeMap.keys.map { $0.relativeName }
        guard !relativeNames.contains(type.name) else { throw OrbitError(message: "Attempted to redefine type '\(type.name)'", position: position) }
        
        let absoluteNames = self.llvmTypeMap.keys.map { $0.absoluteName }
        guard !absoluteNames.contains(type.name) else { throw OrbitError(message: "Attempted to redefine type '\(type.name)'", position: position) }
        
        try self.llvmTypeMap[Name(relativeName: type.name, absoluteName: type.absoluteName())] = llvmType
    }
    
    func lookupType(expr: Expression) throws -> TypeProtocol {
        guard let type = self.typeMap[expr.hashValue] else {
            throw OrbitError(message: "Type of expression '\(expr)' could not be deduced", position: expr.startToken.position)
        }
        
        return type
    }
    
    func lookupLLVMType(type: TypeProtocol, position: SourcePosition) throws -> IRType {
        if let listType = type as? ListType {
            let elementType = try lookupLLVMType(type: listType.elementType, position: position)
            
            return PointerType(pointee: elementType)
        }
        
        guard let t = self.llvmTypeMap[try type.fullName()] else {
            throw OrbitError(message: "Unknown type: \(type.name)", position: position)
        }
        
        guard type is ValueType else { return PointerType(pointee: t) }
        
        return t
    }
    
    func lookupFunction(named: String, position: SourcePosition) throws -> Function {
        guard let fn = self.module.function(named: named) else {
            throw OrbitError(message: "Undefined function: \(named)", position: position)
        }
        
        return fn
    }
    
    func lookupLLVMType(hashValue: Int, position: SourcePosition) throws -> IRType {
        guard let type = self.typeMap[hashValue] else {
            throw OrbitError(message: "FATAL")
        }
        
        return try self.lookupLLVMType(type: type, position: position)
    }
    
    func generateTypeDef(expr: TypeDefExpression) throws {
        let type = try self.lookupType(expr: expr)
        
        let propertyTypes = try expr.properties.map { pair in
            return try self.lookupLLVMType(hashValue: pair.type.hashValue, position: expr.startToken.position)
        }
        
        let irType = self.builder.createStruct(name: type.name, types: propertyTypes)
        
        try self.defineLLVMType(type: type, llvmType: irType, position: expr.startToken.position)
        
        // Auto-generate constructor methods
        
        try expr.constructorSignatures.forEach { signature in
            let fnType = try self.generateSharedMethodComponents(expr: signature)
            
            let argTypeNames = signature.parameters.map { $0.type.value }.joined(separator: ".")
            
            let fn = self.builder.addFunction("\(type.name).\(signature.name.value).\(argTypeNames)", type: fnType) // TODO - Add param types to name
            _ = self.generateEntryBlock(function: fn)
            
            if type is ValueType {
                _ = self.builder.buildRet(StructType.constant(values: fn.parameters))
                return
            }
            
            let alloca = self.builder.buildAlloca(type: irType)
            
            fn.parameters.enumerated().forEach { pair in
                let gep = self.builder.buildStructGEP(alloca, index: pair.offset)
                
                self.builder.buildStore(pair.element, to: gep)
            }
            
            
            _ = self.builder.buildRet(alloca)
        }
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
        
        let fn = try self.lookupFunction(named: opName, position: expr.startToken.position)
        let call = self.builder.buildCall(fn, args: [left, right])
        
        // `call` holds the result of `left op right` (really `op(left, right)`)
        return call
    }
    
    func generateVariableRef(expr: IdentifierExpression, dereference: Bool = true, enclosingScope: Scope) throws -> IRValue {
        // TODO - For now, all variables are pointers.
        // Value types will come later.
        
        let ptr = try enclosingScope.lookupVariable(named: expr.value, position: expr.startToken.position)
        
        return dereference ? ptr.read() : ptr.ref
    }
    
    func generatePropertyAccess(expr: PropertyAccessExpression, enclosingScope: Scope) throws -> IRValue {
        guard let type = try self.lookupType(expr: expr) as? PropertyAccessType else {
            throw OrbitError(message: "FATAL")
        }
        
        guard let idx = type.receiverType.propertyOrder[expr.propertyName.value] else {
            throw OrbitError(message: "Property '\(expr.propertyName.value)' not found for type '\(type.receiverType.name)'", position: expr.startToken.position)
        }
        
        let val = try self.generateValue(expr: expr.receiver, dereferencePointer: true, scope: enclosingScope)
        
        // TODO - Always dereference the GEP?
        
        let alloca = self.builder.buildStructGEP(val, index: idx)
        
        return self.builder.buildLoad(alloca)
    }
    
    func generateList(expr: ListExpression, scope: Scope) throws -> IRValue {
        let listType = try self.lookupType(expr: expr) as! ListType
        //let arrType = try self.lookupLLVMType(type: listType)
        let elementType = try self.lookupLLVMType(type: listType.elementType, position: expr.startToken.position)
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
    
    func generateStringValue(expr: StringLiteralExpression) throws -> IRValue {
        // TODO - String interpolation, ideally mimic Swift's "Hello, \(name)!" syntax
        
        let str = self.builder.buildGlobalStringPtr(expr.value)
        
        return str
    }
    
    func generateValue(expr: Expression, dereferencePointer: Bool = true, scope: Scope) throws -> IRValue {
        switch expr {
        case is IdentifierExpression: return try self.generateVariableRef(expr: expr as! IdentifierExpression, dereference: dereferencePointer, enclosingScope: scope)
            case is IntLiteralExpression: return try self.generateIntValue(expr: expr as! IntLiteralExpression)
            case is RealLiteralExpression: return try self.generateRealValue(expr: expr as! RealLiteralExpression)
            case is StringLiteralExpression: return try self.generateStringValue(expr: expr as! StringLiteralExpression)
            
            case is BinaryExpression: return try self.generateBinaryExpression(expr: expr as! BinaryExpression, scope: scope)
            case is PropertyAccessExpression: return try self.generatePropertyAccess(expr: expr as! PropertyAccessExpression, enclosingScope: scope)
            case is AssignmentStatement: return try self.generateAssignment(expr: expr as! AssignmentStatement, scope: scope)
            case is ListExpression: return try self.generateList(expr: expr as! ListExpression, scope: scope)
            case is IndexAccessExpression: return try self.generateIndexAccess(expr: expr as! IndexAccessExpression, scope: scope)
            case is StaticCallExpression: return try self.generateStaticCall(expr: expr as! StaticCallExpression, scope: scope)
            case is InstanceCallExpression: return try self.generateInstanceCall(expr: expr as! InstanceCallExpression, scope: scope)
            
            default: throw OrbitError(message: "Expression \((expr as! GroupableExpression).dump()) does not yield a value", position: expr.startToken.position)
        }
    }
    
    func generateReturn(expr: ReturnStatement, scope: Scope) throws -> IRValue {
        let retVal = try self.generateValue(expr: expr.value, scope: scope)
        
        return self.builder.buildRet(retVal)
    }
    
    func generateAssignment(expr: AssignmentStatement, scope: Scope) throws -> IRValue {
        // TODO - Value types
        
        let valueType = try self.lookupType(expr: expr.value)
        
        let irType = try self.lookupLLVMType(type: valueType, position: expr.startToken.position)
        let value = try self.generateValue(expr: expr.value, scope: scope)
        let binding = IRBinding.create(builder: self.builder, type: valueType, irType: irType, name: expr.name.value, initial: value)
        
        try scope.defineVariable(named: expr.name.value, binding: binding, position: expr.startToken.position)
        
        return value
    }
    
    func generateStaticCall(expr: StaticCallExpression, scope: Scope) throws -> IRValue {
        let argTypes = try expr.args.map { try self.lookupType(expr: $0).name }.joined(separator: ".")
        
        let name = Mangler.mangle(name: "\(expr.receiver.value).\(expr.methodName.value).\(argTypes)")
        let fn = try self.lookupFunction(named: name, position: expr.startToken.position)
        let args = try expr.args.map { try self.generateValue(expr: $0, scope: scope) }
        
        return self.builder.buildCall(fn, args: args)
    }
    
    func generateInstanceCall(expr: InstanceCallExpression, scope: Scope) throws -> IRValue {
        let receiverType = try self.lookupType(expr: expr.receiver)
        let selfValue = try self.generateValue(expr: expr.receiver, scope: scope)
        let selfType = try lookupType(expr: expr.receiver)
        var args = [selfValue]
        var argTypes = [selfType.name]
        
        try expr.args.forEach { arg in
            let value = try self.generateValue(expr: arg, scope: scope)
            args.append(value)
            
            let type = try lookupType(expr: arg)
            argTypes.append(type.name)
        }
        
        let name = Mangler.mangle(name: "\(receiverType.name).\(expr.methodName.value).\(argTypes.map { $0 }.joined(separator: "."))")
        let fn = try self.lookupFunction(named: name, position: expr.startToken.position)
        
        return self.builder.buildCall(fn, args: args)
    }
    
    func generateStringDebug(value: IRValue) {
        guard let puts = self.module.function(named: "printf") else {
            let strType = PointerType(pointee: IntType.int8)
            let putsType = FunctionType(argTypes: [strType], returnType: IntType.int32)
            let puts = self.builder.addFunction("puts", type: putsType)
            
            _ = self.builder.buildCall(puts, args: [value])
            
            return
        }
        
        _ = self.builder.buildCall(puts, args: [value])
    }
    
//    func generateIntDebug(value: IRValue) {
//        guard let putd = self.module.function(named: "puts") else {
//            let strType = PointerType(pointee: IntType.int8)
//            let putsType = FunctionType(argTypes: [strType], returnType: IntType.int32)
//            let puts = self.builder.addFunction("puts", type: putsType)
//            
//            _ = self.builder.buildCall(puts, args: [value])
//            
//            return
//        }
//        
//        _ = self.builder.buildCall(puts, args: [value])
//    }
    
    private func derefPointer(value: IRValue) -> IRValue {
        let kind = LLVMGetTypeKind(value.type.asLLVM())
        
        if kind == LLVMPointerTypeKind {
            let load = self.builder.buildLoad(value)
            return derefPointer(value: load)
        }
        
        return value
    }
    
    private func fmtString(value: IRValue, type: TypeProtocol, position: SourcePosition) throws -> String {
        let kind = LLVMGetTypeKind(value.type.asLLVM())
        var fmt = ""
        
        if kind == LLVMIntegerTypeKind {
            fmt = "%d\n"
        } else if kind == LLVMFloatTypeKind {
            fmt = "%f\n"
        } else if kind == LLVMPointerTypeKind {
            let deref = derefPointer(value: value)
            
            let pointeeKind = LLVMGetTypeKind(deref.type.asLLVM())
            
            if type == ReferenceType.StringType {
                return "%s\n"
            }
            
            if pointeeKind == LLVMStructTypeKind {
                // TODO - StringValue trait
                throw OrbitError(message: "Struct debugging is not currently supported", position: position)
            } else {
                return try fmtString(value: deref, type: type, position: position)
            }
        } else {
            throw OrbitError(message: "Cannot debug value of type '\(type.name)'", position: position)
        }
        
        return fmt
    }
    
    func generateDebug(expr: DebugExpression, scope: Scope) throws -> IRValue? {
        let valueType = try self.lookupType(expr: expr.debuggable)
        let value = try self.generateValue(expr: expr.debuggable, scope: scope)
        
        guard let printf = self.module.function(named: "printf") else {
            throw OrbitError(message: "FATAL: No printf", position: expr.startToken.position)
        }
        
        let fmt = try fmtString(value: value, type: valueType, position: expr.startToken.position)
        
        let fmtStr = self.builder.buildGlobalStringPtr(fmt)
        
        _ = self.builder.buildCall(printf, args: [fmtStr, value])
        
        return nil
    }
    
    func generate(expr: Expression, scope: Scope) throws -> IRValue? {
        switch expr {
            case is ValueExpression: return try self.generateValue(expr: expr, scope: scope)
            case is ReturnStatement: return try self.generateReturn(expr: expr as! ReturnStatement, scope: scope)
            case is AssignmentStatement: return try self.generateAssignment(expr: expr as! AssignmentStatement, scope: scope)
            case is StaticCallExpression: return try self.generateStaticCall(expr: expr as! StaticCallExpression, scope: scope)
            case is InstanceCallExpression: return try self.generateInstanceCall(expr: expr as! InstanceCallExpression, scope: scope)
            case is DebugExpression: return try self.generateDebug(expr: expr as! DebugExpression, scope: scope)
            
            default: throw OrbitError(message: "Could not evaluate expression: \(expr)", position: expr.startToken.position)
        }
    }
    
    func generateSharedMethodComponents(expr: StaticSignatureExpression) throws -> FunctionType {
        let argTypes: [IRType] = try expr.parameters.map { param in
            //let type = try self.lookupType(expr: param.type)
            let irType = try self.lookupLLVMType(hashValue: param.type.hashValue, position: expr.startToken.position)
            
            //guard type is ValueType else { return PointerType(pointee: irType) }
            
            return irType
        }
        
        var retType: IRType = LLVM.VoidType()
        
        if let ret = expr.returnType {
            retType = try self.lookupLLVMType(hashValue: ret.hashValue, position: ret.startToken.position)
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
            let irType = try self.lookupLLVMType(hashValue: element.type.hashValue, position: element.startToken.position)
            
            let binding = IRBinding.create(builder: self.builder, type: type, irType: irType, name: element.name.value, initial: function.parameters[offset], isFunctionParameter: true)
            
            try signatureType.scope.defineVariable(named: element.name.value, binding: binding, position: element.startToken.position)
        }
    }
    
    func generateMethodBody(body: [Expression], signatureType: TypeProtocol) throws {
        try body.forEach { statement in
            _ = try self.generate(expr: statement, scope: signatureType.scope)
        }
    }
    
    func generateMethod(expr: MethodExpression, signatureType: TypeProtocol, receiverName: String, functionName: String) throws {
        let funcType = try self.generateSharedMethodComponents(expr: expr.signature)
        
        let fn = self.builder.addFunction(functionName, type: funcType)
        _ = self.generateEntryBlock(function: fn)
        
        try self.generateMethodParams(params: expr.signature.parameters, function: fn, signatureType: signatureType)
        
        // Check for empty methods that should have a return statement
        // And for superfluous return statements
        try Correctness.ensureMethodReturnCorrectness(expr: expr)
        
        try self.generateMethodBody(body: expr.body, signatureType: signatureType)
        
        if expr.signature.returnType == nil {
            _ = self.builder.buildRetVoid()
        }
    }
    
    func generateStaticMethod(expr: MethodExpression) throws {
        _ = try self.lookupLLVMType(hashValue: expr.signature.receiverType.hashValue, position: expr.startToken.position)
        let sigType = try self.lookupType(expr: expr.signature)
        
        try self.generateMethod(expr: expr, signatureType: sigType, receiverName: expr.signature.receiverType.value, functionName: expr.signature.name.value)
    }
    
    func generateMain() throws {
        // TODO - We'll handle this better once imports are working
        let fnType = FunctionType(argTypes: [IntType.int32, PointerType(pointee: PointerType(pointee: IntType.int8))], returnType: IntType.int32)
        let fn = self.builder.addFunction("main", type: fnType)
        let entry = fn.appendBasicBlock(named: "entry")
        
        self.builder.positionAtEnd(of: entry)
        
        guard let userMain = self.module.function(named: "Main.Main.main.Main.Main") else {
            throw OrbitError(message: "Expected to find method '(Main) main (Main) ()'")
        }
        
        guard let mainType = self.module.type(named: "Main.Main") else {
            throw OrbitError(message: "APIs tagged as Main Must declare a type Main(argc Int, argv [String])")
        }
        
        let alloca = self.builder.buildAlloca(type: mainType)
        
        let gep1 = self.builder.buildStructGEP(alloca, index: 0)
        let gep2 = self.builder.buildStructGEP(alloca, index: 1)
        
        _ = self.builder.buildStore(fn.parameters[0], to: gep1)
        _ = self.builder.buildStore(fn.parameters[1], to: gep2)
        
        _ = self.builder.buildCall(userMain, args: [alloca])
        _ = self.builder.buildRet(IntType.int32.constant(0))
    }
    
    public func execute(input: CompilationContext) throws -> Module {
        self.typeMap = input.expressionTypeMap
        
        guard let ast = input.mergedAPI else { throw OrbitError(message: "FATAL: APIs not merged") }
        
        self.module = Module(name: ast.name.value)
        self.builder = IRBuilder(module: self.module)
        
        // BUILT-INS
        _ = BuiltIn.generateIntIntPlusFn(builder: self.builder)
        _ = self.builder.addFunction("printf", type: BuiltIn.Printf)
        
        let typeDefs = ast.body.filter { $0 is TypeDefExpression }
        let staticMethodDefs = ast.body.filter { $0 is MethodExpression }
        
        try typeDefs.forEach { try self.generateTypeDef(expr: $0 as! TypeDefExpression) }
        try staticMethodDefs.forEach { try self.generateStaticMethod(expr: $0 as! MethodExpression) }
        
        if input.hasMain {
            try self.generateMain()
        }
        
        return self.module
    }
}
