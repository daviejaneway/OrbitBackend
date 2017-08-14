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

extension Array {
    var powerset: [[Element]] {
        guard count > 0 else { return [self] }
        
        let tail = Array(self[1..<endIndex])
        let head = self[0]
        
        let withoutHead = tail.powerset
        let withHead = withoutHead.map { $0 + [head] }
        
        return withHead + withoutHead
    }
}

/**
    This compilation phase is responsible for generating
    specialised versions of trait methods for types that
    implement traits.
 */
public class TraitResolver : CompilationPhase {
    public typealias InputType = CompilationContext
    public typealias OutputType = CompilationContext
    
    private var context: CompilationContext!
    
    public init() {}
    
    func specialise(parameter: PairExpression) throws -> [PairExpression] {
        guard self.context.traitNames.contains(parameter.type.value) else {
            // This param is a concrete type
            return [parameter]
        }
        
        let concretions = self.context.typeMethodMaps.filter { $0.type.adoptedTraits.map { $0.value }.contains(parameter.type.value) }
        
        guard concretions.count > 0 else {
            throw OrbitError(message: "Trait '\(parameter.type.value)' has no concrete implementations but is accepted as a parameter", position: parameter.startToken.position)
        }
        
        return concretions.map { PairExpression(name: parameter.name, type: $0.type.name, startToken: parameter.startToken) }
    }
    
    func specialise(allParameters: [PairExpression]) throws -> [PairExpression] {
        var specialisations = [PairExpression]()
        
        for param in allParameters {
            let spec = try specialise(parameter: param)
            
            specialisations.append(contentsOf: spec)
        }
        
        return specialisations
    }
    
    func specialise(method: MethodExpression, belongingTo: TraitDefExpression, forConcreteType: TypeDefExpression) throws -> [Expression] {
        // By this point, all names have been mangled, and we need to know this method's unmangled name.
        // Reverse lookup to get this method's unmangled name
        guard let unmangledNames = self.context?.methodNameMap[method.signature.name.value, .Relative] else {
            throw OrbitError(message: "FATAL")
        }
        
        guard unmangledNames.count == 1 else { throw OrbitError(message: "FATAL") }
        
        /*
            There are multiple branches in specialising a method.
                1) A specialisation against the receiver type for each type that implements this trait
                2) Parameters could also be of a trait type, meaning we need a specialisation for each combination
                    of receiver vs params
                3) The return type could also be a trait type
        */
        
        
        let specialisations = try specialise(allParameters: method.signature.parameters)
        
        // Its easier to generate all the powersets and pick out the ones we need
        // Probably not efficient
        let powersets = specialisations.powerset.filter { $0.count == method.signature.parameters.count }
        // Get rid of any subset that isn't of the correct length
        let valid1 = powersets.filter { $0.count == method.signature.parameters.count }
        
        let order = Dictionary(keyValuePairs: method.signature.parameters.enumerated().map { (key: $0.element.name.value, value: $0.offset) })
        
        var valid2 = [[PairExpression]]()
        for el in valid1 {
            var seen = Set<String>()
            for param in method.signature.parameters {
                guard el.contains(where: { $0.name.value == param.name.value }) else { continue } // Weird case
                
                seen.insert(param.name.value)
            }
            
            guard seen.count == method.signature.parameters.count else { continue } // If every parameter is matched, this will be true
            
            // No elements missing and guarenteed to be of correct length, therefore is a valid permutation
            
            let sorted = el.sorted { (a, b) -> Bool in
                let i = order[a.name.value]!
                let j = order[b.name.value]!
                
                return i < j
            }
            
            valid2.append(sorted)
            seen = Set<String>()
        }
        
        let valid3: [Expression] = valid2.map { paramSet in
            let paramNames = paramSet.map { $0.type.value }.joined(separator: ".")
            let name = "\(forConcreteType.name.value).\(unmangledNames[0].absoluteName).\(paramNames)"
            
            let id = IdentifierExpression(value: name, startToken: method.startToken)
            
            let signature = StaticSignatureExpression(name: id, receiverType: forConcreteType.name, parameters: paramSet, returnType: method.signature.returnType, genericConstraints: method.signature.genericConstraints, startToken: method.startToken)
            
            return MethodExpression(signature: signature, body: method.body, startToken: method.startToken)
        }
        
        if let ret = method.signature.returnType {
            guard self.context.traitNames.contains(ret.value) else { return valid3 } // Return type is a concrete type
            
            // TODO - Return types are not currently part of a method's mangled name, which means
            // returning something that implements a trait with multiple implementers causes an
            // ambiguity that we can't currently handle.
            // To fix this:
            //      1) Return type has to be part of method signature's mangled name
            //      2) Which means type annotations are needed in weird places
            // Static dispatch might not be enough. We might have to use dynamic dispatch.
            
            throw OrbitError(message: "Method '\(unmangledNames[0].absoluteName)' returns trait type '\(ret.value)' which causes an ambiguity in the current version of Orbit that is not supported", position: ret.startToken.position)
            
//            let concretions = self.context.typeMethodMaps.filter { $0.type.adoptedTraits.map { $0.value }.contains(ret.value) }
//            
//            guard concretions.count > 0 else {
//                throw OrbitError(message: "Trait '\(ret.value)' has no concrete implementations, but is returned from method '\(unmangledNames[0].absoluteName)'", position: ret.startToken.position)
//            }
            
//            return (valid3 as! [MethodExpression]).flatMap { method in
//                return concretions.flatMap { conc in
//                    
//                }
//            }
        }
        
        return valid3
    }
    
    public func execute(input: CompilationContext) throws -> CompilationContext {
        self.context = input
        
        // Iterate over all traits and, using their concrete method implementations,
        // generate specialisations for each implementing type.
        // Method may be overriden by the concrete type, so we need to check for that too.
        for traitMap in input.traitMethodMaps {
            // Get the list of concrete types that implement this trait
            let implementors = input.typeMethodMaps.filter { $0.type.adoptedTraits.contains(where: { $0.value == traitMap.trait.name.value }) }
            
            for typeMap in implementors {
                let generated = try traitMap.methods.flatMap { try specialise(method: $0, belongingTo: traitMap.trait, forConcreteType: typeMap.type) }
                
                input.generatedMethods.append(contentsOf: generated)
            }
        }
        
        print((input.generatedMethods as! [MethodExpression]).map { $0.signature.name.value })
        
        _ = try input.mergeAPIs()
        
        return input
    }
}
