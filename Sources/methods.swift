//
//  methods.swift
//  OrbitBackend
//
//  Created by Davie Janeway on 12/08/2017.
//
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend

/**
    This compilation phase is responsible for building
    a map of Type -> Method. Because methods definitions
    are not syntactically connected (types are extensible outside
    of their enclosing API) it is helpful to keep a record of
    which methods "belong" to which types.
 
    A method `foo` belongs to a type `A` if `foo's` receiver type is `A`.
 */
public struct TypeMethodMap {
    public let type: TypeDefExpression
    public let methods: [MethodExpression]
}

public struct TraitMethodMap {
    public let trait: TraitDefExpression
    public let methods: [MethodExpression]
}

public class MethodResolver : CompilationPhase {
    public typealias InputType = CompilationContext
    public typealias OutputType = CompilationContext
    
    func resolveType(expr: TypeDefExpression, methods: [MethodExpression]) -> TypeMethodMap {
        let owned = methods.filter { method in
            return method.signature.receiverType.value == expr.name.value
        }
        
        return TypeMethodMap(type: expr, methods: owned)
    }
    
    func resolveTrait(expr: TraitDefExpression, methods: [MethodExpression]) -> TraitMethodMap {
        let owned = methods.filter { method in
            return method.signature.receiverType.value == expr.name.value
        }
        
        return TraitMethodMap(trait: expr, methods: owned)
    }
    
    public func execute(input: CompilationContext) throws -> CompilationContext {
        for api in input.apis {
            let typeDefs = api.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
            let traitDefs = api.body.filter { $0 is TraitDefExpression } as! [TraitDefExpression]
            let methodDefs = api.body.filter { $0 is MethodExpression } as! [MethodExpression]
            
            let typeMaps = typeDefs.map { resolveType(expr: $0, methods: methodDefs) }
            let traitMaps = traitDefs.map { resolveTrait(expr: $0, methods: methodDefs) }
            
            input.typeMethodMaps = typeMaps
            input.traitMethodMaps = traitMaps
        }
        
        return input
    }
}
