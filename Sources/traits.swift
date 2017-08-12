//
//  traits.swift
//  OrbitBackend
//
//  Created by Davie Janeway on 11/08/2017.
//
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend

/**
    This compilation phase is responsible for generating
    specialised versions of trait methods for types that
    implement traits.
 */
public class TraitResolver : CompilationPhase {
    public typealias InputType = CompilationContext
    public typealias OutputType = CompilationContext
    
    private var context: CompilationContext?
    
    func specialise(method: MethodExpression, belongingTo: TraitDefExpression, forConcreteType: TypeDefExpression) throws -> Expression {
        // By this point, all names have been mangled, and we need to know this method's unmangled name.
        // Reverse lookup to get this method's unmangled name
        
        guard let unmangledNames = self.context?.methodNameMap[method.signature.name.value, .Relative] else {
            throw OrbitError(message: "FATAL")
        }
        
        guard unmangledNames.count == 1 else { throw OrbitError(message: "FATAL") }
        
        let paramNames = method.signature.parameters.map { $0.type.value }.joined(separator: ".")
        let name = "\(forConcreteType.name.value).\(unmangledNames[0].absoluteName).\(paramNames)"
        
        let id = IdentifierExpression(value: name, startToken: method.startToken)
        
        let signature = StaticSignatureExpression(name: id, receiverType: forConcreteType.name, parameters: method.signature.parameters, returnType: method.signature.returnType, genericConstraints: method.signature.genericConstraints, startToken: method.startToken)
        
        return MethodExpression(signature: signature, body: method.body, startToken: method.startToken)
    }
    
    public func execute(input: CompilationContext) throws -> CompilationContext {
        self.context = input
        
        // Iterate over all traits and, using their concrete method implementations,
        // generate specialisations for each implementing type.
        // Method may be overriden by the concrete type, so we need to check for that too.
        for traitMap in input.traitMethodMaps {
            // Get the list of concrete types that implement this trait
            let implementors = input.typeMethodMaps.filter { $0.type.adoptedTraits.contains(where: { $0.value == traitMap.trait.name.value }) }
            
            //print(traitMap.trait.name.value, implementors.map { $0.type.name.value })
            
            for typeMap in implementors {
                let generated = try traitMap.methods.map { try specialise(method: $0, belongingTo: traitMap.trait, forConcreteType: typeMap.type) }
                
                input.generatedMethods.append(contentsOf: generated)
            }
        }
        
        return input
    }
}
