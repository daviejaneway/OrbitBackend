//
//  llvm.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 08/02/2018.
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend
import LLVM

public class CompContext {
    private let name: String
    fileprivate let module: Module
    fileprivate let builder: IRBuilder
    fileprivate let phase: LLVMGen
    
    private var types = [String : IRType]()
    private var bindings = [String : IRValue]()
    
    let llvmGen: LLVMGen
    
    private var hashedNames = [String : String]()
    
    init(name: String, phase: LLVMGen, llvmGen: LLVMGen) {
        self.name = name
        self.module = Module(name: name)
        self.builder = IRBuilder(module: self.module)
        self.phase = phase
        self.llvmGen = llvmGen
    }
    
    private func hash(str: String) -> String {
        guard let hashed = hashedNames[str] else {
            let hashed = SHA1.hexString(from: str)!
            hashedNames[str] = hashed
            return hashed
        }
        
        return hashed
    }
    
    func addFunction(named: String, type: FunctionType) -> Function {
        guard let fn = self.module.function(named: named) else {
            let fn = self.builder.addFunction(hash(str: named), type: type)
            
            return fn
        }
        
        return fn
    }
    
    func createType(named: String, propertyTypes: [IRType]? = nil, isPacked: Bool = true) -> IRType {
        guard let type = self.module.type(named: named) else {
            let type = self.builder.createStruct(name: hash(str: named), types: propertyTypes, isPacked: isPacked)
            
            return type
        }
        
        return type
    }
    
    func function(named: String) -> Function? {
        return self.module.function(named: hash(str: named))
    }
    
    func type(named: String) -> IRType? {
        return self.module.type(named: hash(str: named))
    }
    
    func bind(value: IRValue, toName: String) {
        self.bindings[toName] = value
    }
    
    func lookup(bindingNamed named: String) throws -> IRValue {
        guard let value = self.bindings[named] else {
            throw OrbitError(message: "Name '\(named)' not bound in this context")
        }
        
        return value
    }
    
    func declare(type: AbstractTypeRecord, irType: IRType) {
        self.types[type.fullName] = irType
    }
    
    func find(type: AbstractTypeRecord, isArrayType: Bool) throws -> IRType {
        if let ir = self.llvmGen.aliasPool[type.fullName] {
            return isArrayType ? PointerType(pointee: ir) : ir
        }
        
        guard let t = self.types[type.fullName] else {
            throw OrbitError(message: "Type '\(type.fullName)' not defined")
        }
        
        return isArrayType ? PointerType(pointee: t) : t
    }
    
    public func gen() {
        self.module.dump()
    }
}

protocol LLVMGenerator {
    associatedtype ExpressionType: Expression
    associatedtype LLVMType
    
    func generate(context: CompContext, expression: ExpressionType) throws -> LLVMType
}

class AbstractLLVMGenerator<E: Expression, L> : LLVMGenerator {
    typealias ExpressionType = E
    typealias LLVMType = L
    
    func generate(context: CompContext, expression: E) throws -> L {
        return 0 as! L
    }
}

class IRTypeGenerator<E: AbstractExpression> : AbstractLLVMGenerator<E, IRType> {}
class IRValueGenerator<E: Expression> : AbstractLLVMGenerator<E, IRValue> {}

class IntLiteralGenerator : IRValueGenerator<IntLiteralExpression> {
    override func generate(context: CompContext, expression: IntLiteralExpression) throws -> IRValue {
        return IntType(width: 32).constant(expression.value)
    }
}

class RealLiteralGenerator : IRValueGenerator<RealLiteralExpression> {
    override func generate(context: CompContext, expression: RealLiteralExpression) throws -> IRValue {
        return FloatType.float.constant(expression.value)
    }
}

class ListLiteralGenerator : IRValueGenerator<ListLiteralExpression> {
    override func generate(context: CompContext, expression: ListLiteralExpression) throws -> IRValue {
        guard let genericType = try TypeUtils.extractType(fromExpression: expression).typeRecord as? GenericTypeRecord else { throw OrbitError(message: "FATAL Expected generic type") }
        
        // TODO - Support empty list
        guard genericType.typeParameters.count > 0 else { throw OrbitError(message: "FATAL empty list is unsupported") }
        
        //let baseType = try context.find(type: genericType.baseType, isArrayType: false)
        let elementType = try context.find(type: genericType.typeParameters[0], isArrayType: false)
        
        let ptr = ArrayType(elementType: elementType, count: expression.value.count).null()
        
        //let ptr = context.builder.buildAlloca(type: arrayType)
        
        let valueGen = ValueGenerator()
        let values = try (expression.value as! [AbstractExpression]).map { try valueGen.generate(context: context, expression: $0) }
        
        values.enumerated().forEach { _ = context.builder.buildInsertElement(vector: ptr, element: $0.element, index: IntType(width: 8).constant($0.offset)) }
        
        return ptr
    }
}

