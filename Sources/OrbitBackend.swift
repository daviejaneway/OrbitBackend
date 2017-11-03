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
    
    static func create(builder: IRBuilder, type: TypeProtocol, irType: IRType, name: String, initial: IRValue, bypassAlloca: Bool = false) -> IRBinding {
        if bypassAlloca {
            let write = { builder.buildStore($0, to: initial) }
            
            return IRBinding(ref: initial, read: { initial }, write: write, type: type, irType: irType)
        }
        
        let alloca = builder.buildAlloca(type: irType, name: name)
        
        builder.buildStore(initial, to: alloca)
        
        let read = { return builder.buildLoad(alloca) }
        let write = { builder.buildStore($0, to: alloca) }
        
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
    
    private var stringPool = [String : IRValue]()
    
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
            
            let alloca = self.builder.buildMalloc(irType)
            
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
        
        let alloca = self.builder.buildStructGEP(val, index: idx)
        
        let l = self.builder.buildLoad(alloca)
        
        return l
    }
    
    func generateList(expr: ListExpression, scope: Scope) throws -> IRValue {
        let listType = try self.lookupType(expr: expr) as! ListType
        let elementType = try self.lookupLLVMType(type: listType.elementType, position: expr.startToken.position)
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
    
    func generateValue(expr: Expression, dereferencePointer: Bool = true, llvmName: String? = nil, scope: Scope) throws -> IRValue {
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
            case is StaticCallExpression: return try self.generateStaticCall(expr: expr as! StaticCallExpression, llvmName: llvmName ?? "", scope: scope)
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
        let value = try self.generateValue(expr: expr.value, llvmName: expr.name.value, scope: scope)
        let binding = IRBinding.create(builder: self.builder, type: valueType, irType: irType, name: expr.name.value, initial: value, bypassAlloca: true)
        
        try scope.defineVariable(named: expr.name.value, binding: binding, position: expr.startToken.position)
        
        return value
    }
    
    func generateStaticCall(expr: StaticCallExpression, llvmName: String, scope: Scope) throws -> IRValue {
        let argTypes = try expr.args.map { try self.lookupType(expr: $0).name }.joined(separator: ".")
        
        let name = Mangler.mangle(name: "\(expr.receiver.value).\(expr.methodName.value).\(argTypes)")
        let fn = try self.lookupFunction(named: name, position: expr.startToken.position)
        let args = try expr.args.map { try self.generateValue(expr: $0, scope: scope) }
        
        guard llvmName != "" else { return self.builder.buildCall(fn, args: args) }
        
        return self.builder.buildCall(fn, args: args, name: llvmName)
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
    
    private func fmtString(value: IRValue, type: TypeProtocol, newline: Bool = true, position: SourcePosition) throws -> (String, [IRValue]) {
        let kind = LLVMGetTypeKind(value.type.asLLVM())
        var fmt = ""
        
        let nl = "" //newline ? "\n" : ""
        
        if kind == LLVMIntegerTypeKind {
            fmt = "%lld\(nl)"
        } else if kind == LLVMFloatTypeKind {
            fmt = "%f\(nl)"
        } else if kind == LLVMDoubleTypeKind {
            fmt = "%f\(nl)"
        } else if kind == LLVMPointerTypeKind {
            let deref = derefPointer(value: value)
            
            let pointeeKind = LLVMGetTypeKind(deref.type.asLLVM())
            
            if pointeeKind == LLVMIntegerTypeKind {
                // Assume any int* is a string
                return ("%s\(nl)", [value])
            }
            
            if pointeeKind == LLVMStructTypeKind {
                // TODO - StringValue trait
                
                if let strct = type as? TypeDefType {
                    let fmts: [(String, IRValue)] = try strct.propertyTypes.enumerated().map { tup in
                        let gep = self.builder.buildStructGEP(value, index: tup.offset)
                        let val = self.builder.buildLoad(gep)
                        
                        let fmt = try fmtString(value: val, type: tup.element.value, newline: false, position: position)
                        
                        return ("\(tup.element.key):\(fmt.0)", fmt.1[0])
                    }
                    
                    let fmtStr = fmts.map { $0.0 }.joined(separator: ", ")
                    
                    return ("\(type.name)(\(fmtStr))", fmts.map { $0.1 })
                } else if let prop = type as? PropertyAccessType {
                    return try fmtString(value: value, type: prop.propertyType, newline: newline, position: position)
                }
                
                throw OrbitError(message: "Cannot debug value of type: \(type.name)", position: position)
            } else {
                return try fmtString(value: deref, type: type, newline: newline, position: position)
            }
        } else {
            throw OrbitError(message: "Cannot debug value of type '\(type.name)'", position: position)
        }
        
        return (fmt, [value])
    }
    
    func generatePrintf(fmtString: String, value: IRValue) {
        guard let printf = self.module.function(named: "printf") else {
            return
        }
        
        let fmtStr = self.builder.buildGlobalStringPtr(fmtString)
        
        _ = self.builder.buildCall(printf, args: [fmtStr, value])
    }
    
    // If we've already allocated a global string with this value, we can safely reuse it
    func globalStringPtr(str: String) -> IRValue {
        guard let ptr = self.stringPool[str] else {
            let ptr = self.builder.buildGlobalStringPtr(str)
            
            self.stringPool[str] = ptr
            
            return ptr
        }
        
        return ptr
    }
    
    func generateDebug(expr: DebugExpression, scope: Scope) throws -> IRValue? {
        let valueType = try self.lookupType(expr: expr.debuggable)
        let value = try self.generateValue(expr: expr.debuggable, scope: scope)
        
        guard let printf = self.module.function(named: "printf") else {
            throw OrbitError(message: "FATAL: No printf", position: expr.startToken.position)
        }
        
        let fmt = try fmtString(value: value, type: valueType, position: expr.startToken.position)
        
        let fmtStr = self.globalStringPtr(str: "\(fmt.0)\n")
        
        var arr = [fmtStr]
        arr.append(contentsOf: fmt.1)
        
        _ = self.builder.buildCall(printf, args: arr)
        
        return nil
    }
    
    func generate(expr: Expression, scope: Scope) throws -> IRValue? {
        switch expr {
            case is ReturnStatement: return try self.generateReturn(expr: expr as! ReturnStatement, scope: scope)
            case is AssignmentStatement: return try self.generateAssignment(expr: expr as! AssignmentStatement, scope: scope)
            case is StaticCallExpression: return try self.generateStaticCall(expr: expr as! StaticCallExpression, llvmName: "", scope: scope)
            case is InstanceCallExpression: return try self.generateInstanceCall(expr: expr as! InstanceCallExpression, scope: scope)
            case is DebugExpression: return try self.generateDebug(expr: expr as! DebugExpression, scope: scope)
            
            // Swift's generics aren't fit for purpose
            default: return try self.generateValue(expr: expr, scope: scope)
            //case is ValueExpression: return try self.generateValue(expr: expr, scope: scope)
            
            //default: throw OrbitError(message: "Could not evaluate expression: \(expr)", position: expr.startToken.position)
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
            
            let binding = IRBinding.create(builder: self.builder, type: type, irType: irType, name: element.name.value, initial: function.parameters[offset], bypassAlloca: false)
            
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
