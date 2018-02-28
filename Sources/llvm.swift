//
//  llvm.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 08/02/2018.
//

import Foundation
import OrbitCompilerUtils
import LLVM

struct CompContext {
    fileprivate let module: Module
    fileprivate let builder: IRBuilder
    
    private let types = [String : IRType]()
    
    init(name: String) {
        self.module = Module(name: name)
        self.builder = IRBuilder(module: self.module)
    }
    
    func find(type: Type) -> IRType {
        guard let t = self.types[type.name] else {
            return TypeGen.generate(context: self, type: type)
        }
        
        return t
    }
    
    func gen() {
        self.module.dump()
    }
}

class TypeGen {
    
    static func generate(context: CompContext, type: Type) -> IRType {
        return context.builder.createStruct(name: type.name)
    }
}

class LLVMGen : CompilationPhase {
    typealias InputType = ProgramType
    typealias OutputType = CompContext
    
    func execute(input: ProgramType) throws -> CompContext {
        let api = input.apis[0]
        let context = CompContext(name: api.name)
        
        api.declaredTypes.forEach {
            _ = context.find(type: $0)
        }
        
        return context
    }
}