class ReferenceGenerator : IRValueGenerator<IdentifierExpression> {
    override func generate(context: CompContext, expression: IdentifierExpression) throws -> IRValue {
        return try context.lookup(bindingNamed: expression.value)
    }
}

class InfixGenerator : IRValueGenerator<BinaryExpression> {
    override func generate(context: CompContext, expression: BinaryExpression) throws -> IRValue {
        let valueGenerator = ValueGenerator()
        
        let meta = try TypeChecker.extractAnnotation(fromExpression: expression, annotationType: MetaDataAnnotation.self)
        let opFuncType = meta.data["OperatorFunction"]! as! AbstractTypeRecord
        let opFunc = context.function(named: opFuncType.fullName)! //context.module.function(named: opFuncType.fullName)!
        
        let lhs = try valueGenerator.generate(context: context, expression: expression.left)
        let rhs = try valueGenerator.generate(context: context, expression: expression.right)
        
        return context.builder.buildCall(opFunc, args: [lhs, rhs])
    }
}

class ConstructorGenerator : IRValueGenerator<ConstructorCallExpression> {
    override func generate(context: CompContext, expression: ConstructorCallExpression) throws -> IRValue {
        let typeRecord = try TypeUtils.extractType(fromExpression: expression).typeRecord
        let type = try context.find(type: typeRecord, isArrayType: false)
        let alloca = context.builder.buildAlloca(type: type)
        
        // TODO - Set constructor param values
        
        return alloca
    }
}

class ValueGenerator : IRValueGenerator<AbstractExpression> {
    override func generate(context: CompContext, expression: AbstractExpression) throws -> IRValue {
        switch expression {
            case is IntLiteralExpression: return try IntLiteralGenerator().generate(context: context, expression: expression as! IntLiteralExpression)
            case is RealLiteralExpression: return try RealLiteralGenerator().generate(context: context, expression: expression as! RealLiteralExpression)
            case is StaticCallExpression: return try StaticCallGenerator().generate(context: context, expression: expression as! StaticCallExpression)
            case is IdentifierExpression: return try ReferenceGenerator().generate(context: context, expression: expression as! IdentifierExpression)
            case is BinaryExpression: return try InfixGenerator().generate(context: context, expression: expression as! BinaryExpression)
            case is AnnotationExpression:
                let result = try (expression as! AnnotationExpression).execute(gen: context.phase)
                
                // TODO - Nil is valid here
                let ir = try TypeChecker.extractAnnotation(fromExpression: result, annotationType: IRValueAnnotation.self)
                
                return ir.value
            case is ListLiteralExpression: return try ListLiteralGenerator().generate(context: context, expression: expression as! ListLiteralExpression)
            
            case is ConstructorCallExpression: return try ConstructorGenerator().generate(context: context, expression: expression as! ConstructorCallExpression)
            
            default: throw OrbitError(message: "Expected Value expression, found \(expression)")
        }
    }
}

class StaticCallGenerator : IRValueGenerator<StaticCallExpression> {
    override func generate(context: CompContext, expression: StaticCallExpression) throws -> IRValue {
        let meta = try TypeChecker.extractAnnotation(fromExpression: expression, annotationType: MetaDataAnnotation.self)
        
        guard let methodName = meta.data["ExpandedMethodName"] as? String else {
            throw OrbitError(message: "FATAL Missing method name")
        }
        
        guard let fn = context.function(named: methodName) else {
            throw OrbitError(message: "FATAL Function not defined for name '\(methodName)'")
        }
        
        let args = try expression.args.map {
            return try ValueGenerator().generate(context: context, expression: $0 as! AbstractExpression)
        }
        
        let value = context.builder.buildCall(fn, args: args)
        
        return value
    }
}

class ReturnGenerator : IRValueGenerator<ReturnStatement> {
    override func generate(context: CompContext, expression: ReturnStatement) throws -> IRValue {
        let valueType = try TypeUtils.extractType(fromExpression: expression)
        
        expression.value.annotate(annotation: valueType)
        
        let value = try ValueGenerator().generate(context: context, expression: expression.value)
        
        context.builder.buildRet(value)
        
        return value
    }
}

