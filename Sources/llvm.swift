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

struct CompContext {
    fileprivate let module: Module
    fileprivate let builder: IRBuilder
    
    private let types = [String : IRType]()
    
    init(name: String) {
        self.module = Module(name: name)
        self.builder = IRBuilder(module: self.module)
    }
    
    func find(type: TypeRecord) throws -> IRType {
        guard let t = self.types[type.fullName] else {
            throw OrbitError(message: "Type '\(type.fullName)' not defined")
        }
        
        return t
    }
    
    func gen() {
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

class TypeGen : IRTypeGenerator<TypeDefExpression> {
    override func generate(context: CompContext, expression: TypeDefExpression) throws -> IRType {
        let nodeType = try TypeUtils.extractType(fromExpression: expression)
        
        return context.builder.createStruct(name: nodeType.typeRecord.fullName)
    }
}

struct OrbitAPI {
    let context: CompContext
    let name: String
}

class APIGen : AbstractLLVMGenerator<APIExpression, OrbitAPI> {
    
    override func generate(context: CompContext, expression: APIExpression) throws -> OrbitAPI {
        let typeDefs = expression.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        let typeGen = TypeGen()
        
        try typeDefs.forEach {
            _ = try typeGen.generate(context: context, expression: $0)
        }
        
        return OrbitAPI(context: context, name: context.module.name)
    }
}

class LLVMGen : CompilationPhase {
    typealias InputType = RootExpression
    typealias OutputType = [OrbitAPI]
    
    let session: OrbitSession
    
    required init(session: OrbitSession) {
        self.session = session
    }
    
    func execute(input: RootExpression) throws -> [OrbitAPI] {
        let prog = input.body[0] as! ProgramExpression
        
        return try prog.apis.map {
            let nodeType = try TypeUtils.extractType(fromExpression: $0)
            let apiGen = APIGen()
            let context = CompContext(name: nodeType.typeRecord.fullName)
            
            return try apiGen.generate(context: context, expression: $0)
        }
    }
}
