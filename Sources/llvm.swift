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
    fileprivate let module: Module
    fileprivate let builder: IRBuilder
    fileprivate let phase: LLVMGen
    
    private var types = [String : IRType]()
    private var bindings = [String : IRValue]()
    
    init(name: String, phase: LLVMGen) {
        self.module = Module(name: name)
        self.builder = IRBuilder(module: self.module)
        self.phase = phase
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
    
    func find(type: AbstractTypeRecord) throws -> IRType {
        guard let t = self.types[type.fullName] else {
            throw OrbitError(message: "Type '\(type.fullName)' not defined")
        }
        
        return t
    }
    
    public func gen() {
        self.module.dump()
    }
}

protocol LLVMGenerator {
    associatedtype ExpressionType: AbstractExpression
    associatedtype LLVMType
    
    func generate(context: CompContext, expression: ExpressionType) throws -> LLVMType
}

class AbstractLLVMGenerator<E: AbstractExpression, L> : LLVMGenerator {
    typealias ExpressionType = E
    typealias LLVMType = L
    
    func generate(context: CompContext, expression: E) throws -> L {
        return 0 as! L
    }
}

class IRTypeGenerator<E: AbstractExpression> : AbstractLLVMGenerator<E, IRType> {}
class IRValueGenerator<E: AbstractExpression> : AbstractLLVMGenerator<E, IRValue> {}

class StaticCallGenerator : IRValueGenerator<StaticCallExpression> {
    override func generate(context: CompContext, expression: StaticCallExpression) throws -> IRValue {
        
        //let fn = context.module.function(named: <#T##String#>)
        return VoidType().null()
    }
}

class StatementGenerator : IRValueGenerator<AbstractExpression> {
    override func generate(context: CompContext, expression: AbstractExpression) throws -> IRValue {
        switch expression {
            case is StaticCallExpression: return try StaticCallGenerator().generate(context: context, expression: expression as! StaticCallExpression)
            
            default: return VoidType().null()
        }
    }
}

class BlockGen : IRValueGenerator<BlockExpression> {
    override func generate(context: CompContext, expression: BlockExpression) throws -> IRValue {
        try expression.body.forEach {
            _ = try StatementGenerator().generate(context: context, expression: $0 as! AbstractExpression)
        }
        
        return VoidType().null()
    }
}

class MethodGen : IRValueGenerator<MethodExpression> {
    override func generate(context: CompContext, expression: MethodExpression) throws -> IRValue {
        let nodeType = try TypeUtils.extractType(fromExpression: expression)
        
        var retType: IRType = VoidType()
        
        if let rt = expression.signature.returnType {
            let nt = try TypeUtils.extractType(fromExpression: rt)
            
            retType = try context.find(type: nt.typeRecord)
        }
        
        let argTypes: [IRType] = try expression.signature.parameters.map {
            let nt = try TypeUtils.extractType(fromExpression: $0)
            
            return try context.find(type: nt.typeRecord)
        }
        
        let fnType = FunctionType(argTypes: argTypes, returnType: retType)
        let fn = context.builder.addFunction(nodeType.typeRecord.fullName, type: fnType)
        
        let entry = fn.appendBasicBlock(named: "entry")
        
        context.builder.positionAtEnd(of: entry)
        context.builder.buildRetVoid()
        
        return fn
    }
}

class TypeGen : IRTypeGenerator<TypeDefExpression> {
    override func generate(context: CompContext, expression: TypeDefExpression) throws -> IRType {
        let nodeType = try TypeUtils.extractType(fromExpression: expression)
        let type = context.builder.createStruct(name: nodeType.typeRecord.fullName)
        
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
    let extensionName = "Orb.Compiler.Backend.LLVM.EntryPoint"
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

public class LLVMGen : CompilationPhase {
    public typealias InputType = RootExpression
    public typealias OutputType = [OrbitAPI]
    
    public let identifier = "Orb.Compiler.Backend.LLVM"
    public let session: OrbitSession
    
    fileprivate let extensions: [String : PhaseExtension] = [
        "Orb.Compiler.Backend.LLVM.EntryPoint": EntryPointExtension()
    ]
    
    public required init(session: OrbitSession, identifier: String = "") {
        self.session = session
    }
    
    public func execute(input: RootExpression) throws -> [OrbitAPI] {
        let prog = input.body[0] as! ProgramExpression
        
        return try prog.apis.map {
            let nodeType = try TypeUtils.extractType(fromExpression: $0)
            let apiGen = APIGen(name: nodeType.typeRecord.fullName)
            let context = CompContext(name: nodeType.typeRecord.fullName, phase: self)
            
            return try apiGen.generate(context: context, expression: $0)
        }
    }
}

//public class IRWriter : ExtendablePhase {
//    public typealias InputType = Module
//    public typealias OutputType = String
//
//    public let identifier = "Orb.Compiler.Backend.LLVM.IRWriter"
//    public let phaseName = "Orb.Compiler.Backend.LLVM.IRWriter"
//
//    public let extensions: [String : PhaseExtension] = [:]
//    public let session: OrbitSession
//
//    public required init(session: OrbitSession, identifier: String = "") {
//        self.session = session
//    }
//
//    public func execute(input: Module) throws -> String {
//        let ir = input.
//    }
//}