class AssignmentGenerator : IRValueGenerator<AssignmentStatement> {
    override func generate(context: CompContext, expression: AssignmentStatement) throws -> IRValue {
        let rhs = try ValueGenerator().generate(context: context, expression: expression.value)
        
        context.bind(value: rhs, toName: expression.name.value)
        
        return rhs
    }
}

class StatementGenerator : IRValueGenerator<AbstractExpression> {
    override func generate(context: CompContext, expression: AbstractExpression) throws -> IRValue {
        switch expression {
            case is StaticCallExpression: return try StaticCallGenerator().generate(context: context, expression: expression as! StaticCallExpression)
            
            case is ReturnStatement: return try ReturnGenerator().generate(context: context, expression: expression as! ReturnStatement)
            
            case is AssignmentStatement: return try AssignmentGenerator().generate(context: context, expression: expression as! AssignmentStatement)
            
            default: return VoidType().null()
        }
    }
}

extension AnnotationExpression {
    func execute(gen: LLVMGen) throws -> AbstractExpression {
        guard let ext = gen.extensions[self.annotationName.value] else {
            throw OrbitError(message: "Extension \(self.annotationName.value) not defined for compilation phase \(gen.identifier)")
        }
        
        return try ext.execute(phase: gen, annotation: self)
    }
}

class BlockGen : IRValueGenerator<BlockExpression> {
    override func generate(context: CompContext, expression: BlockExpression) throws -> IRValue {
        try expression.body.forEach { expr in
            if let annotation = expr as? AnnotationExpression {
                let result = try annotation.execute(gen: context.phase)
                
                try expression.rewriteChildExpression(childExpressionHash: expr.hashValue, input: result)
            }
            
            _ = try StatementGenerator().generate(context: context, expression: expr as AbstractExpression)
        }
        
        guard let ret = expression.returnStatement else {
            context.builder.buildRetVoid()
            
            return VoidType().null()
        }
        
        return try ReturnGenerator().generate(context: context, expression: ret)
    }
}

class MethodGen : IRValueGenerator<MethodExpression> {
    override func generate(context: CompContext, expression: MethodExpression) throws -> IRValue {
        let nodeType = try TypeUtils.extractType(fromExpression: expression)
        
        var retType: IRType = VoidType()
        
        if let rt = expression.signature.returnType {
            let nt = try TypeUtils.extractType(fromExpression: rt)
            
            retType = try context.find(type: nt.typeRecord, isArrayType: rt is ListTypeIdentifierExpression)
        }
        
        let argTypes: [IRType] = try expression.signature.parameters.map {
            let nt = try TypeUtils.extractType(fromExpression: $0)
            let type = try context.find(type: nt.typeRecord, isArrayType: $0.type is ListTypeIdentifierExpression)
            
            return type
        }
        
        let fnType = FunctionType(argTypes: argTypes, returnType: retType)
        let fn = context.addFunction(named: nodeType.typeRecord.fullName, type: fnType)
        
        try expression.signature.parameters.enumerated().forEach { param in
            guard let arg = fn.parameter(at: param.offset) else { throw OrbitError(message: "FATAL No argument at idx \(param.offset)") }
            
            context.bind(value: arg, toName: param.element.name.value)
        }
        
        let entry = fn.appendBasicBlock(named: "entry")
        
        context.builder.positionAtEnd(of: entry)
        
        let blockGen = BlockGen()
        _ = try blockGen.generate(context: context, expression: expression.body)
        
        return fn
    }
}

class TypeGen : IRTypeGenerator<TypeDefExpression> {
    override func generate(context: CompContext, expression: TypeDefExpression) throws -> IRType {
        let nodeType = try TypeUtils.extractType(fromExpression: expression)
        let type = context.createType(named: nodeType.typeRecord.fullName)
        
        context.declare(type: nodeType.typeRecord, irType: type)
        
        return type
    }
}

public struct OrbitAPI {
    public let context: CompContext
    public let name: String
}

class APIGen : AbstractLLVMGenerator<APIExpression, OrbitAPI> {
    private let name: String
    
    init(name: String) {
        self.name = name
    }
    
