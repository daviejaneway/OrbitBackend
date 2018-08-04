//
//  Graph.swift
//
//  Created by Davie Janeway on 09/05/2018.
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend

public class DependencyGraph : CompilationPhase {
    public typealias InputType = RootExpression
    public typealias OutputType = [APIExpression]
    
    public var identifier = "Orb.Compiler.Backend.DependencyGraph"
    public var session: OrbitSession
    
    private var apis: [APIExpression] = []
    private var map: [(String, String)] = []
    
    public required init(session: OrbitSession, identifier: String = "") {
        self.session = session
    }
    
    func seen(apiA: String, apiB: String) -> Bool {
        return self.map.contains { ($0.0 == apiA && $0.1 == apiB) }
    }
    
    func order(api: APIExpression) throws {
        var idx = apis.enumerated().filter { $0.element.hashValue == api.hashValue }[0].offset
        
        if let with = api.with {
            for w in with.withs {
                if w.value == api.name.value {
                    self.session.push(warning: OrbitWarning(message: "API \(api.name.value) is importing itself"))
                    continue
                }
                
                guard !self.seen(apiA: w.value, apiB: api.name.value) else {
                    throw OrbitError(message:
                        "Circular dependency detected: \(api.name.value) -> \(w.value) -> \(api.name.value)"
                    )
                }
                
                self.map.append((api.name.value, w.value))
                
                idx = apis.enumerated().filter { $0.element.hashValue == api.hashValue }[0].offset
                let widx = apis.enumerated().filter { $0.element.name.value == w.value }[0].offset
                
                let wapi = self.apis[widx]
                
                try self.order(api: wapi)
                
                idx = apis.enumerated().filter { $0.element.hashValue == api.hashValue }[0].offset
                
                _ = self.apis.remove(at: idx)
                
                if widx >= self.apis.count {
                    self.apis.append(api)
                } else {
                    self.apis.insert(api, at: widx + 1)
                }
            }
        }
    }
    
    func order() throws -> [APIExpression] {
        for api in self.apis {
            try self.order(api: api)
        }
        
        return apis
    }
    
    public func execute(input: RootExpression) throws -> [APIExpression] {
        let prog = input.body[0] as! ProgramExpression
        self.apis = prog.apis
        
        return try self.order()
    }
}
