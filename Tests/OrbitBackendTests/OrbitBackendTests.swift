import XCTest
import OrbitCompilerUtils
import OrbitFrontend
@testable import OrbitBackend
import cllvm
import LLVM

class OrbitBackendTests : XCTestCase {
    
    func parseTestFile(testFileName: String) throws -> Parser.OutputType {
        let source = SourceResolver()
        let lexer = Lexer()
        let parser = Parser()
        
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: testFileName, ofType: "orb")!
        
        let code = try source.execute(input: path)
        let tokens = try lexer.execute(input: code)
        let ast = try parser.execute(input: tokens)
        
        return ast
    }
    
    func buildTestFile(testFileName: String) throws { //-> (TypeResolver.OutputType, Parser.OutputType) {
        let source = SourceResolver()
        let lexer = Lexer()
        let parser = Parser()
        let nr = NameResolver()
        let mr = MethodResolver()
        let traitResolver = TraitResolver()
        
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: testFileName, ofType: "orb")!
        
        let code = try source.execute(input: path)
        let tokens = try lexer.execute(input: code)
        let ast = try parser.execute(input: tokens)
        
        var context = try nr.execute(input: ast.body as! [APIExpression])
        context = try mr.execute(input: context)
        
        context = try traitResolver.execute(input: context)
        
        let api = try context.mergeAPIs()
        
        let tr = TypeResolver()
        let tm = try tr.execute(input: api)
        
        let gen = LLVMGenerator(apiName: api.name.value)
        let result = try gen.execute(input: (context: context, typeMap: tm, ast: api))
        
        result.dump()
        
        try result.verify()
    }
    
    func testResolve() {
        do {
            try buildTestFile(testFileName: "test1")
        } catch let ex as OrbitError {
            print(ex.message)
        } catch let ex {
            print(ex)
        }
    }
}