    override func generate(context: CompContext, expression: APIExpression) throws -> OrbitAPI {
        let typeDefs = expression.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        let typeGen = TypeGen()
        
        try typeDefs.forEach {
            _ = try typeGen.generate(context: context, expression: $0)
        }
        
        let annnotationExpressions = expression.body.filter { $0 is AnnotationExpression } as! [AnnotationExpression]
        let llvmAnnotations = annnotationExpressions.filter { $0.annotationName.value.starts(with: context.phase.identifier) }
        
        try llvmAnnotations.forEach { expr in
            guard let ext = context.phase.extensions[expr.annotationName.value] else {
                throw OrbitError(message: "Extension \(expr.annotationName.value) not defined for compilation phase \(context.phase.identifier)")
            }
            
            let result = try ext.execute(phase: context.phase, annotation: expr)
            
            try expression.rewriteChildExpression(childExpressionHash: expr.hashValue, input: result)
        }
        
        let methods = expression.body.filter { $0 is MethodExpression } as! [MethodExpression]
        let methodGen = MethodGen()
        
        try methods.forEach {
            _ = try methodGen.generate(context: context, expression: $0)
        }
        
        return OrbitAPI(context: context, name: self.name)
    }
}

/// Inserts a main method that can be called by the LLVM toolchain
class EntryPointExtension : PhaseExtension {
    static let identifier = "LLVM.EntryPoint"
    let extensionName = EntryPointExtension.identifier
    let parameterTypes: [AbstractExpression.Type] = []
    
    func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        let mainMethodExpression = annotation.parameters[0] as! MethodExpression
        let llvmMainIdentifier = IdentifierExpression(value: "main", startToken: annotation.startToken)
        let llvmMainReceiver = mainMethodExpression.signature.receiverType
        let llvmMainParams = mainMethodExpression.signature.parameters
        let llvmMainReturn = mainMethodExpression.signature.returnType
        let llvmMainSignature = StaticSignatureExpression(name: llvmMainIdentifier, receiverType: llvmMainReceiver, parameters: llvmMainParams, returnType: llvmMainReturn, genericConstraints: nil, startToken: annotation.startToken)
        
        let llvmMainMethod = MethodExpression(signature: llvmMainSignature, body: mainMethodExpression.body, startToken: annotation.startToken)
        
        llvmMainMethod.annotate(annotation: TypeAnnotation(typeRecord: TypeRecord(shortName: "main", fullName: "main")))
        
        return llvmMainMethod
    }
}

class IntegerAliasExtension : PhaseExtension {
    static let identifier = "LLVM.IntegerAlias"
    
    let extensionName = IntegerAliasExtension.identifier
    let parameterTypes: [AbstractExpression.Type] = [TypeIdentifierExpression.self, IntLiteralExpression.self]
    
    func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        guard let llvm = phase as? LLVMGen else { throw OrbitError(message: "FATAL Unexpected phase: '\(phase)'") }
        
        let typeId = annotation.parameters[0] as! TypeIdentifierExpression
        let width = annotation.parameters[1] as! IntLiteralExpression
        
        llvm.aliasPool[typeId.value] = IntType(width: width.value)
        
        return annotation
    }
}

class FloatAliasExtension : PhaseExtension {
    static let identifier = "LLVM.FloatAlias"
    
    let extensionName = FloatAliasExtension.identifier
    let parameterTypes: [AbstractExpression.Type] = [TypeIdentifierExpression.self, IntLiteralExpression.self]
    
    func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        guard let llvm = phase as? LLVMGen else { throw OrbitError(message: "FATAL Unexpected phase: '\(phase)'") }
        
        let typeId = annotation.parameters[0] as! TypeIdentifierExpression
        let width = annotation.parameters[1] as! IntLiteralExpression
        
        let kind: FloatType.Kind
        switch width.value {
            case 16: kind = .half
            case 32: kind = .float
            case 64: kind = .double
            case 80: kind = .x86FP80
            case 128: kind = .fp128
            default: throw OrbitError(message: "LLVM Float types have width 16, 32, 64, 80 or 128")
        }
        
        llvm.aliasPool[typeId.value] = FloatType(kind: kind)
        
        return annotation
    }
}

class IRValueAnnotation : DebuggableAnnotation {
    let identifier = "Orb.Core.Backend.Annotations.LLVM.IRValue"
    let value: IRValue
    
    init(value: IRValue) {
        self.value = value
    }
    
    func dump() -> String {
        return ""
    }
    
    func equal(toOther annotation: Annotation) -> Bool {
        return false
    }
}

/*
    This is a very rough first attempt at PhaseExtensions
 */

class PrintIntExtension : PhaseExtension {
    let extensionName = "Printi"
    let parameterTypes: [AbstractExpression.Type] = []
    
    func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        let llvmGen = phase as! LLVMGen
        let context = llvmGen.currentContext!
        
        let ival = try ValueGenerator().generate(context: context, expression: annotation.parameters[0])
        let fmt = context.builder.buildGlobalString("\(ival)")
        
        let putsFn = FunctionType(argTypes: [fmt.type], returnType: IntType(width: 32))
        let puts = context.builder.addFunction("puts", type: putsFn)
        
        _ = context.builder.buildCall(puts, args: [fmt])
        
        return annotation
    }
}

class InsertAddExtension : PhaseExtension {
    let extensionName: String = "Add"
    let parameterTypes: [AbstractExpression.Type] = [IdentifierExpression.self, IdentifierExpression.self]
    
    func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        let llvmGen = phase as! LLVMGen
        let context = llvmGen.currentContext!
        
        let lhs = try ValueGenerator().generate(context: context, expression: annotation.parameters[0])
        let rhs = try ValueGenerator().generate(context: context, expression: annotation.parameters[1])
        
        let result = context.builder.buildAdd(lhs, rhs)
        
        annotation.annotate(annotation: IRValueAnnotation(value: result))
        
        return annotation
    }
}

class InsertUnaryMinusExtension : PhaseExtension {
    let extensionName = "Neg"
    let parameterTypes: [AbstractExpression.Type] = [IntLiteralExpression.self]
    
    func execute<T>(phase: T, annotation: AnnotationExpression) throws -> AbstractExpression where T : CompilationPhase {
        let llvmGen = phase as! LLVMGen
        let context = llvmGen.currentContext!
        
        let operand = try ValueGenerator().generate(context: context, expression: annotation.parameters[0])
        let result = context.builder.buildNeg(operand)
        
        annotation.annotate(annotation: IRValueAnnotation(value: result))
        
        return annotation
    }
}

public class OrbitAPIAnnotation : DebuggableAnnotation {
    public let identifier = "Orb.Compiler.Backend.LLVM.OrbitAPIAnnotation"
    
    let apis: [OrbitAPI]
    
    init(apis: [OrbitAPI]) {
        self.apis = apis
    }
    
    public func equal(toOther annotation: Annotation) -> Bool {
        return self.identifier == annotation.identifier
    }
    
    public func dump() -> String {
        return "@OrbitAPI -> \(apis)"
    }
}

public class LLVMGen : CompilationPhase {
    public typealias InputType = (RootExpression, [APIMap])
    public typealias OutputType = [OrbitAPI]
    
    public let identifier = "LLVM"
    public let session: OrbitSession
    
    var aliasPool = [String : IRType]()
    
    var currentContext: CompContext? = nil
    
    fileprivate let extensions: [String : PhaseExtension] = [
        EntryPointExtension.identifier: EntryPointExtension(),
        IntegerAliasExtension.identifier: IntegerAliasExtension(),
        FloatAliasExtension.identifier: FloatAliasExtension(),
        "Add": InsertAddExtension(),
        "Printi": PrintIntExtension()
    ]
    
    public required init(session: OrbitSession, identifier: String = "") {
        self.session = session
    }
    
    public func execute(input: (RootExpression, [APIMap])) throws -> [OrbitAPI] {
        let prog = input.0.body[0] as! ProgramExpression
        
        return try prog.apis.map { api in
            let nodeType = try TypeUtils.extractType(fromExpression: api)
            let apiGen = APIGen(name: nodeType.typeRecord.fullName)
            let context = CompContext(name: nodeType.typeRecord.fullName, phase: self, llvmGen: self)
            
            if TypeChecker.isAnnotated(expression: api, withType: OrbitAPIAnnotation.self) {
                let libs = try TypeChecker.extractAnnotation(fromExpression: api, annotationType: OrbitAPIAnnotation.self).apis
                
                libs.forEach { lib in
                    _ = context.module.link(lib.context.module)
                }
            }
            
            self.currentContext = context
            
            input.1.forEach { apiMap in
                apiMap.exportedTypes.filter { $0.isImported }.forEach { xType in
                    let type = context.createType(named: xType.fullName)
                    context.declare(type: xType, irType: type)
                }
            }
            
            return try apiGen.generate(context: context, expression: api)
        }
    }
}
